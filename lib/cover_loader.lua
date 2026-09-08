--[[--
Trimmed, adapted copy of hardcoverapp.koplugin's own image_loader.lua +
vendor/url_content.lua (MIT, see ../THIRD_PARTY_NOTICES.md) -- fetches
URLs one at a time (Trapper-wrapped, same subprocess mechanism
hardcover_api.lua's own query() already uses), same no-extra-args
dismissableRunInSubprocess call hardcoverapp's own image loader uses
(getUrlContent returns two values, not one, so task_returns_simple_string
can't be set -- see hardcover_api.lua's own query() for the alternative
shape that's used when a task really does return just one string).

Two flavors: loadAll() queues a background, staggered fetch (silent,
lower priority -- for warming the cache for next time without blocking
what's on screen right now); prefetchAll() blocks until every url is
either loaded or failed (for when covers need to be ready before the
list they belong to is even built -- see shelf_ui.lua's own
prefetchCovers, called before the shelf/search list is shown at all).

Failures are silently skipped either way: a cover thumbnail is a
nice-to-have, not worth surfacing a network error toast over, and the row
it belongs to already has a placeholder standing in for it regardless.
]]--

local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")

local CoverLoader = {}

local function getUrlContent(url, timeout, maxtime)
  local http = require("socket.http")
  local socket = require("socket")
  local socketutil = require("socketutil")
  local socket_url = require("socket.url")

  local parsed = socket_url.parse(url)
  if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
    return false, "Unsupported protocol"
  end

  local sink = {}
  socketutil:set_timeout(timeout or 10, maxtime or 30)
  local request = {
    url = url,
    method = "GET",
    sink = socketutil.table_sink(sink),
  }
  local code, headers = socket.skip(1, http.request(request))
  socketutil:reset_timeout()
  local content = table.concat(sink)

  if code == socketutil.TIMEOUT_CODE or code == socketutil.SSL_HANDSHAKE_CODE
      or code == socketutil.SINK_TIMEOUT_CODE then
    return false, code
  end
  if not headers then
    return false, "Network or remote server unavailable"
  end
  if not code or code < 200 or code > 299 then
    return false, "Remote server error or unavailable"
  end
  return true, content
end

-- items: a list of { url = "...", on_loaded = function(content) ... end }.
-- Downloaded one at a time (not in parallel -- matching hardcoverapp's
-- own batching, easier on both the device and Hardcover's own CDN than
-- firing every request at once for a list of a dozen-plus covers).
function CoverLoader.loadAll(items)
  local queue = { table.unpack(items) }

  local run_next
  run_next = function()
    Trapper:wrap(function()
      local item = table.remove(queue, 1)
      if not item then
        return
      end

      local completed, success, content = Trapper:dismissableRunInSubprocess(function()
        return getUrlContent(item.url, 10, 30)
      end)

      if completed and success and content then
        item.on_loaded(content)
      end

      if #queue > 0 then
        UIManager:scheduleIn(0.1, run_next)
      end
    end)
  end

  if #queue > 0 then
    UIManager:nextTick(run_next)
  end
end

-- Blocking version of the above -- doesn't return until every item in
-- `items` has either loaded or failed (or the user dismisses partway
-- through, via whatever trap widget the caller is showing while this
-- runs -- see shelf_ui.lua's own prefetchCovers). Must be called from
-- inside a Trapper:wrap'd coroutine, same requirement
-- dismissableRunInSubprocess itself has.
function CoverLoader.prefetchAll(items)
  for _, item in ipairs(items) do
    local completed, success, content = Trapper:dismissableRunInSubprocess(function()
      return getUrlContent(item.url, 10, 30)
    end)
    if not completed then
      break
    end
    if success and content then
      item.on_loaded(content)
    end
  end
end

return CoverLoader
