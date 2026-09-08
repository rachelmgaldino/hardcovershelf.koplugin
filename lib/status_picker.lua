--[[--
"Set Reading Status" modal, matching the design handoff's own two-step
flow: tapping a status tile only marks it selected (it inverts to a
filled black tile with a checkmark); a separate Done button is what
actually confirms it. Stock ButtonDialog -- what this plugin's status
picker used before -- can't do that: each of its buttons runs one
callback immediately on tap, there's no way to just mark something
selected and leave the dialog open for a later confirm step. Tapping
"Read" is the one exception -- it skips Done and closes this modal
straight into the rating picker instead (auto-advance), matching the
design's own callback wiring (chooseStatus: 'read' jumps to the rating
screen immediately, anything else just sets selectedStatus).

Dims the screen behind the card via Blitbuffer's own :darkenRect() --
real alpha compositing (blend pure black at a given opacity OVER the
existing pixels), not a flat opaque gray fill overwriting them (an
earlier version painted one of those instead, since no widget anywhere
in this codebase -- ButtonDialog, InputDialog, SpinWidget,
bookshelf.koplugin's own library modal -- already dims what's behind it;
turned out the reason none of them do is that a flat fill was the wrong
tool, not that dimming itself isn't possible here).

Rebuilds its own card content in place (self.card[1] = ...) and marks
just itself dirty on every tile tap, the same way bookshelf.koplugin's
own library_modal.lua refreshes a long-lived modal widget, rather than
closing and reopening a new widget for every tap the way this plugin's
list screens (lib/book_list.lua) do -- those rebuild cheaply from a whole
new API fetch each time; this one only ever changes its own local
"which tile is selected" state, so there's nothing to refetch.
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
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
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
local AUTHOR_COLOR = Blitbuffer.COLOR_GRAY_5
local DISABLED_COLOR = Blitbuffer.COLOR_GRAY_9

local SERIF_BOLD = "NotoSerif-Bold.ttf"
local SERIF_ITALIC = "NotoSerif-Italic.ttf"

-- Card and header/body/footer paddings, straight from the design
-- handoff's own CSS. Font sizes are bumped over the design's literal px
-- values by roughly the same ~15-30% this plugin's other screens ended
-- up at, not the raw numbers.
local CARD_BORDER = S(2)
local CARD_MAX_WIDTH = S(540)
local CARD_OUTER_PADDING = S(40)

local TILE_BORDER = S(1.5)

local HEADER_H_PADDING = S(24)
local HEADER_TOP_PADDING = S(22)
local HEADER_BOTTOM_PADDING = S(16)
local HEADER_GAP = S(12)
local TITLE_FACE_SIZE = 22
local AUTHOR_FACE_SIZE = 16
local AUTHOR_GAP = S(3)
local CLOSE_BTN_SIZE = S(32)

local BODY_PADDING = S(24)
local LABEL_FACE_SIZE = 16
local LABEL_GAP = S(16)
local GRID_GAP = S(12)
local TILE_HEIGHT = S(80)
local TILE_FACE_SIZE = 17
local TILE_H_INSET = S(10) -- side cushion for a tile's own label, design's "padding:0 10px"
local CHECK_FACE_SIZE = 15
local CHECK_TOP = S(7)
local CHECK_RIGHT = S(9)

local FOOTER_H_PADDING = S(24)
local FOOTER_BOTTOM_PADDING = S(24)
local DONE_HEIGHT = S(48)
local DONE_FACE_SIZE = 17

local DIM_AMOUNT = 0.35 -- lighter than the design's own rgba(20,20,20,0.5), by request

-- Dims whatever's already painted beneath it by blending black at
-- DIM_AMOUNT opacity over the given screen region -- real per-pixel
-- alpha compositing (Blitbuffer's own :darkenRect()), not a flat opaque
-- fill overwriting those pixels. A plain Widget (not WidgetContainer):
-- it has no child of its own, paintTo is the whole job.
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

-- One status tile. Selected inverts to a filled black background/white
-- text with a small checkmark pinned to the top-right corner (via
-- OverlapGroup's own overlap_offset mechanism -- an exact pixel
-- position, matching the design's own absolutely-positioned checkmark).
-- The checkmark is a plain Unicode check mark (U+2713) rather than the
-- mdlight "check" icon file -- icons here render in one fixed color with
-- no recolor hook (confirmed against iconwidget.lua), and this needs to
-- swap from black to white along with the rest of the tile's selected
-- state, which only a TextWidget's fgcolor can do.
local function buildTile(width, label_text, selected, callback)
  local fg = selected and Blitbuffer.COLOR_WHITE or INK
  local bg = selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
  local inner_w = width - 2 * TILE_BORDER
  local inner_h = TILE_HEIGHT - 2 * TILE_BORDER

  local label = TextWidget:new{
    text = label_text,
    face = Font:getFace("cfont", TILE_FACE_SIZE),
    bold = true,
    fgcolor = fg,
    max_width = inner_w - 2 * TILE_H_INSET,
  }
  local frame = FrameContainer:new{
    bordersize = TILE_BORDER,
    color = INK,
    background = bg,
    radius = 0,
    padding = 0,
    margin = 0,
    CenterContainer:new{
      dimen = Geom:new{ w = inner_w, h = inner_h },
      label,
    },
  }

  local visual = frame
  if selected then
    local check = TextWidget:new{
      text = "\xE2\x9C\x93", -- U+2713 CHECK MARK
      face = Font:getFace("cfont", CHECK_FACE_SIZE),
      fgcolor = fg,
    }
    check.overlap_offset = { width - CHECK_RIGHT - check:getSize().w, CHECK_TOP }
    visual = OverlapGroup:new{
      dimen = Geom:new{ w = width, h = TILE_HEIGHT },
      allow_mirroring = false,
      frame,
      check,
    }
  end

  return TapArea:new{ widget = visual, callback = callback }
end

-- Header: book title/author on the left, a bordered close ("X") button
-- on the right, a hairline below. Same OverlapGroup + LeftContainer +
-- RightContainer shape as book_list.lua's own header builders, sized to
-- content_w exactly rather than forcing width directly on any bordered
-- FrameContainer (that mismatch -- getSize() ignoring a forced width/
-- height while paintTo honors it -- is a real, previously-hit bug in
-- this same plugin; every box here is built to avoid it instead).
local function buildHeader(content_w, title, author, on_close)
  local inner_w = content_w - 2 * HEADER_H_PADDING
  local text_max_w = inner_w - CLOSE_BTN_SIZE - HEADER_GAP

  local title_widget = TextWidget:new{
    text = title,
    face = Font:getFace(SERIF_BOLD, TITLE_FACE_SIZE),
    max_width = text_max_w,
  }
  local text_block = title_widget
  if author then
    text_block = VerticalGroup:new{
      align = "left",
      title_widget,
      VerticalSpan:new{ width = AUTHOR_GAP },
      TextWidget:new{
        text = author,
        face = Font:getFace(SERIF_ITALIC, AUTHOR_FACE_SIZE),
        fgcolor = AUTHOR_COLOR,
        max_width = text_max_w,
      },
    }
  end

  local close_btn = buildCloseButton(on_close)
  local row_h = math.max(text_block:getSize().h, CLOSE_BTN_SIZE)

  local row = OverlapGroup:new{
    dimen = Geom:new{ w = inner_w, h = row_h },
    allow_mirroring = false,
    LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = row_h }, text_block },
    RightContainer:new{ dimen = Geom:new{ w = inner_w, h = row_h }, close_btn },
  }

  local padded = FrameContainer:new{
    bordersize = 0,
    padding = 0,
    padding_top = HEADER_TOP_PADDING,
    padding_bottom = HEADER_BOTTOM_PADDING,
    padding_left = HEADER_H_PADDING,
    padding_right = HEADER_H_PADDING,
    margin = 0,
    row,
  }

  return VerticalGroup:new{
    align = "left",
    padded,
    LineWidget:new{ dimen = Geom:new{ w = content_w, h = Size.line.thin }, background = Blitbuffer.COLOR_LIGHT_GRAY },
  }
end

-- Body: uppercase "SET READING STATUS" label + a 2x2 grid of status
-- tiles. `options` is a list of { id, label }, rendered in order
-- (top-left, top-right, bottom-left, bottom-right).
local function buildBody(content_w, options, selected_id, on_tile_tap)
  local inner_w = content_w - 2 * BODY_PADDING
  local tile_w = math.floor((inner_w - GRID_GAP) / 2)

  local label = TextWidget:new{
    text = _("SET READING STATUS"),
    face = Font:getFace("cfont", LABEL_FACE_SIZE),
    bold = true,
    fgcolor = INK,
    max_width = inner_w,
  }

  local tiles = {}
  for _, opt in ipairs(options) do
    table.insert(tiles, buildTile(tile_w, opt.label, opt.id == selected_id, function()
      on_tile_tap(opt.id)
    end))
  end

  local row1 = HorizontalGroup:new{ align = "top", tiles[1], HorizontalSpan:new{ width = GRID_GAP }, tiles[2] }
  local row2 = HorizontalGroup:new{ align = "top", tiles[3], HorizontalSpan:new{ width = GRID_GAP }, tiles[4] }
  local grid = VerticalGroup:new{ align = "left", row1, VerticalSpan:new{ width = GRID_GAP }, row2 }

  return FrameContainer:new{
    bordersize = 0,
    padding = BODY_PADDING,
    margin = 0,
    VerticalGroup:new{
      align = "left",
      label,
      VerticalSpan:new{ width = LABEL_GAP },
      grid,
    },
  }
end

-- Footer: full-width Done button, grayed out and inert until a tile is
-- selected. Same fixed-dimen-inner-content approach as the tiles above,
-- for the same reason (a visible bordered box that needs an exact size).
local function buildFooter(content_w, enabled, on_done)
  local btn_w = content_w - 2 * FOOTER_H_PADDING
  local inner_w = btn_w - 2 * TILE_BORDER
  local inner_h = DONE_HEIGHT - 2 * TILE_BORDER

  local label = TextWidget:new{
    text = _("Done"),
    face = Font:getFace("cfont", DONE_FACE_SIZE),
    bold = true,
    fgcolor = enabled and Blitbuffer.COLOR_WHITE or DISABLED_COLOR,
  }
  local button = FrameContainer:new{
    bordersize = TILE_BORDER,
    color = INK,
    background = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
    radius = 0,
    padding = 0,
    margin = 0,
    CenterContainer:new{
      dimen = Geom:new{ w = inner_w, h = inner_h },
      label,
    },
  }

  local tap = TapArea:new{ widget = button, callback = enabled and on_done or nil }

  return FrameContainer:new{
    bordersize = 0,
    padding = 0,
    padding_left = FOOTER_H_PADDING,
    padding_right = FOOTER_H_PADDING,
    padding_bottom = FOOTER_BOTTOM_PADDING,
    margin = 0,
    tap,
  }
end

local StatusPicker = InputContainer:extend{
  book_title = nil,
  book_author = nil,
  options = nil, -- { { id, label }, ... }, exactly 4
  read_id = nil, -- option id that auto-advances instead of needing Done
  on_pick = nil, -- (status_id) -- Done confirmed, or the read_id tile was tapped
  on_cancel = nil, -- close (X) tapped, or a tap outside the card
  selected_id = nil, -- internal
}

function StatusPicker:init()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }

  local card_width = math.min(screen_w - 2 * CARD_OUTER_PADDING, CARD_MAX_WIDTH)
  local content_w = card_width - 2 * CARD_BORDER
  self.content_w = content_w

  self.card = FrameContainer:new{
    bordersize = CARD_BORDER,
    color = INK,
    background = Blitbuffer.COLOR_WHITE,
    radius = 0,
    padding = 0,
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

  -- Tapping outside the card cancels, same as the X button -- a tap the
  -- card's own children already consumed (a tile, Done, X) never reaches
  -- here, per WidgetContainer's own propagateEvent-then-fall-back-to-self
  -- order.
  self.ges_events = {
    TapOutsideCard = { GestureRange:new{ ges = "tap", range = self.dimen } },
  }
end

function StatusPicker:onTapOutsideCard()
  self:_cancel()
  return true
end

function StatusPicker:_buildCardContent(content_w)
  local enabled = self.selected_id ~= nil
  return VerticalGroup:new{
    align = "left",
    buildHeader(content_w, self.book_title, self.book_author, function() self:_cancel() end),
    buildBody(content_w, self.options, self.selected_id, function(status_id) self:_onTileTap(status_id) end),
    buildFooter(content_w, enabled, function() self:_confirm() end),
  }
end

function StatusPicker:_onTileTap(status_id)
  if status_id == self.read_id then
    -- Auto-advance: skips Done entirely, matching the design's own
    -- chooseStatus('read') branch.
    self:_close()
    if self.on_pick then
      self.on_pick(status_id)
    end
    return
  end
  self.selected_id = status_id
  self:_refresh()
end

function StatusPicker:_confirm()
  if not self.selected_id then
    return
  end
  local status_id = self.selected_id
  self:_close()
  if self.on_pick then
    self.on_pick(status_id)
  end
end

function StatusPicker:_cancel()
  self:_close()
  if self.on_cancel then
    self.on_cancel()
  end
end

-- Rebuilds the card's content in place (reflecting the just-changed
-- selection) and repaints just this widget, rather than closing and
-- reopening a new one -- see this file's own header comment.
function StatusPicker:_refresh()
  self.card[1] = self:_buildCardContent(self.content_w)
  UIManager:setDirty(self, "ui")
end

function StatusPicker:_close()
  UIManager:close(self, "full")
end

local M = {}

-- opts: { title, author, options = { { id, label }, ... }, read_id,
-- on_pick, on_cancel }. Shows and returns the widget; the caller doesn't
-- need to hold onto it for anything (it closes itself).
function M.show(opts)
  local picker = StatusPicker:new{
    book_title = opts.title,
    book_author = opts.author,
    options = opts.options,
    read_id = opts.read_id,
    on_pick = opts.on_pick,
    on_cancel = opts.on_cancel,
  }
  UIManager:show(picker, "full")
  return picker
end

return M
