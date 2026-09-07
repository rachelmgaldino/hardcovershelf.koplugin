--[[--
Hardcover Shelf: browse your Hardcover.app "Currently Reading" shelf and
change a book's status, or search the catalog and add/mark a new one --
all without opening a document first (hardcoverapp.koplugin's own status
menu only works on whatever book you have open in the reader).

Built as a standalone plugin rather than an addition to hardcoverapp.koplugin
itself, since forks/ isn't an actively maintained category here -- see
lib/hardcover_api.lua's header for what was vendored from hardcoverapp and
../THIRD_PARTY_NOTICES.md for attribution (MIT).

@module koplugin.HardcoverShelf
--]]--

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local HardcoverShelf = WidgetContainer:extend{
  name = "hardcovershelf",
  is_doc_only = false,
}

function HardcoverShelf:init()
  self.ui.menu:registerToMainMenu(self)
end

function HardcoverShelf:addToMainMenu(menu_items)
  menu_items.hardcover_shelf = {
    text = _("Hardcover Shelf"),
    sorting_hint = "tools",
    callback = function()
      -- self.ui.document is only set inside the reader (ReaderUI); this
      -- instance is FileManager's own when it's nil (see is_doc_only=false
      -- above -- both apps get their own instance of this plugin).
      require("lib/shelf_ui"):show(self.ui.document ~= nil)
    end,
  }
end

return HardcoverShelf
