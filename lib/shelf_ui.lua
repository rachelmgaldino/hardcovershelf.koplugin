local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkManager = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Api = require("lib/hardcover_api")
local BookList = require("lib/book_list")
local CONST = require("lib/constants")
local CoverCache = require("lib/cover_cache")
local CoverLoader = require("lib/cover_loader")
local RatingPicker = require("lib/rating_picker")
local StatusPicker = require("lib/status_picker")

local ShelfUI = {
  -- kept so a status/rating change made from a nested overlay can refresh
  -- the shelf list by closing and reopening the page.
  _shelf_widget = nil,
  _in_book = false,
  -- Search page state, persisted across rebuilds (query text, current
  -- language filter, and the currently-shown widget so a rebuild can
  -- close it first instead of stacking a new copy on top).
  _search_widget = nil,
  _search_query = nil,
  _search_language = nil,
  -- How many of the current query's results are actually shown/have
  -- their covers prefetched -- nil means SEARCH_PAGE_SIZE (the default,
  -- reset whenever a new query runs). findBooks already returns up to 25
  -- results in one request; this is purely about not blocking on
  -- prefetching every one of their covers up front when only the first
  -- handful are visible without scrolling.
  _search_visible_count = nil,
}

local SEARCH_PAGE_SIZE = 5

local status_labels = {
  [CONST.STATUS.TO_READ] = _("Want to Read"),
  [CONST.STATUS.READING] = _("Currently Reading"),
  [CONST.STATUS.FINISHED] = _("Read"),
  [CONST.STATUS.DNF] = _("Did Not Finish"),
}

local EBOOK_FORMAT_ID = 4

local EMPTY_ROW_ID = "__empty__"
local LOAD_MORE_ROW_ID = "__load_more__"

-- reading_format_id == nil (edition has no format set) is kept, same
-- reasoning as filterByLanguage below: unset isn't the same as "wrong".
local function filterByFormat(editions, format_id)
  local filtered = {}
  for _, edition in ipairs(editions) do
    if not edition.reading_format_id or edition.reading_format_id == format_id then
      table.insert(filtered, edition)
    end
  end
  return filtered
end

-- cached_contributors is an opaque `json` scalar in Hardcover's schema
-- (confirmed against the real schema.graphql -- unlike primary_books_count
-- below, its internal shape isn't something the schema documents). This
-- mirrors hardcoverapp's own search_dialog.lua instead, which checks a
-- singular `.author` field before the full array -- empirically the
-- primary author, ahead of the full contributor list (illustrators,
-- translators, etc. -- what was showing up for every manga volume).
local function mainAuthor(book)
  if not book.contributions then
    return nil
  end
  if book.contributions.author then
    return book.contributions.author
  end
  local first = book.contributions[1]
  if first and first.author and first.author.name then
    return first.author.name
  end
  return nil
end

-- book_series is a real list on the `books` type (confirmed:
-- `book_series: [book_series!]!` in schema.graphql), so index [1] rather
-- than treating it as a bare object.
--
-- No "of N" total -- tried computing a real released-count (see git
-- history / this session's own back-and-forth) and hit an unresolvable
-- ambiguity in Hardcover's own data: a `YYYY-01-01` release date can mean
-- either "real release, exact day just wasn't recorded" (One Piece Vol 2,
-- 1998) or "placeholder for an unconfirmed future book" (an ACOTAR
-- translation dated 2026-01-01 for a book that isn't out until October) --
-- same shape, opposite meaning, no field to tell them apart. Position
-- alone doesn't have that problem.
local function seriesLabel(book)
  local entry = book.book_series and book.book_series[1]
  if not entry or not entry.position or not entry.series then
    return nil
  end
  return entry.series.name .. ", #" .. tostring(entry.position)
end

-- title/author passed through as separate fields (not one combined
-- string) so book_list.lua can style them differently -- bold title,
-- gray author -- and size each independently against the actual space
-- left after the series tag, if any.
-- cached_image is a real, opaque `json` scalar on the `books` type
-- (confirmed live: { id, url, color, width, height, color_name }) -- only
-- url/width/height are what book_list.lua needs to actually render one.
local function bookListItem(book)
  local cover_url, cover_w, cover_h
  if book.cached_image and book.cached_image.url then
    cover_url = book.cached_image.url
    cover_w = book.cached_image.width
    cover_h = book.cached_image.height
  end
  return {
    title = book.title,
    author = mainAuthor(book),
    series_tag = seriesLabel(book),
    book_id = book.book_id,
    pages = book.pages,
    reading_progress = book.reading_progress,
    cover_url = cover_url,
    cover_w = cover_w,
    cover_h = cover_h,
  }
end

function ShelfUI:requireNetwork()
  if not NetworkManager:isConnected() then
    UIManager:show(InfoMessage:new{
      text = _("Connect to WiFi first."),
      icon = "notice-warning",
    })
    return false
  end
  return true
end

-- Downloads and caches any of `books`' covers that aren't already on
-- disk, THEN calls `continue_fn` -- covers are ready before the list
-- they belong to is even built, rather than the list showing first with
-- placeholders and the cache only catching up for a future rebuild.
-- That "catch up next time" version is still what lib/book_list.lua
-- itself falls back to for any row this doesn't cover, but it's a poor
-- primary strategy for a screen like search results, which is rarely the
-- exact same list twice -- there usually isn't a meaningful "next time"
-- for it to catch up on.
--
-- Trapper:dismissableRunInSubprocess (what the actual downloading goes
-- through, lib/cover_loader.lua's own prefetchAll) needs to run inside a
-- coroutine, and, more importantly, doesn't block its caller's own stack
-- by itself -- Trapper:wrap's coroutine.resume() returns as soon as the
-- wrapped function first yields, not when it finishes -- so `continue_fn`
-- has to run *inside* that same wrapped function, after the prefetch
-- call, rather than as ordinary code placed after this one returns.
local function prefetchCoversThen(books, continue_fn)
  local pending = {}
  for _, book in ipairs(books) do
    local cover = book.cached_image
    if cover and cover.url and not CoverCache:isCached(book.book_id, cover.url) then
      table.insert(pending, {
        url = cover.url,
        on_loaded = function(content)
          CoverCache:save(book.book_id, cover.url, content)
        end,
      })
    end
  end

  if #pending == 0 then
    continue_fn()
    return
  end

  Trapper:wrap(function()
    local msg = InfoMessage:new{ text = _("Loading covers...") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    CoverLoader.prefetchAll(pending)
    UIManager:close(msg)
    continue_fn()
  end)
end

-- Builds and shows the custom list (lib/book_list.lua) as an overlay ON
-- TOP of whatever's currently shown (the shelf page underneath is never
-- closed for this), returning the widget passed to UIManager:show, for
-- closing later.
--
-- "full" refresh type on both show and close: e-ink partial refresh only
-- redraws the specific region UIManager computes as dirty, and stacking a
-- second full-page custom widget on top of the shelf (never closed) was
-- leaving the shelf's own rows visibly ghosted through on top. Forcing a
-- full screen redraw sidesteps needing that computed region to be exactly
-- right.
-- Header button entries (opts.header_buttons and opts.back_button)
-- without their own "callback" get this screen's own close (back to
-- whatever's underneath) wired in automatically -- so callers can write
-- e.g. { icon = "close" } or { icon = "chevron.left" } for a plain
-- dismiss button without needing the widget reference (which doesn't
-- exist yet at the point the caller builds opts) to build that closure
-- themselves. opts.on_closed, if given, runs right after -- for a caller
-- (the search page) that tracks "is my widget currently open" in its own
-- state and needs to hear about a close triggered from inside this
-- screen (its back button), not just ones it triggers itself.
function ShelfUI:_openOverlayList(title, item_table, in_book, on_select, opts)
  local widget
  local on_close = function()
    UIManager:close(widget, "full")
    if opts.on_closed then
      opts.on_closed()
    end
  end
  opts = opts or {}
  if opts.header_buttons then
    for _, btn in ipairs(opts.header_buttons) do
      btn.callback = btn.callback or on_close
    end
  end
  if opts.back_button then
    opts.back_button.callback = opts.back_button.callback or on_close
  end
  widget = BookList.build(title, item_table, in_book, on_select, on_close, opts)
  UIManager:show(widget, "full")
  return { widget = widget }
end

-- No live in-place update on this custom list (unlike stock Menu's
-- switchItemTable), so refreshing the shelf means closing and rebuilding
-- it -- simple, and the shelf is cheap enough to rebuild that this isn't
-- worth optimizing away.
function ShelfUI:_refreshShelf()
  if self._shelf_widget then
    UIManager:close(self._shelf_widget, "full")
  end
  self:show(self._in_book)
end

function ShelfUI:_shelfItemTable(books)
  local item_table = {}
  if #books == 0 then
    table.insert(item_table, {
      text = _("Nothing here yet -- tap the search icon above to add a book."),
      row_id = EMPTY_ROW_ID,
      dim = true,
    })
  end
  for _, book in ipairs(books) do
    table.insert(item_table, bookListItem(book))
  end
  return item_table
end

local STATUS_OPTIONS = {
  { id = CONST.STATUS.TO_READ, label = status_labels[CONST.STATUS.TO_READ] },
  { id = CONST.STATUS.READING, label = status_labels[CONST.STATUS.READING] },
  { id = CONST.STATUS.FINISHED, label = status_labels[CONST.STATUS.FINISHED] },
  { id = CONST.STATUS.DNF, label = status_labels[CONST.STATUS.DNF] },
}

function ShelfUI:showStatusPicker(book_id, title, author, edition_id, on_done)
  -- Every other status commits the moment its Done tap reaches here (see
  -- the plain branch of pick() below). Read is the one exception: tapping
  -- its tile auto-advances straight into the rating picker (read_id below)
  -- with nothing sent yet -- Skip or Save Rating there is what actually
  -- fires the "mark as read" mutation (+ rating, for Save), and closing
  -- that screen any other way (the X, or a tap outside the card) cancels
  -- the whole thing: nothing is sent to Hardcover, the book's status
  -- doesn't change, same as cancelling out of this status picker itself.
  local function markRead()
    -- requireNetwork() isn't checked until here (not when the rating
    -- picker opens): opening it is just local UI, no reason to gate that
    -- on being online -- only the actual commit needs a connection.
    local function commit(rating)
      if not self:requireNetwork() then
        return
      end
      local result = Api:updateUserBook(book_id, CONST.STATUS.FINISHED, nil, edition_id)
      if not result then
        UIManager:show(InfoMessage:new{
          text = _("Could not update status. Try again."),
          icon = "notice-warning",
        })
        return
      end
      if rating then
        Api:updateRating(result.id, rating)
      end
      -- Deferred until the rating picker closes, not shown alongside it --
      -- showing both at once left this toast sitting on top of the rating
      -- picker for its whole 2s timeout instead of the two being
      -- sequential.
      UIManager:show(InfoMessage:new{
        text = title .. ": " .. status_labels[CONST.STATUS.FINISHED],
        timeout = 2,
      })
    end

    RatingPicker.show{
      title = title,
      author = author,
      on_save = function(rating)
        commit(rating)
        on_done()
      end,
      on_skip = function()
        commit(nil)
        on_done()
      end,
      -- on_cancel: nothing sent, nothing changed -- on_done isn't called
      -- either, same as StatusPicker's own cancel path (no on_cancel
      -- wired below), since the list page underneath never went stale.
    }
  end

  local function pick(status_id)
    if status_id == CONST.STATUS.FINISHED then
      markRead()
      return
    end

    if not self:requireNetwork() then
      on_done()
      return
    end

    local result = Api:updateUserBook(book_id, status_id, nil, edition_id)
    if not result then
      UIManager:show(InfoMessage:new{
        text = _("Could not update status. Try again."),
        icon = "notice-warning",
      })
      on_done()
      return
    end

    -- Plants a reading session the moment a book is marked Currently
    -- Reading, instead of leaving the shelf's progress bar/meta line
    -- blank until you happen to log a real update on Hardcover's own site
    -- or app -- that's the only reason no info showed up there earlier,
    -- not a fetch bug (confirmed by updating progress on the site and
    -- watching it appear immediately). No page count passed -- Hardcover
    -- normalizes an explicit 0 to null server-side anyway (confirmed
    -- live: a session created with progress_pages=0 came back null), and
    -- lib/book_list.lua's own progress display already treats a nil
    -- progress_pages as 0% once a session exists, so there's nothing a
    -- literal 0 would add. Only when nothing's logged yet
    -- (result.user_book_reads, from the mutation's own response, is this
    -- user_book's existing most-recent session if any) -- otherwise
    -- re-affirming Currently Reading on a book you already have real
    -- progress on would bury it under a fresh empty one.
    if status_id == CONST.STATUS.READING and not (result.user_book_reads and result.user_book_reads[1]) then
      Api:createRead(result.id, edition_id, nil, os.date("%Y-%m-%d"))
    end

    UIManager:show(InfoMessage:new{
      text = title .. ": " .. status_labels[status_id],
      timeout = 2,
    })
    on_done()
  end

  StatusPicker.show{
    title = title,
    author = author,
    options = STATUS_OPTIONS,
    read_id = CONST.STATUS.FINISHED,
    on_pick = pick,
  }
end

-- code2 -> button label, for the language-filter chooser. Not every
-- language you might hit needs an entry here -- "Other" covers the rest
-- via a typed 2-letter code.
local LANGUAGE_LABELS = {
  en = _("English"),
  pt = _("Portuguese"),
}
local DEFAULT_LANGUAGE = "en"

local function languageLabel(code)
  if not code or code == "all" then
    return _("All languages")
  end
  return LANGUAGE_LABELS[code] or code:upper()
end

-- Short code for the search-bar chip ("EN", "PT", "ALL"), as opposed to
-- languageLabel's full name (used in the "Results for... / {Language}"
-- line) -- same distinction the design handoff itself makes between its
-- langCode and langName.
local function languageCode(code)
  if not code or code == "all" then
    return _("ALL")
  end
  return code:upper()
end

-- Option list (English/Portuguese/All/a typed code) behind the search
-- page's language chip (chooseSearchLanguage, below) -- factored out on
-- its own in case a second caller needs the same picker again later.
local function chooseLanguageOptions(current, on_pick)
  local dialog
  local function pick(code)
    UIManager:close(dialog)
    on_pick(code)
  end

  dialog = ButtonDialog:new{
    title = _("Filter editions by language"),
    buttons = {
      { { text = _("English"), callback = function() pick("en") end } },
      { { text = _("Portuguese"), callback = function() pick("pt") end } },
      { { text = _("All languages"), callback = function() pick("all") end } },
      { { text = _("Other (enter code)"), callback = function()
        UIManager:close(dialog)
        local input
        input = InputDialog:new{
          title = _("2-letter language code"),
          input_hint = _("e.g. fr, de, ja"),
          buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(input) end },
            {
              text = _("OK"),
              is_enter_default = true,
              callback = function()
                local code = input:getInputText():lower():match("^%a%a$")
                UIManager:close(input)
                on_pick(code or current)
              end,
            },
          }},
        }
        UIManager:show(input)
        input:onShowKeyboard()
      end } },
    },
  }
  UIManager:show(dialog)
end

-- code2 == nil (edition has no language set) is kept in every filter --
-- excluding it would hide editions Hardcover just never tagged, which
-- isn't the same as them being the wrong language.
local function filterByLanguage(editions, code)
  if not code or code == "all" then
    return editions
  end
  local filtered = {}
  for _, edition in ipairs(editions) do
    local edition_code = edition.language and edition.language.code2
    if not edition_code or edition_code == code then
      table.insert(filtered, edition)
    end
  end
  return filtered
end

-- Wired to the search page's persistent language filter -- the only
-- remaining language override, now that pickEditionThenStatus below no
-- longer shows a picker screen of its own to host a per-book one. Set
-- this before tapping a search result to link the rare book actually
-- being read in a language other than the current default.
function ShelfUI:chooseSearchLanguage(in_book)
  chooseLanguageOptions(self._search_language, function(code)
    self._search_language = code
    self:showSearchPage(in_book)
  end)
end

-- Only for books being newly added from search -- an already-linked shelf
-- book keeps whatever edition it was originally linked with; changing that
-- later is out of scope for now (Hardcover's upsert semantics for omitting
-- edition_id on an existing link aren't confirmed, so this deliberately
-- doesn't touch it).
--
-- Auto-links the matching edition with the most Hardcover readers,
-- instead of making you pick between several near-duplicate ebook
-- editions of the same book by hand: findEditions already orders its
-- results by users_count desc_nulls_last (confirmed live against the
-- API), and filtering preserves that order, so the first entry left
-- after narrowing to ebook + language is the most-read match. Widens
-- language before format: if there's an ebook but not in the requested
-- language, that's still the right edition; if there's no ebook at all
-- (their database is younger than Goodreads', so this happens), fall
-- back to every edition (still most-read first) and say so explicitly,
-- so a print/audio pick reads as "nothing else was available" rather
-- than a bug.
function ShelfUI:pickEditionThenStatus(book_id, title, author, in_book, on_done, language_filter)
  language_filter = language_filter or DEFAULT_LANGUAGE

  if not self:requireNetwork() then
    on_done()
    return
  end

  local all_editions = Api:findEditions(book_id) or {}
  local ebook_editions = filterByFormat(all_editions, EBOOK_FORMAT_ID)
  local editions = filterByLanguage(ebook_editions, language_filter)

  if #editions == 0 and #ebook_editions > 0 then
    -- Ebook editions exist, just not in the requested language.
    editions = ebook_editions
  end

  if #editions == 0 then
    -- No ebook edition at all for this book -- fall back to whatever
    -- exists instead of a dead end.
    editions = filterByLanguage(all_editions, language_filter)
    if #editions == 0 then
      editions = all_editions
    end
    if #editions == 0 then
      UIManager:show(InfoMessage:new{
        text = _("No editions found for this book."),
        icon = "notice-warning",
      })
      on_done()
      return
    end
    UIManager:show(InfoMessage:new{
      text = _("No ebook/Kindle edition found for this book -- using the most-read other format instead."),
      timeout = 3,
    })
  end

  self:showStatusPicker(book_id, title, author, editions[1].id, on_done)
end

-- Opens a plain InputDialog (the same popup search always used) prefilled
-- with the current query, then rebuilds the search page with the new
-- query on Search -- the on-page search bar only ever *looks* like a real
-- text field; tapping it still hands off to this same popup rather than
-- embedding a live-editable field directly in the page. KOReader's
-- InputText widget genuinely can be embedded standalone outside
-- InputDialog (bookshelf.koplugin's own library_modal.lua does exactly
-- that), but only by keeping one persistent instance alive across an
-- in-place refresh -- every other screen in this plugin, this one
-- included, is built by fully closing and reopening a new widget on any
-- change, which a live keystroke-by-keystroke field can't survive. A
-- popup avoids needing a second, different page-lifecycle model just for
-- this one field.
function ShelfUI:_editSearchQuery(in_book)
  local dialog
  dialog = InputDialog:new{
    title = _("Search Hardcover"),
    input_hint = _("Title or author"),
    input = self._search_query or "",
    buttons = {{
      {
        text = _("Cancel"),
        callback = function() UIManager:close(dialog) end,
      },
      {
        text = _("Search"),
        is_enter_default = true,
        callback = function()
          local query = dialog:getInputText()
          UIManager:close(dialog)
          self._search_query = query
          self._search_visible_count = nil
          self:showSearchPage(in_book)
        end,
      },
    }},
  }
  UIManager:show(dialog)
  dialog:onShowKeyboard()
end

-- The search page itself: header (back chevron + title), a search-bar row
-- (fake field showing the current query/hint + a language chip -- both
-- just open a popup on tap, see _editSearchQuery/chooseSearchLanguage),
-- a "Results for..." line, then results or an empty state. Rebuilt (closed
-- and reopened) on every query/language change rather than updated in
-- place, same as every other screen here -- self._search_widget tracks
-- the current instance so a rebuild can close the old one first instead
-- of stacking a new copy on top.
function ShelfUI:showSearchPage(in_book)
  if self._search_widget then
    UIManager:close(self._search_widget, "full")
    self._search_widget = nil
  end
  if self._search_language == nil then
    self._search_language = DEFAULT_LANGUAGE
  end

  local query = self._search_query
  local has_query = query and query:match("%S")
  local books = {}

  if has_query then
    if not self:requireNetwork() then
      return
    end
    local user_id = Api:getUserId()
    if not user_id then
      UIManager:show(InfoMessage:new{
        text = _("Could not reach Hardcover. Check your token and connection."),
        icon = "notice-warning",
      })
      return
    end
    books = Api:findBooks(query, nil, user_id) or {}
  end

  -- Only the visible slice gets its covers prefetched -- findBooks can
  -- return up to 25 results in one request, and blocking on every one of
  -- their covers before showing anything was the actual slow part, not
  -- the search itself. "Load more" just reveals (and prefetches) another
  -- page of what's already been fetched, not a new API call.
  local visible_count = math.min(self._search_visible_count or SEARCH_PAGE_SIZE, #books)
  local visible_books = {}
  for i = 1, visible_count do
    table.insert(visible_books, books[i])
  end

  prefetchCoversThen(visible_books, function()
    local item_table = {}
    local subheader
    if not has_query then
      table.insert(item_table, { text = _("Search for a title or author above."), dim = true })
    elseif #books == 0 then
      table.insert(item_table, { text = string.format(_('No results for "%s".'), query), dim = true })
    else
      for _, book in ipairs(visible_books) do
        table.insert(item_table, bookListItem(book))
      end
      if #books > visible_count then
        table.insert(item_table, {
          text = string.format(_("Show %d more results"), math.min(SEARCH_PAGE_SIZE, #books - visible_count)),
          row_id = LOAD_MORE_ROW_ID,
          accent = true,
        })
      end
    end
    if has_query then
      subheader = string.format(_('Results for "%s" - %s / Ebook'), query, languageLabel(self._search_language))
    end

    local opts = {
      back_button = { icon = "chevron.left" },
      -- Closes the shelf too, not just this search overlay -- dismisses
      -- the whole plugin in one tap instead of needing back-to-shelf
      -- then its own X.
      close_button = {
        icon = "close",
        callback = function()
          if self._search_widget then
            UIManager:close(self._search_widget, "full")
            self._search_widget = nil
          end
          if self._shelf_widget then
            UIManager:close(self._shelf_widget, "full")
            self._shelf_widget = nil
          end
        end,
      },
      search_bar = {
        query_text = query,
        query_hint = _("Search Hardcover"),
        language_label = languageCode(self._search_language),
        on_query_tap = function() self:_editSearchQuery(in_book) end,
        on_language_tap = function() self:chooseSearchLanguage(in_book) end,
      },
      subheader = subheader,
      on_closed = function() self._search_widget = nil end,
    }

    local opened
    opened = self:_openOverlayList(_("Search Hardcover"), item_table, in_book, function(item)
      if item.row_id == LOAD_MORE_ROW_ID then
        self._search_visible_count = visible_count + SEARCH_PAGE_SIZE
        self:showSearchPage(in_book)
        return
      end
      UIManager:close(opened.widget, "full")
      self:pickEditionThenStatus(item.book_id, item.title, item.author, in_book, function()
        self:_refreshShelf()
      end, self._search_language)
    end, opts)
    self._search_widget = opened.widget
  end)
end

-- Single entry point: one page showing your Currently Reading shelf, with
-- a pinned row to search and add a book -- everything else (search,
-- edition pick, status pick, rating) opens as an overlay stacked on top of
-- this page, which is never closed until the whole thing is dismissed.
function ShelfUI:show(in_book)
  self._in_book = in_book

  if not self:requireNetwork() then
    return
  end

  local user_id = Api:getUserId()
  if not user_id then
    UIManager:show(InfoMessage:new{
      text = _("Could not reach Hardcover. Check your token and connection."),
      icon = "notice-warning",
    })
    return
  end

  local books = Api:listByStatus(CONST.STATUS.READING, user_id) or {}

  prefetchCoversThen(books, function()
    local subheader = string.format(_("Currently Reading - %d books"), #books)

    local opts = {
      header_buttons = {
        { icon = "appbar.search", callback = function() self:showSearchPage(in_book) end },
        { icon = "cre.render.reload", callback = function() self:_refreshShelf() end },
        { icon = "close" },
      },
      subheader = subheader,
    }

    local opened = self:_openOverlayList(_("Hardcover Shelf"), self:_shelfItemTable(books), in_book, function(item)
      if item.row_id == EMPTY_ROW_ID then
        self:_refreshShelf()
        return
      end
      self:showStatusPicker(item.book_id, item.title, item.author, nil, function()
        self:_refreshShelf()
      end)
    end, opts)
    self._shelf_widget = opened.widget
  end)
end

return ShelfUI
