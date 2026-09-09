--[[--
"Up Next" modal, shown right after markRead's commit succeeds -- see
shelf_ui.lua's own _maybeOfferNextInSeries. Offers to start reading the
next book in a series, the same "commit or back out entirely" shape as
status_picker.lua/rating_picker.lua: Start Reading confirms, the close (X)
or a tap outside the card backs out and does nothing, no distinct third
outcome the way the rating picker has (there's no partial state to
record here -- either you start the next book or you don't).

No design-handoff mockup covers this screen (it's a feature this plugin
added on its own, not part of the original design), so there's nothing to
match pixel-for-pixel -- this reuses the same card/backdrop/button recipe
status_picker.lua and rating_picker.lua already establish (their own
header comments cover the DarkenOverlay/OverlapGroup/TapArea mechanics at
length; not repeated here) rather than falling back to a stock KOReader
ConfirmBox, which was the actual problem this file fixes: a plain
ConfirmBox looks like raw KOReader chrome next to every other screen in
this plugin.
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
local MUTED_COLOR = Blitbuffer.COLOR_GRAY_5 -- matches status_picker.lua/rating_picker.lua's own #555555

local SERIF_BOLD = "NotoSerif-Bold.ttf"
local SERIF_ITALIC = "NotoSerif-Italic.ttf"

-- Same card proportions as rating_picker.lua -- a short prompt like this
-- one needs even less room, but matching the sibling modal's size keeps
-- the plugin's overlays feeling like one consistent set rather than each
-- popping up at its own arbitrary size.
local CARD_BORDER = S(2)
local CARD_MAX_WIDTH = S(480)
local CARD_OUTER_PADDING = S(40)
local CARD_V_PADDING = S(28)
local CARD_H_PADDING = S(32)
local GROUP_GAP = S(20)

local HEADER_LABEL_FACE_SIZE = 16
local HEADER_GAP = S(12)
local CLOSE_BTN_SIZE = S(32)

local TITLE_FACE_SIZE = 23
local AUTHOR_FACE_SIZE = 16
local AUTHOR_GAP = S(5)

local BUTTON_GAP = S(14)
local BUTTON_HEIGHT = S(48)
local BUTTON_BORDER = S(1.5)
local BUTTON_FACE_SIZE = 17

local DIM_AMOUNT = 0.35 -- same tuned value as the sibling modals' backdrop

-- Same real per-pixel dimming as status_picker.lua/rating_picker.lua's
-- own DarkenOverlay (Blitbuffer:darkenRect(), not a flat opaque fill) --
-- duplicated here rather than shared, matching this plugin's existing
-- per-screen-file convention.
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

-- Header: uppercase "UP NEXT" label on the left, bordered close ("X") on
-- the right -- same OverlapGroup + Left/RightContainer shape as every
-- other header row in this plugin.
local function buildHeader(content_w, on_close)
  local label = TextWidget:new{
    text = _("UP NEXT"),
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

-- Book title (+ author, if given), centered as a block -- same shape as
-- rating_picker.lua's own title block.
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

-- Not Now / Start Reading, side by side, equal width -- same recipe as
-- rating_picker.lua's Skip/Save Rating row.
local function buildButtonRow(content_w, on_not_now, on_start)
  local btn_w = math.floor((content_w - BUTTON_GAP) / 2)
  local inner_w = btn_w - 2 * BUTTON_BORDER
  local inner_h = BUTTON_HEIGHT - 2 * BUTTON_BORDER

  local not_now_btn = FrameContainer:new{
    bordersize = BUTTON_BORDER,
    color = INK,
    background = Blitbuffer.COLOR_WHITE,
    radius = 0,
    padding = 0,
    margin = 0,
    CenterContainer:new{
      dimen = Geom:new{ w = inner_w, h = inner_h },
      TextWidget:new{
        text = _("Not Now"),
        face = Font:getFace("cfont", BUTTON_FACE_SIZE),
        bold = true,
        fgcolor = INK,
      },
    },
  }
  local start_btn = FrameContainer:new{
    bordersize = BUTTON_BORDER,
    color = INK,
    background = Blitbuffer.COLOR_BLACK,
    radius = 0,
    padding = 0,
    margin = 0,
    CenterContainer:new{
      dimen = Geom:new{ w = inner_w, h = inner_h },
      TextWidget:new{
        text = _("Start Reading"),
        face = Font:getFace("cfont", BUTTON_FACE_SIZE),
        bold = true,
        fgcolor = Blitbuffer.COLOR_WHITE,
      },
    },
  }

  return HorizontalGroup:new{
    align = "top",
    TapArea:new{ widget = not_now_btn, callback = on_not_now },
    HorizontalSpan:new{ width = BUTTON_GAP },
    TapArea:new{ widget = start_btn, callback = on_start },
  }
end

local NextReadPrompt = InputContainer:extend{
  book_title = nil,
  book_author = nil,
  on_start = nil,  -- Start Reading tapped
  on_cancel = nil, -- Not Now, the close (X), or a tap outside the card
}

function NextReadPrompt:init()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }

  local card_width = math.min(screen_w - 2 * CARD_OUTER_PADDING, CARD_MAX_WIDTH)
  local content_w = card_width - 2 * CARD_BORDER - 2 * CARD_H_PADDING

  local content = VerticalGroup:new{
    align = "center",
    buildHeader(content_w, function() self:_cancel() end),
    VerticalSpan:new{ width = GROUP_GAP },
    buildTitleBlock(content_w, self.book_title, self.book_author),
    VerticalSpan:new{ width = GROUP_GAP },
    buildButtonRow(content_w, function() self:_cancel() end, function() self:_start() end),
  }

  local card = FrameContainer:new{
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
    content,
  }

  local dim = DarkenOverlay:new{
    dimen = Geom:new{ w = screen_w, h = screen_h },
  }
  local centered_card = CenterContainer:new{
    dimen = Geom:new{ w = screen_w, h = screen_h },
    card,
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

function NextReadPrompt:onTapOutsideCard()
  self:_cancel()
  return true
end

function NextReadPrompt:_start()
  self:_close()
  if self.on_start then
    self.on_start()
  end
end

function NextReadPrompt:_cancel()
  self:_close()
  if self.on_cancel then
    self.on_cancel()
  end
end

function NextReadPrompt:_close()
  UIManager:close(self, "full")
end

local M = {}

-- opts: { title, author, on_start, on_cancel }. Shows and returns the
-- widget; the caller doesn't need to hold onto it for anything (it closes
-- itself).
function M.show(opts)
  local prompt = NextReadPrompt:new{
    book_title = opts.title,
    book_author = opts.author,
    on_start = opts.on_start,
    on_cancel = opts.on_cancel,
  }
  UIManager:show(prompt, "full")
  return prompt
end

return M
