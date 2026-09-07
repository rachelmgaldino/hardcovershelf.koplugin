-- Trimmed, adapted copy of hardcoverapp.koplugin's HardcoverApi (MIT, see
-- ../THIRD_PARTY_NOTICES.md). Kept: the request wrapper, user lookup,
-- catalog search, book hydration, existing-link lookup, and the
-- link/status-change mutation. Dropped: everything tied to a document
-- being open (page/progress tracking, ratings, journal notes, edition
-- selection, ISBN auto-link). Added: listByStatus, which doesn't exist
-- upstream -- see hardcoverapp's getRandomToRead for the pattern this is
-- based on.

local config = require("hardcovershelf_config")
local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local _t = require("lib/table_util")
local Trapper = require("ui/trapper")
local NetworkManager = require("ui/network/manager")
local socketutil = require("socketutil")

local api_url = "https://api.hardcover.app/v1/graphql"

local headers = {
  ["Content-Type"] = "application/json",
  ["User-Agent"] = "hardcovershelf.koplugin/0.1.0 (https://hardcover.app)",
  Authorization = "Bearer " .. config.token
}

local HardcoverApi = {
  enabled = true
}

local book_fragment = [[
fragment BookParts on books {
  book_id: id
  title
  release_year
  pages
  book_series {
    position
    series {
      name
    }
  }
  contributions: cached_contributors
  cached_image
  user_books(where: { user_id: { _eq: $userId }}) {
    id
  }
}]]

local user_book_fragment = [[
fragment UserBookParts on user_books {
  id
  book_id
  status_id
  edition_id
  privacy_setting_id
  rating
}]]

local edition_fragment = [[
fragment EditionParts on editions {
  id
  edition_format
  reading_format_id
  pages
  language {
    code2
  }
  publisher {
    name
  }
  release_date
}]]

function HardcoverApi:me()
  local result = self:query([[{
    me {
      id
      account_privacy_setting_id
    }
  }]])

  if result and result.me then
    return result.me[1]
  end
  return {}
end

-- Not present upstream (hardcoverapp persists this in its own settings
-- file via lib/user.lua; this plugin keeps no settings file, so it's just
-- cached in memory for the current KOReader session).
local cached_user_id

function HardcoverApi:getUserId()
  if not cached_user_id then
    local me = self:me()
    cached_user_id = me.id
  end
  return cached_user_id
end

function HardcoverApi:query(query, parameters)
  if not NetworkManager:isConnected() or not self.enabled then
    return
  end

  local completed, content

  completed, content = Trapper:dismissableRunInSubprocess(function()
    return self:_query(query, parameters)
  end, true, true)

  if completed and content then
    local code, response = string.match(content, "^([^:]*):(.*)")
    if string.find(code, "^%d%d%d") then
      local data = json.decode(response, json.decode.simple)
      if data.data then
        return data.data
      elseif data.errors or data.error then
        local err = data.errors or { data.error }
        if self.on_error then
          for _, e in ipairs(err) do
            self.on_error(e)
          end
        end

        return nil, { errors = err }
      end
    else
      return nil, { completed = false }
    end
  else
    return nil, { completed = completed }
  end
end

function HardcoverApi:_query(query, parameters)
  local requestBody = {
    query = query,
    variables = parameters
  }

  local maxtime = 12
  local timeout = 6

  local sink = {}
  socketutil:set_timeout(timeout, maxtime or 30)
  local request = {
    url = api_url,
    method = "POST",
    headers = headers,
    source = ltn12.source.string(json.encode(requestBody)),
    sink = socketutil.table_sink(sink),
  }

  local _, code, _headers, _status = http.request(request)
  socketutil:reset_timeout()

  local content = table.concat(sink)
  if code == socketutil.TIMEOUT_CODE or
    code == socketutil.SSL_HANDSHAKE_CODE or
    code == socketutil.SINK_TIMEOUT_CODE
  then
    logger.warn("[HardcoverShelf] request interrupted:", code)
    return code .. ':'
  end

  if type(code) == "string" then
    logger.dbg("[HardcoverShelf] request error", code)
  end

  if type(code) == "number" and (code < 200 or code > 299) then
    logger.dbg("[HardcoverShelf] request error", code, content)
  end

  return code .. ':' .. content
end

function HardcoverApi:hydrateBooks(ids, user_id)
  if #ids == 0 then
    return {}
  end

  local bookQuery = [[
    query ($ids: [Int!], $userId: Int!) {
      books(where: { id: { _in: $ids }}) {
        ...BookParts
      }
    }
  ]] .. book_fragment

  local books = self:query(bookQuery, { ids = ids, userId = user_id })
  if books then
    local list = books.books

    if #list > 1 then
      local id_order = {}

      for i, v in ipairs(ids) do
        id_order[v] = i
      end

      table.sort(list, function(a, b)
        return id_order[a.book_id] < id_order[b.book_id]
      end)
    end

    return list
  end
end

function HardcoverApi:search(title, author, userId, page)
  page = page or 1
  local query = [[
    query ($query: String!, $page: Int!) {
      search(query: $query, per_page: 25, page: $page, query_type: "Book") {
        ids
      }
    }]]
  local search = title .. " " .. (author or "")
  local results, error = self:query(query, { query = search, page = page })
  if error then
    return nil, error
  end

  if not results or not _t.dig(results, "search", "ids") then
    return {}
  end

  local ids = _t.map(results.search.ids, function(id) return tonumber(id) end)
  return self:hydrateBooks(ids, userId)
end

function HardcoverApi:findBooks(title, author, userId)
  if not title or string.match(title, "^%s*$") then
    return {}
  end

  title = title:gsub(":.+", ""):gsub("^%s+", ""):gsub("%s+$", "")
  return self:search(title, author, userId)
end

-- Trimmed from hardcoverapp's findEditions: dropped its second query that
-- re-sorts to prefer editions the user has already read (an extra network
-- round trip) -- this just returns Hardcover's own users_count desc order,
-- which is enough to tell a physical/ebook/audiobook edition apart and pick
-- one deliberately instead of letting insert_user_book silently default.
function HardcoverApi:findEditions(book_id)
  local query = [[
    query ($id: Int!) {
      editions(where: { book_id: { _eq: $id }}, order_by: { users_count: desc_nulls_last }) {
        ...EditionParts
      }
    }]] .. edition_fragment

  local results, err = self:query(query, { id = book_id })
  if not results or not results.editions then
    return {}, err
  end

  return results.editions
end

-- Not present upstream -- list every book the user has at a given status
-- (Want to Read / Currently Reading / Read / DNF, see lib/constants.lua),
-- newest-linked first. Modeled on hardcoverapp's getRandomToRead, which
-- does the same status_id filter but only for a random Want-to-Read pick.
-- Pulled but not rendered anywhere yet: progress_pages/started_at from
-- Hardcover's own user_book_reads (the structure hardcoverapp itself
-- writes to, which this plugin's own updateUserBook/updateRating never
-- touch, so this is read-only against whatever hardcoverapp or the
-- Hardcover website already recorded). limit: 1, order_by desc gets the
-- most recent read session per book, which is what "current progress"
-- means for a book with more than one (a re-read, or a paused-then-resumed
-- one).
function HardcoverApi:listByStatus(status_id, user_id)
  -- status_id is interpolated as a literal, not a $variable -- matching
  -- hardcoverapp's own getRandomToRead (hardcover_api.lua:404-427), which
  -- does the same rather than declaring it as an Int! GraphQL variable.
  -- Safe here since status_id only ever comes from lib/constants.lua, never
  -- from user input.
  local query = string.format([[
    query ($userId: Int!) {
      user_books(
        where: { status_id: { _eq: %d }, user_id: { _eq: $userId }},
        order_by: { id: desc }
      ) {
        book_id
        user_book_reads(order_by: { id: desc }, limit: 1) {
          started_at
          finished_at
          progress_pages
        }
      }
    }
  ]], status_id)

  local results, err = self:query(query, { userId = user_id })
  if not results or not results.user_books then
    return {}, err
  end

  local ids = _t.map(results.user_books, function(r) return tonumber(r.book_id) end)
  local books = self:hydrateBooks(ids, user_id)
  if not books then
    return books, err
  end

  -- Merge each user_book's latest read session back onto its hydrated
  -- book record (hydrateBooks itself only returns book-level fields, not
  -- anything from user_books) so it travels with the book without
  -- changing hydrateBooks' own, more widely-used, shape.
  local reads_by_book_id = {}
  for _, ub in ipairs(results.user_books) do
    local read = ub.user_book_reads and ub.user_book_reads[1]
    if read then
      reads_by_book_id[tonumber(ub.book_id)] = read
    end
  end
  for _, book in ipairs(books) do
    book.reading_progress = reads_by_book_id[book.book_id]
  end

  return books
end

function HardcoverApi:findUserBook(book_id, user_id)
  local read_query = [[
    query ($id: Int!, $userId: Int!) {
      user_books(where: { book_id: { _eq: $id }, user_id: { _eq: $userId }}) {
        ...UserBookParts
      }
    }
  ]] .. user_book_fragment

  local results, err = self:query(read_query, { id = book_id, userId = user_id })
  if not results or not results.user_books then
    return {}, err
  end

  return results.user_books[1]
end

function HardcoverApi:updateUserBook(book_id, status_id, privacy_setting_id, edition_id)
  if not privacy_setting_id then
    local me = self:me()
    privacy_setting_id = me.account_privacy_setting_id or 1
  end

  local query = [[
    mutation ($object: UserBookCreateInput!) {
      insert_user_book(object: $object) {
        error
        user_book {
          ...UserBookParts
        }
      }
    }
  ]] .. user_book_fragment

  local update_args = {
    book_id = book_id,
    privacy_setting_id = privacy_setting_id,
    status_id = status_id,
    edition_id = edition_id
  }

  local result = self:query(query, { object = update_args })
  if result and result.insert_user_book then
    return result.insert_user_book.user_book
  end
end

function HardcoverApi:updateRating(user_book_id, rating)
  local query = [[
    mutation ($id: Int!, $rating: numeric) {
      update_user_book(id: $id, object: { rating: $rating }) {
        error
        user_book {
          ...UserBookParts
        }
      }
    }
  ]] .. user_book_fragment

  local result = self:query(query, { id = user_book_id, rating = rating })
  if result and result.update_user_book then
    return result.update_user_book.user_book
  end
end

return HardcoverApi
