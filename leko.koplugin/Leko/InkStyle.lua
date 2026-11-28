--[[--
阅读器设置控件（Sean 2026-11-28 按参考图实现）。

完全自绘，不依赖任何外部模块或图标资源。包含：

  * Slider   —— 胶囊轨道 + 黑色填充 + 白色圆钮黑描边（tap 定位 / hold 拖动 /
                 release 提交；拖动中只预览，松手才回调，避免墨水屏整页重排卡顿）
  * StepBtn  —— − / ＋ 图标按钮
  * Pill     —— 圆角胶囊描边按钮
  * Switch   —— 开关（on 黑底白点 / off 白底黑边黑点）
  * Rule     —— 浅灰分隔线

这些控件只负责「长相」和手势，数值语义仍由调用方（两个设置页）决定。
--]]
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local Screen = Device.screen

local S = {}

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.COLOR_LIGHT_GRAY
local DGRAY = Blitbuffer.COLOR_DARK_GRAY

local function px(n) return Screen:scaleBySize(n) end

-- 字号语义：Font:getFace 内部已经 scaleBySize，所以这里传的是
-- 「未缩放」的 pt；再按屏幕 dp 做一次 UI 级微调。之前把 px(size) 传给
-- getFace 等于缩放两次，这正是截图里字大得离谱的原因。
function S.fontSize(size, level)
    level = math.max(0, math.min(4, math.floor(tonumber(level or 1))))
    local short_side = math.min(Screen:getWidth(), Screen:getHeight())
    local dpi = type(Screen.getDPI) == "function" and Screen:getDPI() or 160
    local dp = short_side * 160 / math.max(1, dpi or 160)
    local offsets = dp >= 702 and { 2, 3, 5, 8, 12 }
        or (dp < 480 and { -1, 0, 1, 2, 3 } or { -1, 0, 1, 3, 5 })
    return (size or 18) + offsets[level + 1] - offsets[2]
end

-- Font:getFace 第三参数是 faceindex（不是 bold），bold 交给控件自身的 bold 字段。
function S.face(size)
    return Font:getFace("cfont", S.fontSize(size))
end

function S.label(text, width, size, bold, align, fgcolor)
    return TextBoxWidget:new{
        text = tostring(text or ""), width = width,
        face = S.face(size or 18),
        bold = bold == true,
        alignment = align or "left",
        fgcolor = fgcolor or BLACK,
        height_overflow_show_ellipsis = true,
    }
end

-- ---------------------------------------------------------------- Slider --
local Slider = InputContainer:extend{}

function Slider:init()
    self.minimum = self.minimum or 0
    self.maximum = self.maximum or 100
    self.step = self.step or 1
    self.value = math.max(self.minimum,
        math.min(self.maximum, tonumber(self.value) or self.minimum))
    self.dimen = Geom:new{ w = math.max(1, self.width or px(200)), h = px(44) }
end

local function sliderGeometry(self, x)
    local r = px(9)                 -- 圆钮半径
    local left = x + r
    local width = math.max(1, self.dimen.w - 2 * r)
    return r, left, width
end

function Slider:_valueAt(x)
    local r, left, width = sliderGeometry(self, self.dimen.x)
    local ratio = math.max(0, math.min(1, (x - left) / width))
    local raw = self.minimum + ratio * (self.maximum - self.minimum)
    local step = self.step or 1
    local value = math.floor(raw / step + 0.5) * step
    return math.max(self.minimum, math.min(self.maximum, value))
end

function Slider:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local r, left, width = sliderGeometry(self, x)
    local ratio = (self.value - self.minimum) / math.max(1, self.maximum - self.minimum)
    local center = math.floor(left + width * math.max(0, math.min(1, ratio)))
    local cy = y + math.floor(self.dimen.h / 2)
    local bar_h = px(8)
    local br = math.floor(bar_h / 2)

    local function capsule(from, to, color)
        bb:paintRect(from + br, cy - br, math.max(0, to - from - 2 * br), 2 * br, color)
        bb:paintCircle(from + br, cy, br, color)
        bb:paintCircle(to - br, cy, br, color)
    end
    capsule(x, x + self.dimen.w, GRAY)
    capsule(x, math.max(x + bar_h, center + r), BLACK)
    bb:paintCircle(center, cy, r, WHITE)
    bb:paintCircle(center, cy, r, BLACK, px(2))
end

-- ⚠️ setDirty(nil, ...) 只往刷新队列塞一次屏幕刷新，并不会把任何 widget 标脏：
-- 自绘控件的值改了却不会重画。必须把宿主弹窗交给 setDirty，才会触发 paintTo。
function Slider:_dirty(mode)
    if type(self.dirty) == "function" then
        self.dirty(mode)
    else
        UIManager:setDirty(nil, mode, self.dimen:copy())
    end
end

-- 拖动中只走 preview_callback（更新数值标签），release/tap 才调用 callback。
function Slider:_apply(value, committing)
    value = math.max(self.minimum, math.min(self.maximum, value))
    local changed = value ~= self.value
    self.value = value
    if changed and type(self.preview_callback) == "function" then
        self.preview_callback(value)
    end
    if committing and type(self.callback) == "function" then self.callback(value) end
end

function Slider:onGesture(ges)
    local kind = ges.ges
    local start = ges.start_pos or ges.pos
    local pos = ges.pos or start
    if kind == "tap" then
        if not self.dimen:contains(pos) then return end
        self:_apply(self:_valueAt(pos.x), true)
        self:_dirty("ui")
        return true
    end
    if kind == "hold" then
        if not self.dimen:contains(pos) then return end
        self._dragging, self._committed = true, false
        return true
    end
    if kind == "pan" or kind == "hold_pan" then
        if not self._dragging then
            if not start or not self.dimen:contains(start) then return end
            self._dragging, self._committed = true, false
        end
        self:_apply(self:_valueAt(pos.x), false)
        self:_dirty("fast")
        return true
    end
    if kind == "pan_release" or kind == "hold_release" or kind == "swipe" then
        if self._dragging then
            self._dragging = nil
            self:_apply(self:_valueAt((ges.end_pos or pos).x), true)
            self:_dirty("ui")
            return true
        end
    end
    if self._dragging then
        self._dragging = nil
        self:_dirty("ui")
        return true
    end
end

S.Slider = Slider

-- --------------------------------------------------------------- StepBtn --
local StepBtn = InputContainer:extend{}

function StepBtn:init()
    self.width = self.width or px(46)
    self.height = self.height or px(44)
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events.TapStep = { GestureRange:new{ ges = "tap", range = self.dimen } }
end

function StepBtn:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self.dimen.w <= 0 or self.dimen.h <= 0 then return end
    local cx = x + math.floor(self.dimen.w / 2)
    local cy = y + math.floor(self.dimen.h / 2)
    local arm = px(11)
    local thick = math.max(2, px(3))
    bb:paintRect(cx - arm, cy - math.floor(thick / 2), 2 * arm, thick, BLACK)
    if self.plus then
        bb:paintRect(cx - math.floor(thick / 2), cy - arm, thick, 2 * arm, BLACK)
    end
end

function StepBtn:onTapStep()
    if self.callback then self.callback() end
    return true
end

function S.stepButton(plus, callback, width, height)
    return StepBtn:new{ plus = plus == true, callback = callback,
        width = width, height = height }
end

-- ------------------------------------------------------------------ Pill --
local Pill = InputContainer:extend{}

function Pill:init()
    self.width = self.width or px(200)
    self.height = self.height or px(52)
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events.TapPill = { GestureRange:new{ ges = "tap", range = self.dimen } }
    -- selected=true → 黑底白字（参考图里「竖屏」的选中态）。
    local selected = self.selected == true
    local label = TextWidget:new{
        text = tostring(self.text or ""),
        face = S.face(self.font_size or 17), padding = 0, bold = true,
        max_width = self.width - px(20),
        fgcolor = selected and WHITE or BLACK,
    }
    self[1] = FrameContainer:new{
        bordersize = px(1), radius = px(24), padding = 0,
        color = BLACK, background = selected and BLACK or WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height }, label,
        },
    }
end

function Pill:onTapPill()
    if self.callback then self.callback() end
    return true
end

function S.pill(text, width, callback, height, selected, id, font_size)
    return Pill:new{ text = text, width = width, height = height or px(52),
        callback = callback, selected = selected == true, id = id,
        font_size = font_size }
end

-- ---------------------------------------------------------------- Switch --
local Switch = InputContainer:extend{}

function Switch:init()
    self.width = self.width or px(60)
    self.height = self.height or px(32)
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events.TapSwitch = { GestureRange:new{ ges = "tap", range = self.dimen } }
end

local function roundRect(bb, x, y, w, h, r, color)
    if r > math.floor(math.min(w, h) / 2) then r = math.floor(math.min(w, h) / 2) end
    bb:paintRect(x + r, y, w - 2 * r, h, color)
    bb:paintRect(x, y + r, w, h - 2 * r, color)
    bb:paintCircle(x + r, y + r, r, color)
    bb:paintCircle(x + w - r - 1, y + r, r, color)
    bb:paintCircle(x + r, y + h - r - 1, r, color)
    bb:paintCircle(x + w - r - 1, y + h - r - 1, r, color)
end

function Switch:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.dimen.w, self.dimen.h
    local r = math.floor(h / 2)
    local on = self.on == true
    local stroke = px(2)
    -- 参考图：on = 纯黑长条 + 白圆点；off = 白底黑描边 + 黑圆点。
    if on then
        roundRect(bb, x, y, w, h, r, BLACK)
    else
        roundRect(bb, x, y, w, h, r, BLACK)
        roundRect(bb, x + stroke, y + stroke, w - 2 * stroke, h - 2 * stroke,
            math.max(1, r - stroke), WHITE)
    end
    local cx = on and (x + w - r - 1) or (x + r + 1)
    bb:paintCircle(cx, y + r, math.max(1, r - stroke - 1), on and WHITE or BLACK)
end

function Switch:_dirty(mode)
    if type(self.dirty) == "function" then
        self.dirty(mode)
    else
        UIManager:setDirty(nil, mode, self.dimen:copy())
    end
end

function Switch:onTapSwitch()
    self.on = not self.on
    if self.callback then self.callback(self.on) end
    self:_dirty("ui")
    return true
end

function S.switch(on, callback, width, height, dirty, id)
    return Switch:new{ on = on == true, callback = callback,
        width = width, height = height, dirty = dirty, id = id }
end

function S.setSwitchOn(widget, on)
    if widget then widget.on = on == true end
end

-- ------------------------------------------------------------- Rule/Panel --
local Rule = Widget:extend{}

function Rule:getSize()
    return Geom:new{ w = self.width or 0, h = px(1) }
end

function Rule:paintTo(bb, x, y)
    bb:paintRect(x, y, self.width or 0, px(1), GRAY)
end

function S.rule(width) return Rule:new{ width = width } end

-- ----------------------------------------------------------- BottomSheet --
-- 阅读器设置界面不是全屏页：正文仍留在屏幕上方，面板贴底弹出。
-- covers_fullscreen=false 让 UIManager 只刷新面板区域，不把正文擦成白底。
local BottomSheet = InputContainer:extend{ modal = true, covers_fullscreen = false }

function BottomSheet:init()
    self.dimen = Screen:getSize()
    self.ges_events.TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } }
    if Device:hasKeys() then
        self.key_events.Close = { { "Back" }, { "Esc" } }
    end
end

function BottomSheet:onTapOutside(_, ges)
    -- 面板内的 tap 由子控件处理；这里只关「面板上方」的空白区域。
    local panel_h = self.panel_dimen and self.panel_dimen.h or 0
    if ges.pos.y >= self.dimen.h - panel_h then return true end
    if type(self.onCloseSheet) == "function" then self.onCloseSheet() end
    return true
end

function BottomSheet:onClose()
    if type(self.onCloseSheet) == "function" then self.onCloseSheet() end
    return true
end

function BottomSheet:onShow()
    UIManager:setDirty(nil, "ui")
end

function S.bottomSheet(content, on_close)
    local sheet = BottomSheet:new()
    local frame = FrameContainer:new{
        bordersize = px(2), padding = px(10),
        color = BLACK, background = WHITE,
        content,
    }
    sheet[1] = BottomContainer:new{
        dimen = sheet.dimen:copy(),
        frame,
    }
    sheet.panel_dimen = frame:getSize()
    sheet.onCloseSheet = on_close
    return sheet
end

S.px = px
S.BLACK, S.WHITE, S.GRAY, S.DGRAY = BLACK, WHITE, GRAY, DGRAY
S.HorizontalGroup = HorizontalGroup
S.VerticalGroup = VerticalGroup

return S
