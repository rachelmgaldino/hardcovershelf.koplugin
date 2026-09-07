--[[--
A small custom scrollable list, built from scratch rather than KOReader's
core `Menu` widget. `Menu` only renders plain text per row (its `mandatory`
field is hard-coerced into a plain TextWidget internally, see menu.lua's
own updateItems -- no hook for a custom child widget), so there's no way
to get a real rounded-corner background tag into a stock Menu row without
either vendoring a huge replacement (the ~1000-line approach hardcoverapp
and bookends both took for their own fancier lists) or building just
enough of a list ourselves. This is the second option, scoped to exactly
what this plugin needs: a title/author line and an optional series tag
per row, nothing else.
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
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local VerticalGroup = require("ui/widget/verticalgroup")

local Screen = Device.screen

local ROW_V_PADDING = Size.padding.default
local ROW_H_PADDING = Size.padding.large
local TAG_GAP = Size.padding.default

-- A rounded-corner background pill, e.g. "A Song of Ice and Fire, #1".
-- Any KOReader widget with a `background` color draws with
-- `Size.radius.button` corners (confirmed in ui/widget/button.lua), so
-- this is just that same recipe applied directly via FrameContainer
-- rather than going through the interactive Button widget itself.
local function buildSeriesTag(text)
  local label = TextWidget:new{
    text = text,
    face = Font:getFace("cfont", 16),
    fgcolor = Blitbuffer.COLOR_BLACK,
  }
  return FrameContainer:new{
    bordersize = 0,
    background = Blitbuffer.COLOR_GRAY_E,
    radius = Size.radius.button,
    padding_top = Size.padding.small,
    padding_bottom = Size.padding.small,
    padding_left = Size.padding.default,
    padding_right = Size.padding.default,
    margin = 0,
    label,
  }
end

local BookRow = InputContainer:extend{
  item = nil,
  width = nil,
  callback = nil,
  show_parent = nil,
}

function BookRow:init()
  local content_width = self.width - 2 * ROW_H_PADDING
  local content

  if self.item.series_tag then
    -- Single-line text (TextWidget, not TextBoxWidget) truncated with an
    -- ellipsis at max_width, so the tag sits immediately after wherever
    -- the text actually ends -- TextBoxWidget always reserves its full
    -- given width regardless of the text's real length, which is what
    -- was pushing the tag out to a fixed offset near the row's right edge
    -- instead of right after the author.
    local tag = buildSeriesTag(self.item.series_tag)
    local tag_width = tag:getSize().w
    local text_max_width = content_width - tag_width - TAG_GAP
    content = HorizontalGroup:new{
      align = "center",
      TextWidget:new{
        text = self.item.text,
        face = Font:getFace("cfont", 20),
        max_width = text_max_width,
      },
      HorizontalSpan:new{ width = TAG_GAP },
      tag,
    }
  else
    content = TextBoxWidget:new{
      text = self.item.text,
      face = Font:getFace("cfont", 20),
      width = content_width,
    }
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

local BookList = {}

-- Builds and returns the widget to pass to UIManager:show()/close(). Not
-- shown here, the caller does that, same as the Menu-based version this
-- replaced, so shelf_ui.lua's overlay-stacking logic (search/edition
-- picker/status picker layering on top without closing the shelf) doesn't
-- need to change at all, only how the list itself is built.
--
-- item_table entries carry a "text" field ("Title - Author"), an optional
-- "series_tag" field ("Series Name, #1"), and whatever identifying fields
-- the caller needs (book_id, row_id, edition_id...), passed straight
-- through to on_select untouched.
function BookList.build(title, item_table, in_book, on_select, on_close)
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local width, height
  if in_book then
    width = math.min(screen_w - Screen:scaleBySize(50), Screen:scaleBySize(600))
    height = screen_h - Screen:scaleBySize(50)
  else
    width = screen_w
    height = screen_h
  end

  local title_bar = TitleBar:new{
    width = width,
    title = title,
    close_callback = on_close,
  }

  local rows = VerticalGroup:new{ align = "left" }
  local book_rows = {}
  for _, item in ipairs(item_table) do
    local row = BookRow:new{
      item = item,
      width = width,
      callback = function() on_select(item) end,
    }
    table.insert(book_rows, row)
    table.insert(rows, row)
    table.insert(rows, LineWidget:new{
      dimen = Geom:new{ w = width, h = Size.line.thin },
      background = Blitbuffer.COLOR_GRAY_D,
    })
  end

  local content_height = height - title_bar:getSize().h
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
      title_bar,
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
  title_bar.show_parent = top_widget
  scroll_container.show_parent = top_widget
  for _, row in ipairs(book_rows) do
    row.show_parent = top_widget
  end

  return top_widget
end

return BookList
