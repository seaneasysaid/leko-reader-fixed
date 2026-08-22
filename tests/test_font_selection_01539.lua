local plugin_root = assert(arg[1]):gsub("\\", "/")
package.path = plugin_root .. "/?.lua;" .. plugin_root .. "/?/init.lua;" .. package.path

local Menu = {}
function Menu:extend(definition)
    local class = {}
    for key, value in pairs(definition or {}) do class[key] = value end
    class.__index = class
    class.switchItemTable = function(self, title, items, selected)
        self.title, self.item_table, self.selection = title, items, selected
    end
    function class:new(options)
        local instance = options or {}
        setmetatable(instance, class)
        if instance.init then instance:init() end
        return instance
    end
    return class
end
function Menu.init() end
package.loaded["ui/widget/menu"] = Menu
package.preload["ui/widget/menu"] = function() return Menu end

local FontList = {
    fontinfo = {
        ["/fonts/JP.otf"] = { { index = 0, names = { "Japanese CJK" }, langs = { "ja" } } },
        ["/fonts/KR.otf"] = { { index = 0, names = { "Korean CJK" }, langs = { "ko" } } },
        ["/fonts/Generic.otf"] = { { index = 0, names = { "Noto CJK" }, langs = { "zh" } } },
        ["/fonts/TC.ttc"] = { { index = 0, names = { "繁體黑体" }, langs = { "zh-Hant" } } },
        ["/fonts/SC.ttc"] = {
            { index = 0, names = { "简体黑体" }, bold = false, italic = false, langs = { "zh-Hans" } },
            { index = 1, names = { "简体黑体" }, bold = true, italic = false, langs = { "zh-Hans" } },
        },
        ["/system/SC-Regular.ttf"] = {
            { index = 0, names = { "简体黑体" }, bold = false, italic = false, langs = { "zh-Hans" } },
        },
    },
}
function FontList:getFontList()
    return { "/fonts/JP.otf", "/fonts/KR.otf", "/fonts/Generic.otf", "/fonts/TC.ttc", "/fonts/SC.ttc",
        "/system/SC-Regular.ttf" }
end
function FontList:getLocalizedFontName(path, index)
    return self.fontinfo[path][index + 1].names[1]
end
package.loaded["fontlist"] = FontList
package.preload["fontlist"] = function() return FontList end

local Font = {}
function Font:getFace(path, size, index)
    if path == "/fonts/Broken.otf" then return nil end
    return { path = path, size = size, index = index }
end
package.loaded["ui/font"] = Font
package.preload["ui/font"] = function() return Font end

local notifications = {}
package.loaded["ui/widget/notification"] = {
    new = function(_, item) return item end,
}
package.preload["ui/widget/notification"] = function()
    return { new = function(_, item) return item end }
end
package.loaded["ui/uimanager"] = {
    show = function(_, item) notifications[#notifications + 1] = item.text end,
    close = function() end,
    nextTick = function(_, callback) callback() end,
}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, item) notifications[#notifications + 1] = item.text end,
        close = function() end,
        nextTick = function(_, callback) callback() end,
    }
end

local View = require("Leko/FontSelectionView")
local style = { body_font = "cfont" }
local items, selection = View.buildItems(style)
assert(items[1].text == "系统默认（简体中文优先）" and selection == 1,
    "system default font is not the first item")
assert(items[2].display_name == "简体黑体" and items[3].display_name == "简体黑体 — Bold",
    "KOReader bold metadata is not shown without synthetic face-number labels")
assert(items[2].action == "choose-font-path" and #items[2].variants == 2,
    "same-name fonts were not grouped behind one display row")
for _, item in ipairs(items) do
    assert(not tostring(item.display_name):find("字体面", 1, true), "face-number label leaked into font menu")
    assert(not tostring(item.display_name):match("%.[Oo][Tt][Ff]$")
        and not tostring(item.display_name):match("%.[Tt][Tt][Ff]$"), "font extension leaked into label")
end
assert(items[4].display_name == "繁體黑体" and items[5].display_name == "Noto CJK",
    "traditional/generic CJK order is incorrect")
assert(items[6].display_name == "Japanese CJK" and items[7].display_name == "Korean CJK",
    "Japanese/Korean fonts were not retained after CJK fonts")

style.body_font = "/fonts/SC.ttc"
style.body_font_index = 0
local path_view = View:new{ style = style }
path_view.onMenuSelect(path_view, items[2])
assert(path_view.title == "选择字体位置" and #path_view.item_table == 2
    and path_view.item_table[1].text:sub(1, 1) == "/",
    "same-name font path submenu was not shown")
path_view:onReturn()
assert(path_view.title == "选择字体" and path_view._path_group == nil,
    "font path submenu did not return to the grouped font list")

style.body_font = "/fonts/SC.ttc"
style.body_font_index = 1
local current_items, current_selection = View.buildItems(style)
assert(current_items[current_selection].face_index == 1
    and current_items[current_selection].mandatory == "当前",
    "current TTC face is not marked")

local selected, returned
local checked, checked_err = View.validateSelection(current_items[current_selection])
local view = View:new{
    style = style,
    on_selected = function(value) selected = value end,
    on_return = function() returned = true end,
}
view.onMenuSelect(view, current_items[current_selection])
assert(selected and selected.font_path == "/fonts/SC.ttc" and selected.face_index == 1,
    "font selection did not preserve the face index")
assert(returned == true, "font menu did not return to layout settings")
local invalid, invalid_err = View.validateSelection({ font_path = "/fonts/Broken.otf", face_index = 0 })
assert(not invalid and invalid_err, "invalid font was accepted")

print("native font menu ordering, TTC face selection, and invalid-face guard: OK")
