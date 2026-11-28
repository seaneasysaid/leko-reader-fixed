--[[--
排版设置：简洁风格的底部弹窗（正文仍留在屏幕上方，不遮挡整屏）。

  ┌ 正文 ────────────────────────────┐
  │                                  │
  │ ┌──────────────────────────────┐ │
  │ │ 排版设置      首行缩进 [开关]  │ │
  │ │ ──────────────────────────── │ │
  │ │ 字号  − ●────────── ＋  27   │ │
  │ │ …（共六行滑块，右侧显示当前刻度）… │ │
  │ │ (字体)      (阅读状态栏)       │ │
  │ │ (保存为默认排版)(恢复默认排版)  │ │
  │ │ (关闭)                       │ │
  │ └──────────────────────────────┘ │
  └──────────────────────────────────┘

滑块刻度直接对齐阅读器排版：
  字号 12~72 / 0.5；字重 -3~5.5 / 0.25；行距 80%~200% / 10%；
  段间距 0~2em / 0.25em；左右边距 8~48 / 2；上下边距 2~40 / 2。
leko 不是 crengine，字重与段距按 Leko/FontWeight.lua、ReaderView 的
paragraph_spacing_em 换算到自己的渲染语义；数值语义由 ReaderView:applyStyleChange
与 Paginator 决定，本页只负责外观与吸附刻度。
--]]
local Device = require("device")
local HorizontalSpan = require("ui/widget/horizontalspan")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local FontSelectionView = require("Leko/FontSelectionView")
local FontWeight = require("Leko/FontWeight")
local Storage = require("Leko/Storage")
local W = require("Leko/InkStyle")

local LayoutSettingsView = {}

local function snap(value, minimum, maximum, step)
    local number = tonumber(value) or minimum
    local steps = math.floor((number - minimum) / step + 0.5)
    number = minimum + steps * step
    if number < minimum then return minimum end
    if number > maximum then return maximum end
    return number
end

-- 27.00 -> 27；27.50 -> 27.5；-3.00 -> -3。
local function formatNumber(value)
    local text = string.format("%.2f", tonumber(value) or 0)
    text = text:gsub("0+$", ""):gsub("%.$", "")
    if text == "-0" then text = "0" end
    return text
end

function LayoutSettingsView:new(opts)
    opts = opts or {}
    local style = opts.style or {}
    local sheet
    local function apply(fn) if type(opts.onApply) == "function" then opts.onApply(fn) end end
    local function close(after)
        UIManager:close(sheet, "ui")
        if type(after) == "function" then UIManager:nextTick(after) end
    end
    -- setDirty(nil, ...) 不会标脏 widget，自绘滑块/开关必须传宿主弹窗才会重画。
    local function dirty(mode)
        if sheet then UIManager:setDirty(sheet, mode or "ui") end
    end

    local width = Screen:getWidth()
    local panel_w = width - W.px(16)
    local inner_w = panel_w - W.px(24)   -- 面板 padding(10)*2 + 边框(2)*2

    local body = VerticalGroup:new{}
    body[#body + 1] = W.HorizontalGroup:new{
        W.label("排版设置", inner_w - W.px(148), 20, true, "left"),
        W.label("首行缩进", W.px(72), 14, false, "right", W.DGRAY),
        W.switch(style.indent ~= false, function(on)
            apply(function(s) s.indent = on and 2 or false end)
        end, nil, nil, dirty),
    }
    body[#body + 1] = VerticalSpan:new{ width = W.px(5) }
    body[#body + 1] = W.rule(inner_w)
    body[#body + 1] = VerticalSpan:new{ width = W.px(5) }

    -- 标签列收窄让滑块左移，右侧留出当前刻度列（与设备控制同一套布局口径）。
    local label_w = math.floor(inner_w * 0.20)
    local step_w = W.px(42)
    local value_w = W.px(56)
    local slider_w = inner_w - label_w - 2 * step_w - value_w

    -- formatter 把吸附后的刻度换成统一口径的显示值；拖动中也实时刷新。
    local function sliderRow(label, minimum, maximum, step, value, callback, formatter)
        formatter = formatter or formatNumber
        local value_widget = W.label("", value_w, 14, false, "right")
        local slider
        local function render(v, mode)
            v = snap(v, minimum, maximum, step)
            if slider then slider.value = v end
            value_widget:setText(formatter(v))
            dirty(mode or "fast")
        end
        slider = W.Slider:new{
            width = slider_w, minimum = minimum, maximum = maximum, step = step,
            value = value,
            preview_callback = function(v) render(v, "fast") end,
            callback = function(v) callback(v); render(v, "ui") end,
            dirty = dirty,
        }
        local function nudge(delta)
            local v = snap(slider.value + delta, minimum, maximum, step)
            render(v, "ui")
            callback(v)
        end
        body[#body + 1] = W.HorizontalGroup:new{
            W.label(label, label_w, 18, false, "left"),
            W.stepButton(false, function() nudge(-step) end, step_w),
            slider,
            W.stepButton(true, function() nudge(step) end, step_w),
            value_widget,
        }
        body[#body + 1] = VerticalSpan:new{ width = W.px(3) }
        render(value, "fast")
    end

    -- 行距刻度是百分比；leko 的 line_spacing 是在 1 之上的 em 增量。
    local function linePercent(spacing)
        return snap(100 + (tonumber(spacing) or 0.28) * 100, 80, 200, 10)
    end
    -- 老存档只有像素段距；第一次动字号/段距时把它记成 em，之后随字号缩放。
    local function paragraphEm(current)
        if type(current.paragraph_spacing_em) == "number" then
            return snap(current.paragraph_spacing_em, 0, 2, 0.25)
        end
        local size = tonumber(current.body_font_size) or 27
        return snap((tonumber(current.paragraph_spacing) or 10) / size, 0, 2, 0.25)
    end

    sliderRow("字号", 12, 72, 0.5, snap(style.body_font_size or 27, 12, 72, 0.5),
        function(v)
            apply(function(s)
                local old_size = tonumber(s.body_font_size) or 27
                local px = tonumber(s.paragraph_spacing) or 0
                s.body_font_size = v
                if type(s.paragraph_spacing_em) ~= "number" and old_size > 0 then
                    s.paragraph_spacing_em = px / old_size
                end
            end)
        end)
    sliderRow("字重", FontWeight.MIN, FontWeight.MAX, FontWeight.STEP,
        FontWeight.clamp(style.body_weight or 0), function(v)
            apply(function(s) s.body_weight = v end)
        end)
    sliderRow("行距", 80, 200, 10, linePercent(style.line_spacing), function(v)
        apply(function(s)
            s.line_spacing = tonumber(string.format("%.2f", (v - 100) / 100))
        end)
    end, function(v) return string.format("%d%%", v) end)
    sliderRow("段间距", 0, 2, 0.25, paragraphEm(style), function(v)
        apply(function(s)
            s.paragraph_spacing_em = v
            s.paragraph_spacing = v * (tonumber(s.body_font_size) or 27)
        end)
    end)
    sliderRow("左右边距", 8, 48, 2, snap(style.margin_left or 28, 8, 48, 2), function(v)
        apply(function(s) s.margin_left, s.margin_right = v, v end)
    end)
    sliderRow("上下边距", 2, 40, 2, snap(style.margin_top or 12, 2, 40, 2), function(v)
        apply(function(s) s.margin_top, s.margin_bottom = v, v end)
    end)

    body[#body + 1] = VerticalSpan:new{ width = W.px(3) }
    body[#body + 1] = W.rule(inner_w)
    body[#body + 1] = VerticalSpan:new{ width = W.px(6) }

    local pill_gap = W.px(8)
    local pill_w = math.floor((inner_w - pill_gap) / 2)
    local function pillPair(a_text, a_cb, b_text, b_cb)
        return W.HorizontalGroup:new{
            W.pill(a_text, pill_w, a_cb),
            HorizontalSpan:new{ width = pill_gap },
            W.pill(b_text, pill_w, b_cb),
        }
    end

    local function fontPillText()
        local name = FontSelectionView:getDisplayName(style)
        if name == FontSelectionView.SYSTEM_DISPLAY_NAME then name = "系统字体" end
        -- pill 只有半行宽：按字节截断后去掉尾部不完整的 UTF-8 字节。
        if #name > 21 then name = name:sub(1, 21):gsub("[\128-\191]+$", "") .. "…" end
        return "字体：" .. name
    end
    body[#body + 1] = pillPair(
        fontPillText(), function() close(function() if opts.onFont then opts.onFont() end end) end,
        "阅读状态栏", function() close(function() if opts.onStatus then opts.onStatus() end end) end)
    body[#body + 1] = VerticalSpan:new{ width = W.px(6) }
    body[#body + 1] = pillPair(
        "保存为默认排版", function()
            Storage:saveReaderStyle(style)
            UIManager:show(require("ui/widget/notification"):new{ text = "已保存为默认排版" })
        end,
        "恢复默认排版", function()
            apply(function(s)
                local default = Storage:getDefaultReaderStyle()
                for _, key in ipairs({
                    "body_font_size", "body_weight", "line_spacing", "paragraph_spacing",
                    "paragraph_spacing_em",
                    "indent", "text_align", "margin_left", "margin_right",
                    "margin_top", "margin_bottom",
                }) do s[key] = default[key] end
            end)
        end)
    body[#body + 1] = VerticalSpan:new{ width = W.px(6) }
    body[#body + 1] = W.pill("关闭", inner_w, function() close() end, W.px(40))

    sheet = W.bottomSheet(body, function() close() end)
    sheet.onCloseWidget = function()
        if type(opts.onClosed) == "function" then opts.onClosed() end
    end
    return sheet
end

return LayoutSettingsView
