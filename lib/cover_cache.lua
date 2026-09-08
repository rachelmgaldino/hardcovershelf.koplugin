--[[--
Local disk cache for Hardcover cover thumbnails, one file per book (keyed
by book_id, not edition_id -- cached_image lives on the `books` type, not
per-edition, confirmed live: `books(where: {id: {_eq: ...}}) { cached_image
{ url width height } }` returns one image per book regardless of edition).

Cached under KOReader's own data dir, matching bookshelf.koplugin's own
`DataStorage:getDataDir() .. "/cache/..."` convention for this kind of
thing, rather than storing anything inside the plugin folder itself.
]]--

local DataStorage = require("datastorage")
local util = require("util")

local CACHE_DIR = DataStorage:getDataDir() .. "/cache/hardcovershelf_covers"

local CoverCache = {}

-- Extension preserved from the source URL, not a fixed one -- KOReader's
-- own ImageWidget gates its file-loading path on
-- DocumentRegistry:isImageFile(), which checks the file's extension
-- (jpeg/jpg/png/webp/gif), not its content, so a cached file needs a
-- real recognized extension to ever actually load.
local function extensionFor(url)
  local ext = url:match("%.(%a+)$")
  return ext and ext:lower() or "jpg"
end

function CoverCache:path(book_id, url)
  return CACHE_DIR .. "/" .. tostring(book_id) .. "." .. extensionFor(url)
end

function CoverCache:isCached(book_id, url)
  local f = io.open(self:path(book_id, url), "rb")
  if f then
    f:close()
    return true
  end
  return false
end

function CoverCache:save(book_id, url, content)
  util.makePath(CACHE_DIR)
  local f = io.open(self:path(book_id, url), "wb")
  if not f then
    return false
  end
  f:write(content)
  f:close()
  return true
end

return CoverCache
