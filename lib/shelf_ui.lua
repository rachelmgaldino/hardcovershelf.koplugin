local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkManager = require("ui/network/manager")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Api = require("lib/hardcover_api")
local BookList = require("lib/book_list")
local CONST = require("lib/constants")

local ShelfUI = {
  -- kept so a status/rating change made from a nested overlay can refresh
  -- the shelf list by closing and reopening the page.
  _shelf_widget = nil,
  _in_book = false,
}

local status_labels = {
  [CONST.STATUS.TO_READ] = _("Want to Read"),
  [CONST.STATUS.READING] = _("Currently Reading"),
  [CONST.STATUS.FINISHED] = _("Read"),
  [CONST.STATUS.DNF] = _("Did Not Finish"),
}

-- hardcoverapp's Book:readingFormat table (index 3 is deliberately unused
-- upstream too -- Hardcover's reading_format_id has no value 3).
local reading_format_labels = {
  [1] = _("Physical Book"),
  [2] = _("Audiobook"),
  [4] = _("E-Book"),
}

local EBOOK_FORMAT_ID = 4

local EMPTY_ROW_ID = "__empty__"

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
local function bookListItem(book)
  return {
    title = book.title,
    author = mainAuthor(book),
    series_tag = seriesLabel(book),
    book_id = book.book_id,
    pages = book.pages,
    reading_progress = book.reading_progress,
  }
end

local function editionListItem(edition)
  local format = edition.edition_format
  if not format or format == "" then
    format = reading_format_labels[edition.reading_format_id] or _("Unknown format")
  end
  local text = format
  if edition.publisher and edition.publisher.name then
    text = text .. " - " .. edition.publisher.name
  end
  if edition.release_date then
    local year = edition.release_date:match("^(%d%d%d%d)-")
    if year then
      text = text .. " (" .. year .. ")"
    end
  end
  return {
    text = text,
    edition_id = edition.id,
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
-- themselves.
function ShelfUI:_openOverlayList(title, item_table, in_book, on_select, opts)
  local widget
  local on_close = function()
    UIManager:close(widget, "full")
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

-- Star rating, shown only after marking a book Read. close_callback fires
-- on both Save and Cancel (spinwidget.lua's onClose path), so on_done
-- always runs -- the shelf refresh doesn't depend on whether a rating was
-- actually set.
function ShelfUI:showRatingPicker(user_book_id, title, on_done)
  local spinner = SpinWidget:new{
    title_text = _("Rate: ") .. title,
    value = 2.5,
    value_min = 0,
    value_max = 5,
    value_step = 0.5,
    value_hold_step = 2,
    precision = "%.1f",
    ok_text = _("Save"),
    cancel_text = _("Skip"),
    -- SpinWidget disables Save unless the value differs from its starting
    -- point (spinwidget.lua: enabled = ok_always_enabled or original_value
    -- ~= current). There's never a pre-existing rating being edited here,
    -- so any value, including the untouched default, is a legitimate save.
    ok_always_enabled = true,
    callback = function(spin)
      if not self:requireNetwork() then
        return
      end
      Api:updateRating(user_book_id, spin.value)
    end,
    close_callback = on_done,
  }
  UIManager:show(spinner)
end

function ShelfUI:showStatusPicker(book_id, title, edition_id, on_done)
  local dialog

  local function pick(status_id)
    UIManager:close(dialog)
    if not self:requireNetwork() then
      on_done()
      return
    end

    local result = Api:updateUserBook(book_id, status_id, nil, edition_id)
    local marking_read = result and status_id == CONST.STATUS.FINISHED

    if not result then
      UIManager:show(InfoMessage:new{
        text = _("Could not update status. Try again."),
        icon = "notice-warning",
      })
      on_done()
      return
    end

    if marking_read then
      -- Deferred until the rating picker closes, not shown here -- showing
      -- both at once left this toast sitting on top of the rating picker
      -- for its whole 2s timeout instead of the two being sequential.
      self:showRatingPicker(result.id, title, function()
        UIManager:show(InfoMessage:new{
          text = title .. ": " .. status_labels[status_id],
          timeout = 2,
        })
        on_done()
      end)
    else
      UIManager:show(InfoMessage:new{
        text = title .. ": " .. status_labels[status_id],
        timeout = 2,
      })
      on_done()
    end
  end

  dialog = ButtonDialog:new{
    title = title,
    buttons = {
      { { text = status_labels[CONST.STATUS.TO_READ], callback = function() pick(CONST.STATUS.TO_READ) end } },
      { { text = status_labels[CONST.STATUS.READING], callback = function() pick(CONST.STATUS.READING) end } },
      { { text = status_labels[CONST.STATUS.FINISHED], callback = function() pick(CONST.STATUS.FINISHED) end } },
      { { text = status_labels[CONST.STATUS.DNF], callback = function() pick(CONST.STATUS.DNF) end } },
    },
  }
  UIManager:show(dialog)
end

-- code2 -> button label, for the language-filter chooser. Not every
-- language you might hit needs an entry here -- "Other" covers the rest
-- via a typed 2-letter code.
local LANGUAGE_LABELS = {
  en = _("English"),
  pt = _("Portuguese"),
}
local DEFAULT_LANGUAGE = "en"
local LANGUAGE_ROW_ID = "__language__"

local function languageLabel(code)
  if not code or code == "all" then
    return _("All languages")
  end
  return LANGUAGE_LABELS[code] or code:upper()
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

function ShelfUI:showLanguageChooser(book_id, title, in_book, on_done, current)
  local dialog
  local function pick(code)
    UIManager:close(dialog)
    self:pickEditionThenStatus(book_id, title, in_book, on_done, code)
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
                if code then
                  pick(code)
                else
                  self:pickEditionThenStatus(book_id, title, in_book, on_done, current)
                end
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

-- Only for books being newly added from search -- an already-linked shelf
-- book keeps whatever edition it was originally linked with; changing that
-- later is out of scope for now (Hardcover's upsert semantics for omitting
-- edition_id on an existing link aren't confirmed, so this deliberately
-- doesn't touch it).
--
-- Defaults to an ebook edition in English -- Hardcover returns print,
-- audio and ebook editions in every language it knows about for a book,
-- which is a lot of noise to hand-pick from when you're reading on a
-- Kindle and only ever want the ebook. Widens language before format: if
-- there's an ebook but not in English, that's still the right edition; if
-- there's no ebook at all (their database is younger than Goodreads', so
-- this happens), fall back to every edition and say so explicitly, so a
-- print/audio result reads as "nothing else was available" rather than a
-- bug. Always shows the edition picker screen, even for a single clean
-- match -- the language button on it is a deliberate per-book override for
-- the rare book actually being read in another language, not just a
-- resolver for ambiguous results, so it has to stay reachable every time.
function ShelfUI:pickEditionThenStatus(book_id, title, in_book, on_done, language_filter)
  if language_filter == nil then
    language_filter = DEFAULT_LANGUAGE
  end

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
    language_filter = "all"
  end

  local no_ebook = false
  if #editions == 0 then
    -- No ebook edition at all for this book -- show whatever exists
    -- instead of a dead end, and say clearly why.
    no_ebook = true
    editions = filterByLanguage(all_editions, language_filter)
    if #editions == 0 then
      editions = all_editions
      language_filter = "all"
    end
  end

  if no_ebook then
    UIManager:show(InfoMessage:new{
      text = _("No ebook/Kindle edition found for this book -- showing other formats too."),
      timeout = 3,
    })
  end

  -- Always show this screen, even when there's only one edition to pick --
  -- the language button is a deliberate per-book override (almost never
  -- needed, since English/ebook is the right default nearly every time),
  -- not just a resolver for ambiguous results. A book that's actually
  -- being read in Portuguese still needs that override reachable, and it
  -- wouldn't be if a clean single English match skipped this screen
  -- entirely.
  local language_row = {
    text = "[" .. languageLabel(language_filter) .. "] " .. _("change language..."),
    row_id = LANGUAGE_ROW_ID,
    accent = true,
  }
  local item_table = { language_row }
  for _, edition in ipairs(editions) do
    table.insert(item_table, editionListItem(edition))
  end

  local opened
  opened = self:_openOverlayList(_("Select edition: ") .. title, item_table, in_book, function(item)
    UIManager:close(opened.widget, "full")
    if item.row_id == LANGUAGE_ROW_ID then
      self:showLanguageChooser(book_id, title, in_book, on_done, language_filter)
      return
    end
    self:showStatusPicker(book_id, title, item.edition_id, on_done)
  end)
end

function ShelfUI:showSearchDialog(in_book)
  local search_dialog
  search_dialog = InputDialog:new{
    title = _("Search Hardcover"),
    input_hint = _("Title or author"),
    -- TEMPORARY testing prefill -- remove before calling this finished.
    input = "a court of thorns and roses",
    buttons = {{
      {
        text = _("Cancel"),
        callback = function() UIManager:close(search_dialog) end,
      },
      {
        text = _("Search"),
        is_enter_default = true,
        callback = function()
          local query = search_dialog:getInputText()
          UIManager:close(search_dialog)
          self:runSearch(query, in_book)
        end,
      },
    }},
  }
  UIManager:show(search_dialog)
  search_dialog:onShowKeyboard()
end

function ShelfUI:runSearch(query, in_book)
  if not query or query:match("^%s*$") then
    return
  end
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

  local books = Api:findBooks(query, nil, user_id)
  if not books or #books == 0 then
    UIManager:show(InfoMessage:new{ text = _("No results.") })
    return
  end

  local item_table = {}
  for _, book in ipairs(books) do
    table.insert(item_table, bookListItem(book))
  end

  local opened
  opened = self:_openOverlayList(_("Search Hardcover"), item_table, in_book, function(item)
    UIManager:close(opened.widget, "full")
    self:pickEditionThenStatus(item.book_id, item.title, in_book, function()
      self:_refreshShelf()
    end)
  end, { back_button = { icon = "chevron.left" } })
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

  local subheader = string.format(_("Currently Reading - %d books"), #books)

  local opts = {
    header_buttons = {
      { icon = "appbar.search", callback = function() self:showSearchDialog(in_book) end },
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
    self:showStatusPicker(item.book_id, item.title, nil, function()
      self:_refreshShelf()
    end)
  end, opts)
  self._shelf_widget = opened.widget
end

return ShelfUI
