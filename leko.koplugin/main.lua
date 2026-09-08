local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local App = require("Leko/App")
local ErrorGuard = require("Leko/ErrorGuard")
local FileManagerTab = require("Leko/FileManagerTab")
local VERSION = require("Leko/Version").version

local Leko = WidgetContainer:extend{
    name = "leko",
    fullname = "Leko Reader · " .. VERSION,
    is_doc_only = false,
}

function Leko:getCurrentReadingContext()
    local context = App:getCurrentReadingContext()
    local snapshot = {}
    for key, value in pairs(context or {}) do snapshot[key] = value end
    return snapshot
end

function Leko:onDispatcherRegisterActions()
    Dispatcher:registerAction("leko_open", {
        category = "none",
        event = "OpenLekoReader",
        title = self.fullname,
        general = true,
    })
end

function Leko:init()
    logger.info("Leko plugin: initializing", self.fullname,
        self.ui and self.ui.document and "reader" or "filemanager")
    ErrorGuard:run("initialize", function() App:init() end)
    -- Install only the FileManager build-after wrapper.  The ordinary plugin
    -- menu entry below remains the explicit fallback if the host cannot expose
    -- a compatible FileManagerMenu contract.
    local tab_ok, tab_result = xpcall(function()
        return FileManagerTab:install({ app = App, ui_manager = UIManager })
    end, function(err)
        return debug and debug.traceback and debug.traceback(tostring(err), 2)
            or tostring(err)
    end)
    if not tab_ok then
        logger.err("Leko plugin: file-manager tab installation failed:", tab_result)
    elseif tab_result == false then
        logger.warn("Leko plugin: file-manager tab unavailable; keeping ordinary menu entry")
    end
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu and type(self.ui.menu.registerToMainMenu) == "function" then
        self.ui.menu:registerToMainMenu(self)
        logger.info("Leko plugin: ordinary menu entry registered")
    else
        logger.err("Leko plugin: host menu registration API is unavailable")
    end
end

function Leko:onFlushSettings()
    pcall(function() require("Leko/SourceHealth"):flushNow() end)
    pcall(function() require("Leko/CoverService"):flushDiagnostics() end)
end

function Leko:onSuspend()
    pcall(function() require("Leko/MobileSourceImport"):notifySuspend() end)
    self:onFlushSettings()
end

function Leko:onExit()
    pcall(function() require("Leko/SearchResultCache"):onExit() end)
    pcall(App.closeReadingStatistics, App)
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
