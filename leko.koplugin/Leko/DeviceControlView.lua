--[[--
设备控制：简洁风格的底部弹窗（正文仍留在屏幕上方，不遮挡整屏）。

  ┌ 正文 ────────────────────────────┐
  │ ┌──────────────────────────────┐ │
  │ │          设备控制             │ │
  │ │ 亮度 − ●─────── ＋  12        │ │
  │ │ 色温 − ●─────── ＋   5        │ │
  │ │ ──────────────────────────── │ │
  │ │ 夜间模式            [开关]    │ │
  │ │ 反转屏幕明暗                  │ │
  │ │ 翻页动画            [开关]    │ │
  │ │ 翻页时显示滑动效果            │ │
  │ └──────────────────────────────┘ │
  └──────────────────────────────────┘

亮度/色温直接调 KOReader 的 PowerDevice；翻页动画沿用 KOReader 全局
swipe_animations；夜间模式也走 KOReader 全局 framebuffer 反转。
--]]
local Device = require("device")
local Event = require("ui/event")
local Screen = Device.screen
local HorizontalSpan = require("ui/widget/horizontalspan")
local RightContainer = require("ui/widget/container/rightcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Geom = require("ui/geometry")

local W = require("Leko/InkStyle")

local DeviceControlView = {}

local function powerDevice()
    local ok, powerd = pcall(function() return Device:getPowerDevice() end)
    return ok and powerd or nil
end

function DeviceControlView:new(opts)
    opts = opts or {}
    local sheet
    local function close()
        UIManager:close(sheet, "ui")
    end
    -- setDirty(nil, ...) 只入队刷新队列、不标脏 widget：自绘滑块/开关必须
    -- 把宿主弹窗传进去，值改了才会重新 paintTo。
    local function dirty(mode)
        if sheet then UIManager:setDirty(sheet, mode or "ui") end
    end

    local width = Screen:getWidth()
    local panel_w = width - W.px(16)
    local inner_w = panel_w - W.px(24)

    local body = VerticalGroup:new{}
    body[#body + 1] = W.label("设备控制", inner_w, 20, true, "center")
    body[#body + 1] = VerticalSpan:new{ width = W.px(18) }

    -- 屏幕方向：与 KOReader 原生 rotation 菜单同一套常量（竖屏 0 / 逆时针 3 / 顺时针 1）。
    -- 走广播让宿主一并转屏，leko ReaderView 会在 onSetRotationMode 里重建尺寸/分页。
    -- 三个紧凑按钮跟标签同一行（Sean 2026-11-28：按钮别太大、放标签后面）。
    local rot_label_w = math.floor(inner_w * 0.20)
    local rot_gap = W.px(6)
    local rot_h = W.px(32)
    local rot_font = 13
    local rot_w = math.floor((inner_w - rot_label_w - 3 * rot_gap) / 3)
    local rot_options = {
        { text = "竖屏", mode = Screen.DEVICE_ROTATED_UPRIGHT },
        { text = "逆时针 90°", mode = Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE },
        { text = "顺时针 90°", mode = Screen.DEVICE_ROTATED_CLOCKWISE },
    }
    local rot_row = W.HorizontalGroup:new{
        W.label("屏幕方向", rot_label_w, 18, true, "left"),
        HorizontalSpan:new{ width = rot_gap },
    }
    for i, opt in ipairs(rot_options) do
        if i > 1 then rot_row[#rot_row + 1] = HorizontalSpan:new{ width = rot_gap } end
        local selected = Screen:getRotationMode() == opt.mode
        rot_row[#rot_row + 1] = W.pill(opt.text, rot_w, function()
            -- full 关弹窗：ui 只标脏弹窗区域，转屏后那块旧像素会残留成竖条。
            UIManager:close(sheet, "full")
            UIManager:broadcastEvent(Event:new("SetRotationMode", opt.mode))
        end, rot_h, selected, "leko_rot_" .. tostring(opt.mode), rot_font)
    end
    body[#body + 1] = rot_row
    body[#body + 1] = VerticalSpan:new{ width = W.px(14) }

    local label_w = math.floor(inner_w * 0.20)
    local step_w = W.px(42)
    local value_w = W.px(52)
    local slider_w = inner_w - label_w - 2 * step_w - value_w

    local function levelRow(label, get, lo, hi, set)
        local ok, value = pcall(get)
        if not ok or type(value) ~= "number" then value = lo end
        value = math.max(lo, math.min(hi, value))
        local value_widget = W.label("", value_w, 14, false, "right")
        local slider
        local function render(v, mode)
            if slider then slider.value = v end
            -- 直接显示 powerd 的原生刻度：亮度 Kindle 0..24 / Kobo 0..100，
            -- 色温由 KOReader 归一到 0..100。不再换算成百分比，跟系统设置一致。
            value_widget:setText(string.format("%d", math.floor(v + 0.5)))
            dirty(mode or "fast")
        end
        -- 拖动中只更新滑块与刻度（设备不用跟着每一格抖动）；松手/点按才 set。
        local function preview(v)
            render(math.max(lo, math.min(hi, v)), "fast")
        end
        local function apply(v)
            v = math.max(lo, math.min(hi, v))
            render(v, "ui")
            local ok2 = pcall(set, v)
            if not ok2 then
                UIManager:show(require("ui/widget/notification"):new{ text = label .. "调整未完成" })
            end
        end
        slider = W.Slider:new{
            width = slider_w, minimum = lo, maximum = hi, step = 1,
            value = value, callback = apply,
            preview_callback = preview, dirty = dirty,
        }
        preview(value)
        body[#body + 1] = W.HorizontalGroup:new{
            W.label(label, label_w, 18, true, "left"),
            W.stepButton(false, function() apply(slider.value - 1) end, step_w),
            slider,
            W.stepButton(true, function() apply(slider.value + 1) end, step_w),
            value_widget,
        }
        body[#body + 1] = VerticalSpan:new{ width = W.px(16) }
    end

    -- 与 KOReader 原生一致：能力看 Device，读写看 powerd。之前错误地要求
    -- powerd 自己也提供 hasFrontlight/hasNaturalLight，导致两台机器都不显示。
    local powerd = powerDevice()
    local function can(fn, ...)
        local ok, supported = pcall(function()
            return type(Device[fn]) == "function" and Device[fn](Device) and true or false
        end)
        if not ok or not supported then return false end
        for _, method in ipairs({ ... }) do
            if type(powerd) ~= "table" or type(powerd[method]) ~= "function" then
                return false
            end
        end
        return true
    end
    if can("hasFrontlight", "frontlightIntensity", "setIntensity") then
        levelRow("亮度", function() return powerd:frontlightIntensity() end,
            powerd.fl_min or 0, powerd.fl_max or 100,
            function(v) powerd:setIntensity(v) end)
    end
    -- ⭐ 色温必须走 KOReader 原生 FrontLightWidget 的硬件刻度链路：
    --   读：toNativeWarmth(frontlightWarmth())，范围 fl_warmth_min..fl_warmth_max
    --   写：setWarmth(fromNativeWarmth(v))，把硬件刻度转回 KOReader 的 0..100
    -- 之前直接拿 frontlightWarmth()(KOReader 0..100) 当 0..100 显示，Kobo 上
    -- 数字对不上机器自己的 1..10 档位。其他实现直接写死 0..100 是简化，
    -- Sean 要求「跟系统自身刻度一致」，所以按 KOReader 原生控件来。
    if can("hasNaturalLight", "frontlightWarmth", "setWarmth")
        and type(powerd.toNativeWarmth) == "function"
        and type(powerd.fromNativeWarmth) == "function" then
        levelRow("色温",
            function() return powerd:toNativeWarmth(powerd:frontlightWarmth()) end,
            powerd.fl_warmth_min or 0, powerd.fl_warmth_max or 100,
            function(v) powerd:setWarmth(powerd:fromNativeWarmth(v)) end)
    else
        -- 老设备 powerd 没有原生刻度换算函数时退回 KOReader 0..100。
        if can("hasNaturalLight", "frontlightWarmth", "setWarmth") then
            levelRow("色温", function() return powerd:frontlightWarmth() end,
                0, 100, function(v) powerd:setWarmth(v) end)
        end
    end

    body[#body + 1] = W.rule(inner_w)
    body[#body + 1] = VerticalSpan:new{ width = W.px(16) }

    local function toggleRow(title, subtitle, get, set, id)
        local sw
        sw = W.switch(get() == true, function(on)
            set(on)
            W.setSwitchOn(sw, on)
            dirty("ui")
        end, nil, nil, dirty, id)
        local line = VerticalGroup:new{
            W.label(title, inner_w - W.px(70), 18, true, "left"),
            VerticalSpan:new{ width = W.px(2) },
            W.label(subtitle, inner_w - W.px(70), 14, false, "left", W.DGRAY),
        }
        body[#body + 1] = W.HorizontalGroup:new{
            line,
            RightContainer:new{
                dimen = Geom:new{ w = W.px(56), h = line:getSize().h },
                sw,
            },
        }
        body[#body + 1] = W.rule(inner_w)
        body[#body + 1] = VerticalSpan:new{ width = W.px(15) }
    end

    -- ⭐ 与 KOReader 全局一致：夜间模式走 KOReader 全局反转，不再用 leko
    -- 自己的 style.night_mode（那是只反阅读页的局部方案）。devicelistener
    -- 的 onToggleNightMode 会 Screen:toggleNightMode() + 全屏 full 刷新。
    toggleRow("夜间模式", "反转屏幕明暗", function()
        return Screen.night_mode == true
    end, function(v)
        if (Screen.night_mode == true) ~= v then
            local ok = pcall(function()
                require("device/devicelistener"):new{}:onToggleNightMode()
            end)
            if not ok and G_reader_settings then
                -- 兜底：直接切全局并保存设置。
                Screen:toggleNightMode()
                G_reader_settings:saveSetting("night_mode", v)
                G_reader_settings:flush()
                UIManager:setDirty("all", "full")
            end
        end
    end)
    -- G_reader_settings 是 KOReader 启动时注入的全局单例，不是可 require 的模块。
    -- 之前 require("G_reader_settings") 必然失败，开关点了也只是空转。
    toggleRow("翻页动画", "翻页时显示滑动效果", function()
        return G_reader_settings ~= nil and G_reader_settings:isTrue("swipe_animations")
    end, function(v)
        if G_reader_settings then
            G_reader_settings:saveSetting("swipe_animations", v)
            G_reader_settings:flush()
        end
        if not v and Screen.setSwipeAnimations then Screen:setSwipeAnimations(false) end
    end)
    -- 段评气泡开关：读写 leko 自己的 style.para_review_enabled。
    -- 真正的重排必须走 ReaderView:setParaReviewEnabled（它会清缓存 + 重排），
    -- 所以优先用宿主回调；没有回调时退回 onApply 只改 style 值。
    toggleRow("段评", "显示段落评论气泡", function()
        return opts.style and opts.style.para_review_enabled == true
    end, function(v)
        if type(opts.onParaReviewChanged) == "function" then
            opts.onParaReviewChanged(v)
        elseif type(opts.onApply) == "function" then
            opts.onApply(function(s) s.para_review_enabled = v end)
        end
    end, "leko_switch_para")

    body[#body + 1] = W.pill("关闭", inner_w, function() close() end, W.px(40))

    sheet = W.bottomSheet(body, close)
    sheet.onCloseWidget = function()
        if type(opts.onClosed) == "function" then opts.onClosed() end
    end
    return sheet
end

return DeviceControlView
