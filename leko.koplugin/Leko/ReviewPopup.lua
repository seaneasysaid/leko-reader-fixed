--[[--
Leko 段评弹窗（微信读书「想法」式富排版）。

渲染一条段评下的所有评论，两种承载位置：

  * "bottom"（默认）：底部栏（顶部一条实线分隔），长内容在 bitmap 视口内
    上下滚动 —— leko 用的是这一种；
  * "center"：居中弹窗（本移植未带该变体，`widgetClassFor` 只认 bottom）。

排版管线（`Leko/review_popup/pages.lua`）负责分段、分页与位图缓存；本模块是
公共入口，弹窗按位置池化复用（重开同一段的评论不重建任何位图）。

移植自番茄插件的 `fanqie/review_popup.lua`（其本身移植自 weread.koplugin 的
thought_popup）。与原版的差别见 `face_factory.lua` 顶部注释：leko 不是
crengine，字体与字号由 leko 的阅读样式直接给出，不走 cre 解析。

@module Leko.ReviewPopup
--]]

local FaceFactory = require("Leko/review_popup/face_factory")
local UIManager = require("ui/uimanager")

FaceFactory:init()

local M = {}
local _pool = {}  -- position -> pooled widget

--- The widget class for a position; required lazily so the entry can be
--- loaded without instantiating UI.
local function widgetClassFor(position)
    if position == "center" then
        -- leko 只带了 bottom 想法式变体；center 回落到 bottom，不影响功能。
        return require("Leko/review_popup/widget")
    end
    return require("Leko/review_popup/widget")
end

--[[--
显示（或复用池中实例重开）段评弹窗。

@param opts table
  pages          table   评论条目 { abstract, author, content, likes_count }
  position       string  "bottom"（默认；leko 只有这一种变体）
  font_name      string  KOReader 字体标识（"cfont" 或字体文件路径）
  font_size      number  已按屏幕缩放的像素字号
  doc_margins    table   { left, right, top, bottom }
  height_ratio   number  弹窗高度占屏比，默认 0.70
  contrast       number  灰阶位移（越大越黑）
  tap_to_page    bool    点左右半屏翻页
  para_nav       function(dir)  横滑切上一/下一段
  more_text      string  底部「继续加载」按钮文字（nil 则不显示）
  on_more        function 点「继续加载」时的回调
  close_callback function 关闭后回调，参数是弹窗实际高度
--]]
function M.show(opts)
    opts = opts or {}
    if type(opts.pages) ~= "table" or #opts.pages == 0 then
        error("Leko para popup: invalid pages")
    end

    -- The widget stores the records under "items"; the public contract uses
    -- "pages". Normalize once so the initial construction and the pooled
    -- reopen below both receive the items.
    opts.items = opts.items or opts.pages

    local position = "bottom"

    -- Only the active position stays resident: drop the other pool so its
    -- page/piece/layout caches (bitmaps) are not held for the whole session.
    for other_position, pooled in pairs(_pool) do
        if other_position ~= position then
            pcall(function()
                if UIManager:isWidgetShown(pooled) then
                    UIManager:close(pooled)
                end
            end)
            pooled:clear()
            pooled:_freeContentCaches()
            _pool[other_position] = nil
        end
    end

    local pooled = _pool[position]
    if pooled then
        -- 复用池实例（同一段的「继续加载」就走这条路）：先摘下来再重开，
        -- 免得同一个 widget 在 UIManager 栈上出现两次。
        if UIManager:isWidgetShown(pooled) then
            UIManager:close(pooled)
        end
        pooled:_reopen(opts)
        UIManager:show(pooled)
        return pooled
    end

    local popup = widgetClassFor(position):new{
        items = opts.items,
        -- 兼容原版字段名：doc_font_name / doc_font_size。
        doc_font_name = opts.doc_font_name or opts.font_name,
        doc_font_size = opts.doc_font_size or opts.font_size,
        doc_margins = opts.doc_margins,
        height_ratio = opts.height_ratio,
        width_ratio = opts.width_ratio,
        contrast = opts.contrast,
        tap_to_page = opts.tap_to_page,
        dialog = opts.dialog,
        close_callback = opts.close_callback,
        para_nav = opts.para_nav,
        more_text = opts.more_text,
        on_more = opts.on_more,
    }
    _pool[position] = popup
    popup._para_key = opts.paragraph_key
    UIManager:show(popup)
    return popup
end

--- 当前是否有段评弹窗在屏幕上（用于翻页/切章前收摊）。
function M.isShowing()
    for _, pooled in pairs(_pool) do
        local ok, shown = pcall(function()
            return UIManager:isWidgetShown(pooled)
        end)
        if ok and shown == true then
            return true
        end
    end
    return false
end

function M.closeVisible()
    for _, pooled in pairs(_pool) do
        pcall(function()
            UIManager:close(pooled)
        end)
    end
end

--- 释放池与位图缓存（换书 / 关闭阅读器时调用）。
function M.cleanup()
    if not next(_pool) then
        return
    end
    for _, pooled in pairs(_pool) do
        pcall(function()
            UIManager:close(pooled)
        end)
        -- clear() frees the subtree; bitmaps are freed by _freeContentCaches.
        pooled:clear()
        pooled:_freeContentCaches()
    end
    _pool = {}
end

return M
