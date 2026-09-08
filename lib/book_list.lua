--[[--
A small custom scrollable list, built from scratch rather than KOReader's
core `Menu` widget. `Menu` only renders plain text per row (its `mandatory`
field is hard-coerced into a plain TextWidget internally, see menu.lua's
own updateItems -- no hook for a custom child widget), so there's no way
to get a real rounded-corner background tag into a stock Menu row without
either vendoring a huge replacement (the ~1000-line approach hardcoverapp
and bookends both took for their own fancier lists) or building just
enough of a list ourselves. This is the second option, scoped to exactly
what this plugin needs.

Layout constants below are pulled directly from the design handoff's own
HTML/CSS (design_handoff_hardcover_shelf/Hardcover Shelf.dc.html), not
estimated from the screenshots, and run through Screen:scaleBySize() the
same way every other literal size in this codebase is.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local CoverCache = require("lib/cover_cache")
local CoverLoader = require("lib/cover_loader")

local Screen = Device.screen
local S = function(px) return Screen:scaleBySize(px) end

-- Serif faces for book-like typography (title/author), matching the
-- design handoff's "Georgia in the mock -- substitute KOReader's default
-- serif" instruction. Font:getFace falls back to using its first argument
-- directly as a font filename when it's not a name in the fontmap table
-- (confirmed: ui/font.lua's getFace tries FontList.fontdir.."/"..realname
-- first, then searches every font folder for it -- these three files are
-- on disk under fonts/noto/), so passing the bare filename here is a real,
-- working way to get serif text rather than the sans-only named faces
-- ("cfont" etc.) every other named face in this codebase maps to.
local SERIF_BOLD = "NotoSerif-Bold.ttf"
local SERIF_ITALIC = "NotoSerif-Italic.ttf"

-- Ink colors, matched to the design tokens' exact hex values against
-- KOReader's fixed 16-shade grayscale palette (ffi/blitbuffer.lua):
-- #1a1a1a (primary ink/borders) -> COLOR_BLACK, #555555 (author) ->
-- COLOR_GRAY_5 (0x55, an exact match), #777777 (meta/labels) ->
-- COLOR_GRAY_7 (0x77, exact), #999999 (chevron) -> COLOR_GRAY_9 (0x99,
-- exact), #dddddd (row dividers) -> COLOR_GRAY_D, #eeeeee (subheader
-- hairline) -> COLOR_GRAY_E, #cccccc (header hairline) -> COLOR_LIGHT_GRAY.
local INK = Blitbuffer.COLOR_BLACK
local AUTHOR_COLOR = Blitbuffer.COLOR_GRAY_5
local META_COLOR = Blitbuffer.COLOR_GRAY_7
local ROW_DIVIDER_COLOR = Blitbuffer.COLOR_GRAY_D
local HEADER_DIVIDER_COLOR = Blitbuffer.COLOR_LIGHT_GRAY
local SUBHEADER_DIVIDER_COLOR = Blitbuffer.COLOR_GRAY_E
local BORDER = S(1.5)

-- ---- Header (title row) ------------------------------------------------
-- Two header shapes in the design, not one: the shelf spreads its title
-- to the left edge and a button row to the right ("spread"); search and
-- the language picker put a single back-chevron button and the title
-- side by side at the left edge instead ("leading"). Forcing both through
-- one shape was the actual bug in the previous pass -- the search
-- header's back button was being pinned to the far right of a title that
-- should instead sit right next to it.
local HEADER_H_PADDING = S(24)
local SPREAD_V_PADDING = S(22)
local SPREAD_TITLE_FACE_SIZE = 34
local SPREAD_BTN_SIZE = S(42)
local SPREAD_BTN_GAP = S(10)

local LEADING_V_PADDING = S(20)
local LEADING_TITLE_FACE_SIZE = 29
local LEADING_BTN_SIZE = S(38)
local LEADING_GAP = S(14)

-- The in-book modal is a small centered card (as little as ~350px tall
-- for a handful of rows, see BookList.build's own content-sized height),
-- not a full screen -- the header padding/title size above were tuned
-- for the full-screen shelf/search pages and read as oversized once the
-- surrounding card shrank to fit its actual content.
local IN_BOOK_MAX_HEIGHT_FRACTION = 0.65
local IN_BOOK_HEADER_H_PADDING = S(14)
local IN_BOOK_SPREAD_V_PADDING = S(10)
local IN_BOOK_SPREAD_TITLE_FACE_SIZE = 20
local IN_BOOK_LEADING_V_PADDING = S(10)
local IN_BOOK_LEADING_TITLE_FACE_SIZE = 18

local SUBHEADER_V_PADDING = S(8)
local SUBHEADER_FACE_SIZE = 17

-- ---- Search bar (fake field + language chip, both just open a popup on
-- tap -- see shelf_ui.lua's _editSearchQuery/chooseSearchLanguage) ------
local SEARCH_BAR_HEIGHT = S(44)
local SEARCH_BAR_V_PADDING = S(16)
local SEARCH_BAR_GAP = S(8)
local SEARCH_FIELD_FACE_SIZE = 16
local SEARCH_FIELD_H_PADDING = S(14)
local CHIP_H_PADDING = S(14)
local CHIP_GAP = S(6)
local CHIP_FACE_SIZE = 13
local CHIP_ARROW_SIZE = S(10)

-- ---- Row -----------------------------------------------------------
local ROW_V_PADDING = S(14)
local ROW_H_PADDING = S(24)
local ROW_GAP = S(14)

local COVER_W = S(64)
local COVER_H = S(92)
local COVER_LETTER_FACE_SIZE = 25

local TITLE_FACE_SIZE = 20
local AUTHOR_FACE_SIZE = 15
-- Same "small centered card, not a full screen" reasoning as the in-book
-- header sizes above -- these rows were tuned for the full-screen shelf/
-- search pages, and read as oversized inside the compact in-book card.
local IN_BOOK_TITLE_FACE_SIZE = 15
local IN_BOOK_AUTHOR_FACE_SIZE = 12
local TITLE_TAG_GAP = S(8)
local STACK_GAP = S(5)
-- Tighter than STACK_GAP -- title-to-author sits closer together than the
-- other stacked blocks (a wrapped title dropping its tag below, or the
-- title block to the progress section).
local TITLE_AUTHOR_GAP = S(1)
local TAG_FACE_SIZE = 11
local TAG_RADIUS = S(16)

-- Bar is drawn noticeably thicker than the design's own 5px hairline-thin
-- track, and only spans half its column's width rather than the full
-- text column (the design itself caps this at 300px against a ~460px
-- text column -- roughly half -- rather than filling it).
local PROGRESS_TOP_GAP = S(9) -- design's flex "gap:5" plus the progress block's own "margin-top:4"
local PROGRESS_HEIGHT = S(9)
local PROGRESS_WIDTH_FRACTION = 0.5
local PROGRESS_META_GAP = S(4)
local META_FACE_SIZE = 13

local CHEVRON_SIZE = S(20)
local CHEVRON_LEFT_PAD = S(12)
local CHEVRON_COL_WIDTH = CHEVRON_SIZE + CHEVRON_LEFT_PAD

-- A rounded-corner pill outline, e.g. "The Broken Earth, #1" -- border
-- only, no fill (the design's own tag has no background set), radius
-- large enough to read as a true pill rather than a slightly-rounded
-- rectangle.
local function buildSeriesTag(text)
  local label = TextWidget:new{
    text = text,
    face = Font:getFace("cfont", TAG_FACE_SIZE),
    fgcolor = INK,
  }
  return FrameContainer:new{
    bordersize = Size.border.default,
    color = INK,
    background = Blitbuffer.COLOR_WHITE,
    radius = TAG_RADIUS,
    padding_top = S(3),
    padding_bottom = S(3),
    padding_left = S(10),
    padding_right = S(10),
    margin = 0,
    label,
  }
end

local function buildCoverPlaceholder(title)
  local initial = (title and title:sub(1, 1) or "?"):upper()
  local letter = TextWidget:new{
    text = initial,
    face = Font:getFace(SERIF_BOLD, COVER_LETTER_FACE_SIZE),
    fgcolor = INK,
  }
  -- The design's cover placeholder is a diagonal-hatch fill with a
  -- near-opaque white panel (the initial) drawn on top of the whole box,
  -- which in practice reads as a plain white box with a centered letter --
  -- there's no existing precedent in this codebase for painting a
  -- repeating diagonal pattern, so this reproduces the visible result
  -- (white box, bordered, centered initial) rather than inventing one.
  --
  -- The inner CenterContainer is sized to the box minus its border
  -- (rather than the box's own full width/height) -- FrameContainer
  -- paints its child inset by the border thickness without shrinking the
  -- child's own reported size to match, so giving the CenterContainer the
  -- full outer size shifts its centering box past the actual bordered
  -- edge and the letter renders off-center.
  return FrameContainer:new{
    bordersize = BORDER,
    color = INK,
    background = Blitbuffer.COLOR_WHITE,
    radius = 0,
    padding = 0,
    margin = 0,
    width = COVER_W,
    height = COVER_H,
    CenterContainer:new{
      dimen = Geom:new{ w = COVER_W - 2 * BORDER, h = COVER_H - 2 * BORDER },
      letter,
    },
  }
end

-- Real cover when it's already been fetched and cached to disk (a plain
-- ImageWidget, scale_factor=0 so it's fit-within-bounds keeping its own
-- aspect ratio rather than stretched to exactly COVER_W x COVER_H);
-- otherwise the letter placeholder, plus a descriptor for the caller to
-- queue a background fetch so the *next* time this book's row is built,
-- its real cover is already on disk. No live swap-in on THIS view once
-- the fetch finishes -- rebuilding the on-screen row from inside an
-- async callback risks corrupting whatever ScrollableContainer/e-ink
-- partial-refresh state is live at that moment, which isn't something
-- worth risking blind, without a device to actually watch it happen on.
-- A cover that's slow to appear (next open, not this one) is a small
-- price for that.
local function buildCover(item)
  if item.cover_url and CoverCache:isCached(item.book_id, item.cover_url) then
    local image = ImageWidget:new{
      file = CoverCache:path(item.book_id, item.cover_url),
      width = COVER_W - 2 * BORDER,
      height = COVER_H - 2 * BORDER,
      scale_factor = 0,
    }
    return FrameContainer:new{
      bordersize = BORDER,
      color = INK,
      background = Blitbuffer.COLOR_WHITE,
      radius = 0,
      padding = 0,
      margin = 0,
      width = COVER_W,
      height = COVER_H,
      CenterContainer:new{
        dimen = Geom:new{ w = COVER_W - 2 * BORDER, h = COVER_H - 2 * BORDER },
        image,
      },
    }, nil
  end

  local placeholder = buildCoverPlaceholder(item.title)
  local prefetch
  if item.cover_url then
    prefetch = { book_id = item.book_id, url = item.cover_url }
  end
  return placeholder, prefetch
end

local MONTH_NAMES = {
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
}

-- ISO date/timestamp string -> "Mon D" (e.g. "Aug 12"), matching the
-- design handoff's own sample data, rather than a full date parser --
-- same just-take-what-you-need approach as shelf_ui.lua's own
-- release_date year extraction (editionListItem).
local function formatStartedDate(iso)
  if not iso then
    return nil
  end
  local year, month, day = iso:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
  if not year then
    return nil
  end
  local name = MONTH_NAMES[tonumber(month)]
  if not name then
    return nil
  end
  return name .. " " .. tostring(tonumber(day))
end

-- Progress bar + "{pages}p - started {date} - {pct}%" meta line, fed by
-- Hardcover's own progress_pages/started_at (hardcover_api.lua's
-- listByStatus). Only shown when both a page count and a reading-progress
-- record exist -- most books, including every manga volume read through
-- Rakuyomi, have neither, so this is silently absent for them rather than
-- showing an empty or zeroed-out bar.
--
-- progress_pages itself is treated as 0 when nil, not as "no session" --
-- Hardcover's own API normalizes an explicit 0 to null server-side
-- (confirmed live: a freshly-created zero-progress session comes back
-- with progress_pages: null, not 0), and manually adding a progress
-- update on Hardcover's own site without changing anything leaves it the
-- same way. A session existing at all, regardless of its progress_pages
-- value, is what "started reading, 0% so far" actually means here.
local function buildProgressSection(item, width)
  local progress = item.reading_progress
  if not progress or not item.pages or item.pages <= 0 then
    return nil
  end

  local pages_read = progress.progress_pages or 0
  local pct = pages_read / item.pages
  if pct < 0 then pct = 0 end
  if pct > 1 then pct = 1 end

  local bar_width = math.floor(width * PROGRESS_WIDTH_FRACTION)
  local bar = ProgressWidget:new{
    width = bar_width,
    height = PROGRESS_HEIGHT,
    percentage = pct,
    margin_h = 0,
    margin_v = 0,
    radius = 0,
    bordercolor = INK,
    bgcolor = Blitbuffer.COLOR_GRAY_E,
    fillcolor = INK,
  }

  local pct_text = tostring(math.floor(pct * 100 + 0.5)) .. "%"
  local started = formatStartedDate(progress.started_at)
  local meta_text
  if started then
    meta_text = string.format(_("%dp - started %s - %s"), item.pages, started, pct_text)
  else
    meta_text = string.format(_("%dp - %s"), item.pages, pct_text)
  end

  return VerticalGroup:new{
    align = "left",
    bar,
    VerticalSpan:new{ width = PROGRESS_META_GAP },
    TextWidget:new{
      text = meta_text,
      face = Font:getFace("cfont", META_FACE_SIZE),
      fgcolor = META_COLOR,
      max_width = width,
    },
  }
end

-- Title + optional series tag, inline (matching the design's own
-- inline-flex row) whenever the title's real, untruncated width actually
-- leaves room for the tag; otherwise the title wraps across as many lines
-- as it needs (no ellipsis) and the tag drops to its own line below.
--
-- The two-path split exists because of a real widget limitation:
-- TextBoxWidget (the only widget here that wraps) always reserves its
-- full given width regardless of the actual text length (confirmed
-- earlier in this file's own history -- this was the exact bug that used
-- to push the tag to a fixed offset instead of right after the title), so
-- it can't sit next to a tag and have the tag trail the real text. A
-- single-line TextWidget can (its :getSize() reflects what's actually
-- drawn), so that's used whenever the title fits, which every title in
-- the design's own sample data does.
local function buildTitleAndTag(item, width, in_book)
  local title_face_size = in_book and IN_BOOK_TITLE_FACE_SIZE or TITLE_FACE_SIZE
  local tag, tag_width = nil, 0
  if item.series_tag then
    tag = buildSeriesTag(item.series_tag)
    tag_width = tag:getSize().w + TITLE_TAG_GAP
  end

  local natural_title = TextWidget:new{
    text = item.title,
    face = Font:getFace(SERIF_BOLD, title_face_size),
  }
  local natural_w = natural_title:getSize().w

  if natural_w <= width - tag_width then
    if tag then
      return HorizontalGroup:new{
        align = "center",
        natural_title,
        HorizontalSpan:new{ width = TITLE_TAG_GAP },
        tag,
      }
    end
    return natural_title
  end

  local wrapped = VerticalGroup:new{
    align = "left",
    TextBoxWidget:new{
      text = item.title,
      face = Font:getFace(SERIF_BOLD, title_face_size),
      width = width,
    },
  }
  if tag then
    table.insert(wrapped, VerticalSpan:new{ width = STACK_GAP })
    table.insert(wrapped, tag)
  end
  return wrapped
end

local function buildRowText(item, width, in_book)
  local author_face_size = in_book and IN_BOOK_AUTHOR_FACE_SIZE or AUTHOR_FACE_SIZE
  local lines = VerticalGroup:new{ align = "left", buildTitleAndTag(item, width, in_book) }

  if item.author then
    table.insert(lines, VerticalSpan:new{ width = TITLE_AUTHOR_GAP })
    table.insert(lines, TextBoxWidget:new{
      text = item.author,
      face = Font:getFace(SERIF_ITALIC, author_face_size),
      fgcolor = AUTHOR_COLOR,
      width = width,
    })
  end

  local progress = buildProgressSection(item, width)
  if progress then
    table.insert(lines, VerticalSpan:new{ width = PROGRESS_TOP_GAP })
    table.insert(lines, progress)
  end

  return lines
end

-- A plain already-built widget made tappable -- same minimal
-- tap-gesture pattern as BookRow below, just wrapping arbitrary content
-- instead of a book row specifically. Used for the search bar's fake
-- field and language chip, which are static visuals that open a popup on
-- tap rather than anything that renders its own pressed state.
local TapArea = InputContainer:extend{
  widget = nil,
  callback = nil,
  show_parent = nil,
}

function TapArea:init()
  self[1] = self.widget
  local size = self.widget:getSize()
  self.dimen = Geom:new{ w = size.w, h = size.h }
  if Device:isTouchDevice() then
    self.ges_events = {
      Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
  end
end

function TapArea:onTap()
  if self.callback then
    self.callback()
  end
  return true
end

local BookRow = InputContainer:extend{
  item = nil,
  width = nil,
  callback = nil,
  show_parent = nil,
  in_book = nil,
  pending_covers = nil, -- shared table this row appends a { book_id, url } to if its cover needs fetching
}

function BookRow:init()
  local content_width = self.width - 2 * ROW_H_PADDING
  local content

  if self.item.title then
    -- A book row: cover placeholder, title/author/series-tag/progress
    -- column, chevron pinned to the row's right edge. Top-aligned rather
    -- than vertically centered -- centering the whole row on its tallest
    -- element (the cover) meant the title's position shifted up or down
    -- depending on whether a given row had a progress bar under it; top
    -- alignment keeps the title at the same fixed offset in every row.
    --
    -- The text column is wrapped in a LeftContainer sized to its own
    -- natural height (not lines_h, which can be taller when the cover
    -- dominates) specifically so that wrapping adds zero vertical offset
    -- -- LeftContainer centers its child vertically within whatever
    -- height it's given, so giving it the content's *own* height keeps
    -- the top-alignment above intact, while still fixing its *width* to
    -- text_col_width. That width fix matters for any row short enough to
    -- have no author/tag/progress under the title (a plain title with no
    -- other book data) -- without it, the chevron's RightContainer gets
    -- positioned right after the title's own short natural width instead
    -- of at the row's true right edge, since HorizontalGroup places each
    -- child using its neighbor's actual measured size.
    local text_col_width = content_width - COVER_W - ROW_GAP - CHEVRON_COL_WIDTH - ROW_GAP
    local lines = buildRowText(self.item, text_col_width, self.in_book)
    local lines_h = math.max(lines:getSize().h, COVER_H)

    local cover, prefetch = buildCover(self.item)
    if prefetch and self.pending_covers then
      table.insert(self.pending_covers, prefetch)
    end

    content = HorizontalGroup:new{
      align = "top",
      cover,
      HorizontalSpan:new{ width = ROW_GAP },
      LeftContainer:new{
        dimen = Geom:new{ w = text_col_width, h = lines:getSize().h },
        lines,
      },
      HorizontalSpan:new{ width = ROW_GAP },
      RightContainer:new{
        dimen = Geom:new{ w = CHEVRON_COL_WIDTH, h = lines_h },
        IconWidget:new{
          icon = "chevron.right",
          width = CHEVRON_SIZE,
          height = CHEVRON_SIZE,
        },
      },
    }
  else
    local text_width = content_width
    local icon
    if self.item.icon then
      icon = IconWidget:new{
        icon = self.item.icon,
        width = S(20),
        height = S(20),
      }
      text_width = content_width - S(20) - Size.padding.default
    end

    local label = TextBoxWidget:new{
      text = self.item.text,
      face = Font:getFace("cfont", 22),
      bold = self.item.accent or nil,
      fgcolor = self.item.dim and META_COLOR or nil,
      width = text_width,
    }

    if icon then
      content = HorizontalGroup:new{
        align = "center",
        icon,
        HorizontalSpan:new{ width = Size.padding.default },
        label,
      }
    else
      content = label
    end
  end

  self.frame = FrameContainer:new{
    bordersize = 0,
    padding_top = ROW_V_PADDING,
    padding_bottom = ROW_V_PADDING,
    padding_left = ROW_H_PADDING,
    padding_right = ROW_H_PADDING,
    margin = 0,
    width = self.width,
    content,
  }
  self[1] = self.frame

  self.dimen = Geom:new{ w = self.width, h = self.frame:getSize().h }
  if Device:isTouchDevice() then
    self.ges_events = {
      Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
  end
end

function BookRow:onTap()
  if self.callback then
    self.callback()
  end
  return true
end

-- A bordered square button wrapping a stock IconButton for the tap/hold/
-- flash handling it already has -- IconButton itself draws no border, so
-- this is just IconButton centered inside a bordered FrameContainer.
local function buildIconButton(icon_name, callback, btn_size)
  local icon_size = S(20)
  local pad = math.floor((btn_size - icon_size) / 2)
  local icon_btn = IconButton:new{
    icon = icon_name,
    width = icon_size,
    height = icon_size,
    padding = pad,
    callback = callback,
  }
  local frame = FrameContainer:new{
    bordersize = BORDER,
    color = INK,
    background = Blitbuffer.COLOR_WHITE,
    radius = 0,
    padding = 0,
    margin = 0,
    CenterContainer:new{
      dimen = Geom:new{ w = btn_size, h = btn_size },
      icon_btn,
    },
  }
  return frame, icon_btn
end

-- "Spread" header: left-aligned bold serif title, one or more bordered
-- square buttons pinned to the right edge (the shelf's search/refresh/
-- close trio). `buttons` is a list of { icon, callback }.
local function buildSpreadHeader(title, width, buttons, in_book)
  local h_padding = in_book and IN_BOOK_HEADER_H_PADDING or HEADER_H_PADDING
  local v_padding = in_book and IN_BOOK_SPREAD_V_PADDING or SPREAD_V_PADDING
  local title_face_size = in_book and IN_BOOK_SPREAD_TITLE_FACE_SIZE or SPREAD_TITLE_FACE_SIZE

  local inner_w = width - 2 * h_padding
  local icon_btns = {}
  local btn_frames = {}
  local buttons_width = 0
  for i, btn in ipairs(buttons) do
    if i > 1 then
      buttons_width = buttons_width + SPREAD_BTN_GAP
    end
    local frame, icon_btn = buildIconButton(btn.icon, btn.callback, SPREAD_BTN_SIZE)
    table.insert(btn_frames, frame)
    table.insert(icon_btns, icon_btn)
    buttons_width = buttons_width + SPREAD_BTN_SIZE
  end

  local title_max_width = inner_w - buttons_width - (buttons_width > 0 and SPREAD_BTN_GAP or 0)
  local title_widget = TextWidget:new{
    text = title,
    face = Font:getFace(SERIF_BOLD, title_face_size),
    max_width = title_max_width,
  }
  local row_h = math.max(title_widget:getSize().h, SPREAD_BTN_SIZE)

  local left = LeftContainer:new{
    dimen = Geom:new{ w = inner_w, h = row_h },
    title_widget,
  }

  local overlap
  if #btn_frames > 0 then
    local buttons_row = HorizontalGroup:new{ align = "center" }
    for i, frame in ipairs(btn_frames) do
      if i > 1 then
        table.insert(buttons_row, HorizontalSpan:new{ width = SPREAD_BTN_GAP })
      end
      table.insert(buttons_row, frame)
    end
    overlap = OverlapGroup:new{
      dimen = Geom:new{ w = inner_w, h = row_h },
      allow_mirroring = false,
      left,
      RightContainer:new{ dimen = Geom:new{ w = inner_w, h = row_h }, buttons_row },
    }
  else
    overlap = OverlapGroup:new{
      dimen = Geom:new{ w = inner_w, h = row_h },
      allow_mirroring = false,
      left,
    }
  end

  local padded = FrameContainer:new{
    bordersize = 0,
    padding = 0,
    padding_top = v_padding,
    padding_bottom = v_padding,
    padding_left = h_padding,
    padding_right = h_padding,
    margin = 0,
    width = width,
    overlap,
  }

  return VerticalGroup:new{
    align = "left",
    padded,
    LineWidget:new{ dimen = Geom:new{ w = width, h = Size.line.thin }, background = HEADER_DIVIDER_COLOR },
  }, icon_btns
end

-- "Leading" header: a single bordered back-chevron button, then the title
-- immediately beside it, both left-aligned (search results, language
-- picker) -- a different shape from the shelf's spread header, not the
-- same one with fewer buttons: the title sits right next to the button
-- here, it doesn't get pushed to the opposite edge.
-- close_button (optional) pins a second bordered icon button to the
-- right edge of the same row -- e.g. search results' own "X" for
-- dismissing the whole plugin without first going back to the shelf and
-- closing it from there. Same OverlapGroup + Left/RightContainer shape
-- buildSpreadHeader already uses for pinning its own buttons to the
-- right edge, layered on top of this row instead of the plain title
-- widget spread uses on its left side.
local function buildLeadingHeader(title, width, back_button, in_book, close_button)
  local h_padding = in_book and IN_BOOK_HEADER_H_PADDING or HEADER_H_PADDING
  local v_padding = in_book and IN_BOOK_LEADING_V_PADDING or LEADING_V_PADDING
  local title_face_size = in_book and IN_BOOK_LEADING_TITLE_FACE_SIZE or LEADING_TITLE_FACE_SIZE
  local inner_w = width - 2 * h_padding

  local close_frame, close_icon_btn
  local close_reserved = 0
  if close_button then
    close_frame, close_icon_btn = buildIconButton(close_button.icon, close_button.callback, LEADING_BTN_SIZE)
    close_reserved = LEADING_BTN_SIZE + LEADING_GAP
  end

  local frame, icon_btn = buildIconButton(back_button.icon, back_button.callback, LEADING_BTN_SIZE)
  local title_widget = TextWidget:new{
    text = title,
    face = Font:getFace(SERIF_BOLD, title_face_size),
    max_width = inner_w - LEADING_BTN_SIZE - LEADING_GAP - close_reserved,
  }

  local row = HorizontalGroup:new{
    align = "center",
    frame,
    HorizontalSpan:new{ width = LEADING_GAP },
    title_widget,
  }

  local icon_btns = { icon_btn }
  local content = row
  if close_button then
    local row_h = math.max(row:getSize().h, LEADING_BTN_SIZE)
    content = OverlapGroup:new{
      dimen = Geom:new{ w = inner_w, h = row_h },
      allow_mirroring = false,
      LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = row_h }, row },
      RightContainer:new{ dimen = Geom:new{ w = inner_w, h = row_h }, close_frame },
    }
    table.insert(icon_btns, close_icon_btn)
  end

  local padded = FrameContainer:new{
    bordersize = 0,
    padding = 0,
    padding_top = v_padding,
    padding_bottom = v_padding,
    padding_left = h_padding,
    padding_right = h_padding,
    margin = 0,
    width = width,
    content,
  }

  return VerticalGroup:new{
    align = "left",
    padded,
    LineWidget:new{ dimen = Geom:new{ w = width, h = Size.line.thin }, background = HEADER_DIVIDER_COLOR },
  }, icon_btns
end

-- Subheader strip below the header, e.g. "Currently Reading - 6 books -
-- Updated just now", with its own (lighter) hairline underneath.
local function buildSubheader(text, width)
  return VerticalGroup:new{
    align = "left",
    FrameContainer:new{
      bordersize = 0,
      padding_top = SUBHEADER_V_PADDING,
      padding_bottom = SUBHEADER_V_PADDING,
      padding_left = HEADER_H_PADDING,
      padding_right = HEADER_H_PADDING,
      margin = 0,
      width = width,
      TextWidget:new{
        text = text,
        face = Font:getFace("cfont", SUBHEADER_FACE_SIZE),
        fgcolor = META_COLOR,
        max_width = width - 2 * HEADER_H_PADDING,
      },
    },
    LineWidget:new{ dimen = Geom:new{ w = width, h = Size.line.thin }, background = SUBHEADER_DIVIDER_COLOR },
  }
end

-- The search bar's fake text field -- looks like a real input (bordered
-- box, query text or a grayed-out hint) but only ever opens a popup on
-- tap (see shelf_ui.lua's _editSearchQuery); it's not an editable widget.
--
-- The label is wrapped in a LeftContainer with an explicit dimen instead
-- of forcing width/height directly on the FrameContainer -- the same fix
-- as buildCoverPlaceholder's CenterContainer above, for the same
-- underlying reason: FrameContainer:getSize() computes its own reported
-- size from its child's size plus padding/border, ignoring any forced
-- width/height field entirely, while paintTo *does* honor a forced
-- width/height for what it actually draws. Force one directly (as this
-- function's first version did) and the two go out of sync: whatever
-- else measures this widget via getSize() -- here, the HorizontalGroup
-- placing the language chip right after it -- sees a box only as wide as
-- the label's own short text, while the visible bordered box paints at
-- the full intended width. The label ends up sharing space with a chip
-- positioned as if the field were much narrower than it's drawn, and the
-- field's real right portion renders as a separate-looking empty box.
-- Giving the inner content its own explicit dimen sidesteps the forced
-- override path entirely: FrameContainer's normal content+padding+border
-- formula then reconstructs the exact intended size on its own.
local function buildSearchField(text, hint, width)
  local has_value = text and text:match("%S")
  local inner_w = width - 2 * BORDER - 2 * SEARCH_FIELD_H_PADDING
  local inner_h = SEARCH_BAR_HEIGHT - 2 * BORDER
  local label = TextWidget:new{
    text = has_value and text or hint,
    face = Font:getFace("cfont", SEARCH_FIELD_FACE_SIZE),
    fgcolor = has_value and INK or META_COLOR,
    max_width = inner_w,
  }
  return FrameContainer:new{
    bordersize = BORDER,
    color = INK,
    background = Blitbuffer.COLOR_WHITE,
    radius = 0,
    padding_top = 0,
    padding_bottom = 0,
    padding_left = SEARCH_FIELD_H_PADDING,
    padding_right = SEARCH_FIELD_H_PADDING,
    margin = 0,
    LeftContainer:new{
      dimen = Geom:new{ w = inner_w, h = inner_h },
      label,
    },
  }
end

-- The language chip ("EN ▾") -- a down-chevron synthesized by rotating
-- the up-chevron icon 180 degrees, since resources/icons/mdlight has no
-- dedicated down-chevron file (confirmed: only first/last/left/right/up).
-- Same fixed-dimen-wrapper approach as buildSearchField, for the same
-- reason -- here sized to the content's own natural width (no separate
-- outer width to reconcile against, since the chip isn't stretched to
-- fill any particular column).
local function buildLanguageChip(label_text)
  local label = TextWidget:new{
    text = label_text,
    face = Font:getFace("cfont", CHIP_FACE_SIZE),
    fgcolor = INK,
  }
  local content = HorizontalGroup:new{
    align = "center",
    label,
    HorizontalSpan:new{ width = CHIP_GAP },
    IconWidget:new{
      icon = "chevron.up",
      rotation_angle = 180,
      width = CHIP_ARROW_SIZE,
      height = CHIP_ARROW_SIZE,
    },
  }
  local content_size = content:getSize()
  local inner_h = SEARCH_BAR_HEIGHT - 2 * BORDER
  return FrameContainer:new{
    bordersize = BORDER,
    color = INK,
    background = Blitbuffer.COLOR_WHITE,
    radius = 0,
    padding_top = 0,
    padding_bottom = 0,
    padding_left = CHIP_H_PADDING,
    padding_right = CHIP_H_PADDING,
    margin = 0,
    CenterContainer:new{
      dimen = Geom:new{ w = content_size.w, h = inner_h },
      content,
    },
  }
end

-- Search-bar row (field + language chip) plus its own hairline below,
-- same shape as buildSubheader. cfg: { query_text, query_hint,
-- on_query_tap, language_label, on_language_tap }. Returns the block
-- widget plus the two TapAreas, so the caller can give them a real
-- show_parent the same way every row and header button already gets one.
local function buildSearchBarBlock(cfg, width)
  local inner_w = width - 2 * HEADER_H_PADDING
  local chip = buildLanguageChip(cfg.language_label)
  local chip_w = chip:getSize().w
  local field_w = inner_w - chip_w - SEARCH_BAR_GAP
  local field = buildSearchField(cfg.query_text, cfg.query_hint, field_w)

  local field_tap = TapArea:new{ widget = field, callback = cfg.on_query_tap }
  local chip_tap = TapArea:new{ widget = chip, callback = cfg.on_language_tap }

  local row = HorizontalGroup:new{
    align = "top",
    field_tap,
    HorizontalSpan:new{ width = SEARCH_BAR_GAP },
    chip_tap,
  }

  local padded = FrameContainer:new{
    bordersize = 0,
    padding = 0,
    padding_top = SEARCH_BAR_V_PADDING,
    padding_bottom = SEARCH_BAR_V_PADDING,
    padding_left = HEADER_H_PADDING,
    padding_right = HEADER_H_PADDING,
    margin = 0,
    width = width,
    row,
  }

  local block = VerticalGroup:new{
    align = "left",
    padded,
    LineWidget:new{ dimen = Geom:new{ w = width, h = Size.line.thin }, background = SUBHEADER_DIVIDER_COLOR },
  }

  return block, { field_tap, chip_tap }
end

local BookList = {}

-- Builds and returns the widget to pass to UIManager:show()/close(). Not
-- shown here, the caller does that, same as the Menu-based version this
-- replaced, so shelf_ui.lua's overlay-stacking logic (search/edition
-- picker/status picker layering on top without closing the shelf) doesn't
-- need to change at all, only how the list itself is built.
--
-- item_table entries are either a book row ("title" field, required;
-- "author", "series_tag", "pages" and "reading_progress" optional) or a
-- plain row ("text" field instead, no title/author split -- used for
-- editions/languages). Either kind may set "accent" (bold text), "dim"
-- (gray text -- for informational rows like an empty-shelf message), or
-- "icon" (a stock icon name from resources/icons/mdlight, shown leading
-- the text). Any other fields the caller needs (book_id, row_id,
-- edition_id...) pass straight through to on_select untouched.
--
-- `opts` (optional):
--   header_buttons = { { icon, callback }, ... } -- shelf-style spread
--     header (title left, buttons right).
--   back_button = { icon, callback } -- search/language-picker-style
--     leading header (back button, then title).
--   close_button = { icon, callback } -- optional second button pinned
--     to the right edge of a leading header (only meaningful alongside
--     back_button) -- e.g. search results' own dismiss-the-whole-plugin
--     button, so you don't have to go back to the shelf just to close it
--     from there.
--   subheader = "text" -- shown below the header (and the search bar, if
--     any) with its own hairline.
--   search_bar = { query_text, query_hint, on_query_tap, language_label,
--     on_language_tap } -- a fake text field + language chip, both of
--     which just open a popup on tap (see book_list.lua's own
--     buildSearchBarBlock) rather than being live-editable.
-- Without header_buttons or back_button, falls back to a plain spread
-- header with no buttons at all (still used by the edition/status/
-- language overlays this phase hasn't touched yet).
function BookList.build(title, item_table, in_book, on_select, on_close, opts)
  opts = opts or {}
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local width
  if in_book then
    width = math.min(screen_w - S(50), S(600))
  else
    width = screen_w
  end

  local header_widget, header_icon_btns
  if opts.back_button then
    header_widget, header_icon_btns = buildLeadingHeader(title, width, opts.back_button, in_book, opts.close_button)
  else
    header_widget, header_icon_btns = buildSpreadHeader(title, width, opts.header_buttons or {}, in_book)
  end

  local header_stack = VerticalGroup:new{ align = "left", header_widget }
  if opts.search_bar then
    local search_bar_block, search_bar_taps = buildSearchBarBlock(opts.search_bar, width)
    table.insert(header_stack, search_bar_block)
    for _, tap in ipairs(search_bar_taps) do
      table.insert(header_icon_btns, tap)
    end
  end
  if opts.subheader then
    table.insert(header_stack, buildSubheader(opts.subheader, width))
  end

  -- Rows must be narrower than the full list width by the vertical
  -- scrollbar's own reserved space, or the content is technically wider
  -- than the scrollable viewport once that scrollbar appears (any list
  -- with enough rows to need vertical scrolling), which registers as a
  -- few pixels of horizontal overflow and triggers an unwanted, useless
  -- horizontal scrollbar. Reserved unconditionally rather than only when
  -- scrolling turns out to be needed, since row widths are fixed before
  -- the total content height (and therefore whether scrolling is needed
  -- at all) is known.
  local scrollbar_reserve = ScrollableContainer:getScrollbarWidth()
  local row_width = width - scrollbar_reserve

  local rows = VerticalGroup:new{ align = "left" }
  local book_rows = {}
  local pending_covers = {}
  for _, item in ipairs(item_table) do
    local row = BookRow:new{
      item = item,
      width = row_width,
      callback = function() on_select(item) end,
      in_book = in_book,
      pending_covers = pending_covers,
    }
    table.insert(book_rows, row)
    table.insert(rows, row)
    table.insert(rows, LineWidget:new{
      dimen = Geom:new{ w = row_width, h = Size.line.thin },
      background = ROW_DIVIDER_COLOR,
    })
  end

  -- Any row whose cover isn't cached yet queued a fetch above -- doesn't
  -- touch this screen's own widgets once downloaded (see buildCover's own
  -- comment on why not), just warms the disk cache for next time.
  if #pending_covers > 0 then
    local cover_items = {}
    for _, p in ipairs(pending_covers) do
      table.insert(cover_items, {
        url = p.url,
        on_loaded = function(content)
          CoverCache:save(p.book_id, p.url, content)
        end,
      })
    end
    CoverLoader.loadAll(cover_items)
  end

  -- In-book: a fixed height, the same across the shelf and the search
  -- page regardless of how many rows either has -- a short list just
  -- leaves blank space below it rather than shrinking the card, so the
  -- overlay doesn't visibly change size depending on which screen you're
  -- on. A longer list still scrolls inside this same fixed height instead
  -- of growing past it. The non-in-book shelf/search pages keep filling
  -- the full screen regardless of content, as before.
  local header_h = header_stack:getSize().h
  local height
  if in_book then
    height = math.floor(screen_h * IN_BOOK_MAX_HEIGHT_FRACTION)
  else
    height = screen_h
  end

  local content_height = height - header_h
  local scroll_container = ScrollableContainer:new{
    dimen = Geom:new{ w = width, h = content_height },
    rows,
  }

  local outer = FrameContainer:new{
    bordersize = in_book and Size.border.window or 0,
    radius = in_book and Size.radius.window or 0,
    background = Blitbuffer.COLOR_WHITE,
    padding = 0,
    margin = 0,
    width = width,
    height = height,
    VerticalGroup:new{
      align = "left",
      header_stack,
      scroll_container,
    },
  }

  local top_widget = outer
  if in_book then
    top_widget = CenterContainer:new{
      dimen = Geom:new{ w = screen_w, h = screen_h },
      outer,
    }
  end

  -- ScrollableContainer's own header comment: it needs to be known as
  -- `cropping_widget` on the widget actually passed to UIManager:show(),
  -- or inner-element flashing leaks outside the scrollable area on tap.
  top_widget.cropping_widget = scroll_container
  header_stack.show_parent = top_widget
  scroll_container.show_parent = top_widget
  for _, row in ipairs(book_rows) do
    row.show_parent = top_widget
  end
  for _, icon_btn in ipairs(header_icon_btns) do
    icon_btn.show_parent = top_widget
  end

  return top_widget
end

-- Exposed so other custom modal widgets (e.g. lib/status_picker.lua) can
-- build the same bordered-icon-square chrome and the same "make an
-- already-built widget tappable" wrapper this file already uses,
-- instead of duplicating either construction.
BookList.buildIconButton = buildIconButton
BookList.TapArea = TapArea

return BookList
