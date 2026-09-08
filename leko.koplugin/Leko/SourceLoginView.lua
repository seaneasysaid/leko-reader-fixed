-- One native configuration entry for standard Legado loginUi sources.
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")

local AggregateActionCapability = require("Leko/AggregateActionCapability")
local LegadoLoginUi = require("Leko/LegadoLoginUi")
local LegadoSource = require("Leko/LegadoSource")
local Storage = require("Leko/Storage")

local SourceLoginView = Menu:extend{
    covers_fullscreen = true, is_borderless = true, is_popout = false,
    title_bar_fm_style = true, modal = false,
}

local function text(value) return tostring(value == nil and "" or value) end
local function shortMessage(value)
    value = text(value):gsub("[%w%._%%+%-]+@[%w%._%-]+%.[%a]+", "<账号>")
    if #value > 800 then value = value:sub(1, 800) .. "…" end
    return value
end
local function loginUi(source)
    local raw = type(source and source.raw) == "table" and source.raw or {}
    return source and (source.login_ui or source.loginUi) or raw.loginUi or raw.login_ui or ""
end

function SourceLoginView:_model()
    return LegadoLoginUi.parse(loginUi(self.source))
end

function SourceLoginView:_collect()
    local result = {}
    for _, field in ipairs((self:_model() or {}).fields or {}) do
        result[field.name] = text(self.values[field.index])
    end
    return result
end

function SourceLoginView:_refresh()
    self.item_table = self:_buildItems()
    self:updateItems()
end

function SourceLoginView:_save()
    self.source.login_info = self:_collect()
    local ok, err = Storage:saveSourceRuntime(self.source)
    if ok == false then
        UIManager:show(InfoMessage:new{ text = "保存配置失败：" .. text(err) })
        return false
    end
    UIManager:show(Notification:new{ text = "已保存书源配置" })
    return true
end

function SourceLoginView:_edit(row)
    local dialog
    dialog = InputDialog:new{
        modal = true, title = row.name, input = text(self.values[row.index]),
        input_hint = row.type == "password" and "输入密码或密钥" or "输入字段值",
        input_type = row.type == "password" and "password" or nil,
        buttons = {
            {{ text = "取消", callback = function() UIManager:close(dialog) end }},
            {{ text = "保存本项", callback = function()
                self.values[row.index] = dialog:getInputText()
                UIManager:close(dialog)
                self:_refresh()
            end }},
        },
    }
    UIManager:show(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
end

function SourceLoginView:_run(row)
    local _, supported = AggregateActionCapability.label(self.source, row.action)
    if supported ~= true then return end
    if not self:_save() then return end
    local ok, err, detail = LegadoSource:executeLoginUiAction(self.source, row.action, {
        login_data = self.source.login_info, interactive = false,
    })
    if not ok then
        UIManager:show(InfoMessage:new{ text = "配置操作失败：\n" .. shortMessage(err) })
        return
    end
    local messages = detail and detail.messages or {}
    UIManager:show(InfoMessage:new{
        text = shortMessage(#messages > 0 and table.concat(messages, "\n") or "配置操作已完成"),
    })
end

function SourceLoginView:_buildItems()
    local model = self:_model()
    if not model then return {
        { text = "该书源没有可由 Kindle 原生填写的 loginUi 字段", dim = true },
        { text = "返回", action = "close" },
    } end
    local items = { { text = "配置书源", mandatory = "仅保存本机账号、Cookie 与运行变量", dim = true } }
    for _, row in ipairs(model.fields) do
        local value = text(self.values[row.index])
        items[#items + 1] = {
            text = row.name, row = row,
            mandatory = value == "" and "未填写 · 点击输入" or "已填写 · 点击修改",
        }
    end
    for _, row in ipairs(model.actions) do
        local label, supported = AggregateActionCapability.label(self.source, row.action)
        items[#items + 1] = {
            text = row.name, row = row, action = supported and "run" or nil,
            mandatory = label, supported = supported, dim = not supported,
        }
    end
    items[#items + 1] = { text = "保存配置", action = "save", separator = true }
    items[#items + 1] = { text = "返回", action = "close" }
    return items
end

function SourceLoginView:init()
    self.source, self.values = self.source or {}, {}
    for _, row in ipairs((self:_model() or {}).fields or {}) do
        self.values[row.index] = text(self.source.login_info and self.source.login_info[row.name])
    end
    self.title = "配置书源 · " .. text(self.source.name or "书源")
    self.title_bar_left_icon = "home"
    self.onLeftButtonTap = function() self:onReturn() end
    self.item_table = self:_buildItems()
    self.onMenuSelect = function(menu, item)
        if item.action == "save" then menu:_save()
        elseif item.action == "close" then menu:onReturn()
        elseif item.action == "run" and item.supported == true then menu:_run(item.row)
        elseif item.row and (item.row.type == "text" or item.row.type == "password") then
            menu:_edit(item.row)
        end
    end
    self.close_callback = function() UIManager:close(self, "full") end
    Menu.init(self)
end

function SourceLoginView:onReturn()
    UIManager:close(self, "full")
    return true
end

function SourceLoginView.open(options)
    options = options or {}
    local source = options.source or {}
    local raw = type(source.raw) == "table" and source.raw or {}
    local model = LegadoLoginUi.parse(source.login_ui or source.loginUi or raw.loginUi or raw.login_ui or "")
    local actions = model and model.actions or {}
    local function showView()
        local view = SourceLoginView:new(options)
        UIManager:show(view, "full")
        return view
    end
    if AggregateActionCapability.isPrepared(source, actions) then return showView() end

    local progress = InfoMessage:new{ text = string.format("正在分析按钮能力（0/%d）", #actions) }
    UIManager:show(progress)
    local function prepare()
        AggregateActionCapability.prepare(source, actions, {
            on_progress = function(completed, total)
                progress.text = string.format("正在分析按钮能力（%d/%d）", completed, total)
            end,
        })
        Storage:saveSourceRuntime(source)
        UIManager:close(progress)
        showView()
    end
    if type(UIManager.nextTick) == "function" then UIManager:nextTick(prepare)
    else UIManager:scheduleIn(0, prepare) end
    return progress
end

return SourceLoginView
