local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local UI = {}

-- 顶部/底部菜单的分隔线：按钮不带方框，用横线与正文分隔。
-- 墨水屏上 1px 浅灰几乎看不见，统一加粗到 2px 并改用中灰（Sean 2026-11-28）。
local RULE_T = 2
local DIV_T = 2
local LINE_COLOR = Blitbuffer.COLOR_GRAY

local MenuRule = Widget:extend{}
function MenuRule:getSize()
    return Geom:new{ w = self.width or 0, h = RULE_T }
end
function MenuRule:paintTo(bb, x, y)
    bb:paintRect(x, y, self.width or 0, RULE_T, LINE_COLOR)
end

function UI.vspace(height)
    -- KOReader's VerticalSpan historically names its vertical extent `width`.
    return VerticalSpan:new{ width = math.max(0, math.floor(height or 0)) }
end

-- 相邻菜单项之间的竖线：与上下横线同色同粗细，菜单项本身仍无方框。
local MenuDivider = Widget:extend{}
function MenuDivider:getSize()
    return Geom:new{ w = DIV_T, h = self.height or 0 }
end
function MenuDivider:paintTo(bb, x, y)
    bb:paintRect(x, y, DIV_T, self.height or 0, LINE_COLOR)
end

function UI.rule(width)
    return MenuRule:new{ width = width }
end

function UI.divider(height)
    return MenuDivider:new{ height = math.max(1, math.floor(height or 0)) }
end

-- 菜单条统一包装：顶栏线在文字下方，底栏线在文字上方；
-- 传入的 height 是整条菜单（含 2px 线）的高度，文字行自动减 2px。
function UI.topBar(width, height, options)
    options = options or {}
    local row = UI.header(width, math.max(1, height - RULE_T), options)
    if options.rule == false then return row end
    return VerticalGroup:new{ row, UI.rule(width) }
end

function UI.bottomBar(width, height, cells, options)
    options = options or {}
    local row = UI.footer(width, math.max(1, height - RULE_T), cells, options)
    if options.rule == false then return row end
    return VerticalGroup:new{ UI.rule(width), row }
end

-- 横屏只用于阅读：退出阅读器/书架时统一回竖屏，避免书架与 KOReader
-- 在横屏下布局错乱、露出阅读页残影（Sean 2026-11-28）。
-- 走 KOReader 原生广播让宿主一并转屏；没有视图接管时兜底直接设置。
function UI.resetPortrait()
    local Device = require("device")
    local Screen = Device.screen
    local Event = require("ui/event")
    local UIManager = require("ui/uimanager")
    local upright = Screen.DEVICE_ROTATED_UPRIGHT
    if Screen.getRotationMode and Screen:getRotationMode() == upright then return false end
    UIManager:broadcastEvent(Event:new("SetRotationMode", upright))
    if Screen.getRotationMode and Screen:getRotationMode() ~= upright then
        Screen:setRotationMode(upright)
    end
    return true
end

function UI.defer(owner, key, callback)
    owner = owner or UI
    key = tostring(key or "action")
    owner._leko_deferred = owner._leko_deferred or {}
    if owner._leko_deferred[key] then return true end
    owner._leko_deferred[key] = true
    UIManager:nextTick(function()
        owner._leko_deferred[key] = nil
        local ok, err = xpcall(callback, debug.traceback)
        if not ok then
            logger.err("Leko deferred UI action failed", key, err)
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{ text = "界面操作失败：\n" .. tostring(err) })
        end
    end)
    return true
end

local function showWidget(owner, key, factory, refresh_type, modal)
    return UI.defer(owner, key, function()
        local widget = type(factory) == "function" and factory() or factory
        if not widget then return end
        if modal then widget.modal = true end
        logger.info("Leko UI show", tostring(key), "modal", tostring(widget.modal),
            "owner_modal", tostring(owner and owner.modal))
        UIManager:show(widget, refresh_type)
        if UIManager.getTopmostVisibleWidget then
            local top = UIManager:getTopmostVisibleWidget()
            if top ~= widget then
                logger.warn("Leko widget was not topmost after show", tostring(key), tostring(top), tostring(widget))
            end
        end
    end)
end

function UI.showLater(owner, key, factory, refresh_type)
    return showWidget(owner, key, factory, refresh_type, false)
end

function UI.showModalLater(owner, key, factory, refresh_type)
    return showWidget(owner, key, factory, refresh_type, true)
end

local CellButton = InputContainer:extend{
    text = "",
    callback = nil,
    hold_callback = nil,
    enabled = true,
    align = "center",
    font = "smallinfofont",
    font_size = 20,
    bold = false,
    -- 简洁风格：菜单项无方框，只用一条细线与正文分隔。
    -- 保留 padding 作为点击热区内的文字留白。
    bordersize = 0,
    padding = 6,
}

function CellButton:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = math.max(1, self.width or 1), h = math.max(1, self.height or 1) }
    local inner_w = math.max(1, self.dimen.w - 2 * self.bordersize - 2 * self.padding)
    local inner_h = math.max(1, self.dimen.h - 2 * self.bordersize - 2 * self.padding)
    local text_widget
    if self.multiline then
        text_widget = TextBoxWidget:new{
            text = self.text or "",
            width = inner_w,
            height = inner_h,
            face = Font:getFace(self.font, self.font_size),
            bold = self.bold,
            alignment = self.align,
            alignment_strict = true,
            fgcolor = self.enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        }
    else
        text_widget = TextWidget:new{
            text = self.text or "",
            face = Font:getFace(self.font, self.font_size),
            bold = self.bold,
            max_width = inner_w,
            fgcolor = self.enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        }
    end
    local content
    if self.align == "left" then
        content = LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, text_widget }
    else
        content = CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, text_widget }
    end
    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        bordersize = self.bordersize,
        padding = self.padding,
        background = self.background or Blitbuffer.COLOR_WHITE,
        content,
    }
    self.ges_events = {
        TapCell = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    if self.hold_callback then
        self.ges_events.HoldCell = { GestureRange:new{ ges = "hold", range = self.dimen } }
    end
end

function CellButton:onTapCell()
    if self.enabled and self.callback then self.callback() end
    return true
end

function CellButton:onHoldCell()
    if self.enabled and self.hold_callback then self.hold_callback() end
    return true
end

function UI.cell(options)
    return CellButton:new(options or {})
end

-- 菜单项之间的竖线高度：上下各留约 1/4 行高，视觉上不顶到横细线。
local function dividerHeight(height)
    local pad = math.max(6, math.floor((height or 0) * 0.26))
    return math.max(8, (height or 0) - 2 * pad)
end

function UI.header(width, height, options)
    options = options or {}
    local left_w = options.left_width or math.floor(width * 0.22)
    local right_w = options.right_width or left_w
    -- 两项分隔线各占 DIV_T px，从中间标题宽度里扣，保证整行仍等于 width。
    local show_div = options.dividers ~= false
    local center_w = width - left_w - right_w - (show_div and 2 * DIV_T or 0)
    local group = HorizontalGroup:new{}
    group[#group + 1] = UI.cell{
        text = options.left_text or "‹ 返回",
        width = left_w,
        height = height,
        callback = options.on_left,
        enabled = options.on_left ~= nil,
        font_size = options.font_size or 20,
    }
    if show_div then group[#group + 1] = UI.divider(dividerHeight(height)) end
    group[#group + 1] = UI.cell{
        text = options.title or "",
        width = center_w,
        height = height,
        callback = options.on_title,
        enabled = options.on_title ~= nil,
        bold = true,
        font = "cfont",
        font_size = options.title_size or 23,
    }
    if show_div then group[#group + 1] = UI.divider(dividerHeight(height)) end
    group[#group + 1] = UI.cell{
        text = options.right_text or "",
        width = right_w,
        height = height,
        callback = options.on_right,
        enabled = options.on_right ~= nil,
        font_size = options.font_size or 20,
    }
    return group
end

function UI.footer(width, height, cells, options)
    options = options or {}
    cells = cells or {}
    local show_div = options.dividers ~= false and #cells > 1
    local div_count = show_div and (#cells - 1) or 0
    local usable = width - div_count * DIV_T
    local group = HorizontalGroup:new{}
    local used = 0
    for index, item in ipairs(cells) do
        local cell_w = item.width
        if not cell_w then
            local remaining_count = #cells - index + 1
            cell_w = math.floor((usable - used) / remaining_count)
        end
        if index == #cells then cell_w = usable - used end
        used = used + cell_w
        table.insert(group, UI.cell{
            text = item.text or "",
            width = cell_w,
            height = height,
            callback = item.callback,
            hold_callback = item.hold_callback,
            enabled = item.enabled ~= false,
            bold = item.bold == true,
            font = item.font or "smallinfofont",
            font_size = item.font_size or 19,
            multiline = item.multiline,
        })
        if show_div and index < #cells then
            table.insert(group, UI.divider(dividerHeight(height)))
        end
    end
    return group
end

function UI.screen(width, height, header, body, footer, header_h, footer_h)
    header_h = header and header_h or 0
    footer_h = footer and footer_h or 0
    local body_h = math.max(1, height - header_h - footer_h)
    local body_container = CenterContainer:new{
        dimen = Geom:new{ w = width, h = body_h },
        body,
    }
    local group = VerticalGroup:new{}
    if header then table.insert(group, header) end
    table.insert(group, body_container)
    if footer then table.insert(group, footer) end
    return FrameContainer:new{
        width = width,
        height = height,
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        group,
    }, body_h
end

return UI
