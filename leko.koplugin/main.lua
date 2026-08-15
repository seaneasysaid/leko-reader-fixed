local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local App = require("Leko/App")
local ErrorGuard = require("Leko/ErrorGuard")
local FileManagerTab = require("Leko/FileManagerTab")
local VERSION = require("Leko/Version").version

local Leko = WidgetContainer:extend{
    name = "leko",
    fullname = "Leko Reader · " .. VERSION,
    is_doc_only = false,
}

function Leko:onDispatcherRegisterActions()
    Dispatcher:registerAction("leko_open", {
        category = "none",
        event = "OpenLekoReader",
        title = self.fullname,
        general = true,
    })
end

function Leko:init()
    ErrorGuard:run("initialize", function() App:init() end)
    -- Install only the FileManager build-after wrapper.  The ordinary plugin
    -- menu entry below remains the explicit fallback if the host cannot expose
    -- a compatible FileManagerMenu contract.
    FileManagerTab:install({ app = App, ui_manager = UIManager })
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Leko:onFlushSettings()
    pcall(function() require("Leko/SourceHealth"):flushNow() end)
    pcall(function() require("Leko/CoverService"):flushDiagnostics() end)
end

function Leko:onSuspend()
    pcall(function() require("Leko/MobileSourceImport"):notifySuspend() end)
    self:onFlushSettings()
end

function Leko:addToMainMenu(menu_items)
    -- Keep the lightweight FileManager underneath NovelUI. Opening from an
    -- already active document would retain ReaderUI + CREngine in memory.
    if self.ui and self.ui.document then return end
    menu_items.leko = {
        text = self.fullname,
        sorting_hint = "more_tools",
        callback = function() ErrorGuard:run("open bookshelf", function() App:showBookshelf() end) end,
    }
end

function Leko:onOpenLekoReader()
    if self.ui and self.ui.document then
        UIManager:show(InfoMessage:new{
            text = "为避免同时保留普通文档引擎，请先返回 KOReader 文件管理器，再打开 Leko。",
        })
        return true
    end
    ErrorGuard:run("open bookshelf", function() App:showBookshelf() end)
    return true
end

return Leko
