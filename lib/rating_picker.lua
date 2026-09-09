--[[--
"Rate this Book" modal, shown only right after marking a book Read (see
shelf_ui.lua's own showStatusPicker -> pick(), the "marking_read" branch).
Matches the design handoff's own rating screen: 5 stars in half-star
steps, a live "X / 5" readout, and Skip/Save Rating buttons -- Skip closes
without ever calling the API (no rating recorded), Save always writes
whatever value is currently selected, including 0 (the design's own Save
button is never disabled, even at the untouched 0 default -- confirmed
against the mockup's own renderVals(), which never gates saveRating on
rating > 0).

Card/backdrop plumbing (DarkenOverlay, the OverlapGroup-centered card,
tap-outside-to-dismiss) is the same recipe lib/status_picker.lua already
uses and explains at length in its own header comment -- not repeated
here beyond what's specific to this screen.

Half-star mechanic: each star is a fixed-size box showing ONE of three
literal glyphs (full/half/empty) from KOReader's own bundled
fonts/nerdfonts/symbols.ttf (the "symbols" font face -- confirmed via
frontend/ui/font.lua, and already used the same way by this project's own
iconbrowser.koplugin for a single corner-star marker). This turned out
much simpler than the design's own CSS trick (stacking two full stars and
clipping the top one's box via overflow:hidden;width:X% for a partial
fill) -- no clip/blit compositing needed, just swapping which whole glyph
renders, because the symbols font already ships a genuine half-filled
star glyph. Codepoints and their real on-screen look (confirmed visually
by the user via iconbrowser.koplugin's own "symbols" browse category,
which lists these by name):
  - star.1          U+F005  solid star, slightly rounded edges (full)
  - star_empty      U+F006  white star, black outline (empty)
  - star_half_empty U+F123  full outline, half black / half white (half)
There's also a star_half (U+F089), which sounds right but isn't -- it's a
star shape literally cut in half, not a partial-fill indicator, and would
look broken here.

Two invisible tap zones per star (left half picks the .5 just below,
right half picks the next whole number), stacked over the glyph via
OverlapGroup -- same trick the design's own two overlapping onClick divs
use. Confirmed safe against a real gotcha before building this way:
TapArea extends InputContainer (not just WidgetContainer), and
InputContainer:paintTo() -- unlike WidgetContainer's own default --
actually writes the paint-time x/y into self.dimen every time it's
painted (frontend/ui/widget/container/inputcontainer.lua:81-82), which is
also what its GestureRange tap-hit-test reads. So each zone's hit area
tracks its real OverlapGroup-offset position correctly, even though nothing
here ever sets a dimen up front.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local _ = require("gettext")

local BookList = require("lib/book_list")
local TapArea = BookList.TapArea

local Screen = Device.screen
local S = function(px) return Screen:scaleBySize(px) end

local INK = Blitbuffer.COLOR_BLACK
local MUTED_COLOR = Blitbuffer.COLOR_GRAY_5 -- matches status_picker.lua's own #555555 author/label color

local SERIF_BOLD = "NotoSerif-Bold.ttf"
local SERIF_ITALIC = "NotoSerif-Italic.ttf"

-- Literal UTF-8 bytes for the three symbols-font codepoints above, same
-- safe-encoding convention status_picker.lua uses for its own checkmark
-- (U+2713) rather than a raw non-ASCII source character.
local STAR_GLYPH_FULL = "\xEF\x80\x85"  -- star.1, U+F005
local STAR_GLYPH_EMPTY = "\xEF\x80\x86" -- star_empty, U+F006
local STAR_GLYPH_HALF = "\xEF\x84\xA3"  -- star_half_empty, U+F123

-- Card layout, straight from the design handoff's own CSS (box/padding
-- pixels kept literal; only actually-read text gets the ~15-30% face-size
-- bump this plugin's other screens use -- a glyph rendered to fit a fixed
-- box, like the stars below, is sized to that box instead).
local CARD_BORDER = S(2)
local CARD_MAX_WIDTH = S(480)
local CARD_OUTER_PADDING = S(40)
local CARD_V_PADDING = S(28)
local CARD_H_PADDING = S(32)
local GROUP_GAP = S(20)

local HEADER_LABEL_FACE_SIZE = 16 -- bumped from the design's 14, matches status_picker's own label
local HEADER_GAP = S(12)
local CLOSE_BTN_SIZE = S(32)

local TITLE_FACE_SIZE = 23  -- bumped from the design's 20
local AUTHOR_FACE_SIZE = 16 -- bumped from the design's 14
local AUTHOR_GAP = S(5)

local STAR_BOX = S(52)
local STAR_GAP = S(10)
local STAR_FACE_SIZE = 44 -- literal from the design's own font-size:44 inside a 52px box

local RATING_LABEL_FACE_SIZE = 17 -- bumped from the design's 15

local BUTTON_GAP = S(14)
local BUTTON_HEIGHT = S(48)
local BUTTON_BORDER = S(1.5)
local BUTTON_FACE_SIZE = 17 -- matches status_picker's own Done button bump

local DIM_AMOUNT = 0.35 -- same tuned value as status_picker.lua's backdrop

-- Same real per-pixel dimming as status_picker.lua's own DarkenOverlay
-- (Blitbuffer:darkenRect(), not a flat opaque fill) -- duplicated here
-- rather than shared, matching this plugin's existing per-screen-file
-- convention (each modal file is self-contained).
local DarkenOverlay = Widget:extend{
  dimen = nil,
  by = DIM_AMOUNT,
}

function DarkenOverlay:paintTo(bb, x, y)
  bb:darkenRect(x, y, self.dimen.w, self.dimen.h, self.by)
end

local function buildCloseButton(callback)
  return (BookList.buildIconButton("close", callback, CLOSE_BTN_SIZE))
end

-- Header: uppercase "RATE THIS BOOK" label on the left, bordered close
-- ("X") button on the right -- same OverlapGroup + Left/RightContainer
-- shape as every other header row in this plugin, sized to content_w
-- exactly rather than forcing width on any bordered FrameContainer.
local function buildHeader(content_w, on_close)
  local label = TextWidget:new{
    text = _("RATE THIS BOOK"),
    face = Font:getFace("cfont", HEADER_LABEL_FACE_SIZE),
    bold = true,
    fgcolor = INK,
    max_width = content_w - CLOSE_BTN_SIZE - HEADER_GAP,
  }
  local close_btn = buildCloseButton(on_close)
  local row_h = math.max(label:getSize().h, CLOSE_BTN_SIZE)

  return OverlapGroup:new{
    dimen = Geom:new{ w = content_w, h = row_h },
    allow_mirroring = false,
    LeftContainer:new{ dimen = Geom:new{ w = content_w, h = row_h }, label },
    RightContainer:new{ dimen = Geom:new{ w = content_w, h = row_h }, close_btn },
  }
end

-- Book title (+ author, if given), centered as a block -- design's own
-- text-align:center on this container, which VerticalGroup's own
-- align="center" reproduces directly (centers each line against the
-- block's own natural width, and the outer card content centers the
-- whole block in turn).
local function buildTitleBlock(content_w, title, author)
  local title_widget = TextWidget:new{
    text = title,
    face = Font:getFace(SERIF_BOLD, TITLE_FACE_SIZE),
    max_width = content_w,
  }
  if not author then
    return title_widget
  end
  return VerticalGroup:new{
    align = "center",
    title_widget,
    VerticalSpan:new{ width = AUTHOR_GAP },
    TextWidget:new{
      text = author,
      face = Font:getFace(SERIF_ITALIC, AUTHOR_FACE_SIZE),
      fgcolor = MUTED_COLOR,
      max_width = content_w,
    },
  }
end

-- One star: a fixed STAR_BOX glyph (one of the three states above,
-- centered in its box) with two invisible tap zones stacked over it --
-- left half picks the half-step just below this star's own full value,
-- right half picks this star's own full value. The zones are plain
-- Widgets (base Widget:paintTo is a no-op, so nothing draws) sized via a
-- forced dimen and wrapped in TapArea just for the tap handling -- see
-- this file's own header comment for why their hit position still ends
-- up correct despite never setting dimen.x/y themselves.
local function buildStar(state, on_pick_half, on_pick_full)
  local glyph_char = STAR_GLYPH_EMPTY
  if state == "full" then
    glyph_char = STAR_GLYPH_FULL
  elseif state == "half" then
    glyph_char = STAR_GLYPH_HALF
  end

  local glyph = TextWidget:new{
    text = glyph_char,
    face = Font:getFace("symbols", STAR_FACE_SIZE),
    fgcolor = INK,
  }
  local centered = CenterContainer:new{
    dimen = Geom:new{ w = STAR_BOX, h = STAR_BOX },
    glyph,
  }

  local half_w = math.floor(STAR_BOX / 2)
  local left_zone = TapArea:new{
    widget = Widget:new{ dimen = Geom:new{ w = half_w, h = STAR_BOX } },
    callback = on_pick_half,
  }
  local right_zone = TapArea:new{
    widget = Widget:new{ dimen = Geom:new{ w = STAR_BOX - half_w, h = STAR_BOX } },
    callback = on_pick_full,
  }
  right_zone.overlap_offset = { half_w, 0 }

  return OverlapGroup:new{
    dimen = Geom:new{ w = STAR_BOX, h = STAR_BOX },
    allow_mirroring = false,
    centered,
    left_zone,
    right_zone,
  }
end

-- Five stars in a row, gapped and centered by the outer card content.
-- fill state per star matches the design's own renderVals() exactly:
-- full once rating reaches this star's whole number, half at its .5,
-- empty otherwise.
local function buildStarsRow(rating, on_set_rating)
  local row = HorizontalGroup:new{ align = "center" }
  for i = 0, 4 do
    local state = "empty"
    if rating >= i + 1 then
      state = "full"
    elseif rating >= i + 0.5 then
      state = "half"
    end
    if i > 0 then
      table.insert(row, HorizontalSpan:new{ width = STAR_GAP })
    end
    table.insert(row, buildStar(state, function() on_set_rating(i + 0.5) end, function() on_set_rating(i + 1) end))
  end
  return row
end

-- Skip / Save Rating, side by side, equal width -- unlike status_picker's
-- Done button, Save Rating is never disabled (the design never gates it
-- on rating > 0; Skip is the "don't record anything" action, Save always
-- writes the current value, 0 included).
local function buildButtonRow(content_w, on_skip, on_save)
  local btn_w = math.floor((content_w - BUTTON_GAP) / 2)
  local inner_w = btn_w - 2 * BUTTON_BORDER
  local inner_h = BUTTON_HEIGHT - 2 * BUTTON_BORDER

  local skip_btn = FrameContainer:new{
    bordersize = BUTTON_BORDER,
    color = INK,
    background = Blitbuffer.COLOR_WHITE,
    radius = 0,
    padding = 0,
    margin = 0,
    CenterContainer:new{
      dimen = Geom:new{ w = inner_w, h = inner_h },
      TextWidget:new{
        text = _("Skip"),
        face = Font:getFace("cfont", BUTTON_FACE_SIZE),
        bold = true,
        fgcolor = INK,
      },
    },
  }
  local save_btn = FrameContainer:new{
    bordersize = BUTTON_BORDER,
    color = INK,
    background = Blitbuffer.COLOR_BLACK,
    radius = 0,
    padding = 0,
    margin = 0,
    CenterContainer:new{
      dimen = Geom:new{ w = inner_w, h = inner_h },
      TextWidget:new{
        text = _("Save Rating"),
        face = Font:getFace("cfont", BUTTON_FACE_SIZE),
        bold = true,
        fgcolor = Blitbuffer.COLOR_WHITE,
      },
    },
  }

  return HorizontalGroup:new{
    align = "top",
    TapArea:new{ widget = skip_btn, callback = on_skip },
    HorizontalSpan:new{ width = BUTTON_GAP },
    TapArea:new{ widget = save_btn, callback = on_save },
  }
end

local RatingPicker = InputContainer:extend{
  book_title = nil,
  book_author = nil,
  rating = 0, -- internal, starts untouched at 0 same as the design's own chooseStatus('read') reset
  on_save = nil, -- (rating) -- Save Rating tapped
  on_skip = nil, -- Skip, the close (X), or a tap outside the card
}

function RatingPicker:init()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }

  local card_width = math.min(screen_w - 2 * CARD_OUTER_PADDING, CARD_MAX_WIDTH)
  local content_w = card_width - 2 * CARD_BORDER - 2 * CARD_H_PADDING
  self.content_w = content_w

  self.card = FrameContainer:new{
    bordersize = CARD_BORDER,
    color = INK,
    background = Blitbuffer.COLOR_WHITE,
    radius = 0,
    padding = 0,
    padding_top = CARD_V_PADDING,
    padding_bottom = CARD_V_PADDING,
    padding_left = CARD_H_PADDING,
    padding_right = CARD_H_PADDING,
    margin = 0,
    self:_buildCardContent(content_w),
  }

  local dim = DarkenOverlay:new{
    dimen = Geom:new{ w = screen_w, h = screen_h },
  }
  local centered_card = CenterContainer:new{
    dimen = Geom:new{ w = screen_w, h = screen_h },
    self.card,
  }

  self[1] = OverlapGroup:new{
    dimen = Geom:new{ w = screen_w, h = screen_h },
    allow_mirroring = false,
    dim,
    centered_card,
  }

  self.ges_events = {
    TapOutsideCard = { GestureRange:new{ ges = "tap", range = self.dimen } },
  }
end

function RatingPicker:onTapOutsideCard()
  self:_skip()
  return true
end

function RatingPicker:_buildCardContent(content_w)
  return VerticalGroup:new{
    align = "center",
    buildHeader(content_w, function() self:_skip() end),
    VerticalSpan:new{ width = GROUP_GAP },
    buildTitleBlock(content_w, self.book_title, self.book_author),
    VerticalSpan:new{ width = GROUP_GAP },
    buildStarsRow(self.rating, function(v) self:_setRating(v) end),
    VerticalSpan:new{ width = GROUP_GAP },
    TextWidget:new{
      text = ("%g / 5"):format(self.rating),
      face = Font:getFace("cfont", RATING_LABEL_FACE_SIZE),
      fgcolor = MUTED_COLOR,
    },
    VerticalSpan:new{ width = GROUP_GAP },
    buildButtonRow(content_w, function() self:_skip() end, function() self:_save() end),
  }
end

function RatingPicker:_setRating(v)
  self.rating = v
  self:_refresh()
end

-- Rebuilds the card's content in place and marks just this widget dirty,
-- same as status_picker.lua's own tile-tap refresh -- there's nothing to
-- refetch, only the locally-held rating value changed.
function RatingPicker:_refresh()
  self.card[1] = self:_buildCardContent(self.content_w)
  UIManager:setDirty(self, "ui")
end

function RatingPicker:_save()
  local rating = self.rating
  self:_close()
  if self.on_save then
    self.on_save(rating)
  end
end

function RatingPicker:_skip()
  self:_close()
  if self.on_skip then
    self.on_skip()
  end
end

function RatingPicker:_close()
  UIManager:close(self, "full")
end

local M = {}

-- opts: { title, author, on_save, on_skip }. Shows and returns the
-- widget; the caller doesn't need to hold onto it for anything (it closes
-- itself).
function M.show(opts)
  local picker = RatingPicker:new{
    book_title = opts.title,
    book_author = opts.author,
    rating = 0,
    on_save = opts.on_save,
    on_skip = opts.on_skip,
  }
  UIManager:show(picker, "full")
  return picker
end

return M
