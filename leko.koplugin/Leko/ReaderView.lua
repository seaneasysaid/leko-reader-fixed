local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local DeviceControlView = require("Leko/DeviceControlView")
local LayoutSettingsView = require("Leko/LayoutSettingsView")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Notification = require("ui/widget/notification")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TrapWidget = require("ui/widget/trapwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen

local AsyncImageFetch = require("Leko/AsyncImageFetch")
local AsyncParaReview = require("Leko/AsyncParaReview")
local BookService = require("Leko/BookService")
local FontSelectionView = require("Leko/FontSelectionView")
local KOReaderStatisticsBridge = require("Leko/KOReaderStatisticsBridge")
local Paginator = require("Leko/Paginator")
local ParaComments = require("Leko/ParaComments")
local ReaderFooter = require("Leko/ReaderFooter")
local ShushanAuth = require("Leko/ShushanAuth")
local Storage = require("Leko/Storage")
local TocView = require("Leko/TocView")
local UI = require("Leko/UI")
local Util = require("Leko/Util")

-- 翻页方向常量。leko 不再自带动画实现，翻页动画统一交给 KOReader 原生
-- swipe animation：翻页时设 Screen:setSwipeAnimations(true) + 方向标志，
-- UIManager:_repaint 里的动画补丁会在画新页前保存旧页、逐条带擦除。
-- 开关复用 KOReader 全局 G_reader_settings 的 swipe_animations（与 KOReader 原生一致）。
-- 全刷同理：翻页只发 "partial"（不带 region），由 KOReader 的
-- full_refresh_count（设置里的「全刷页数」）按全局计数自动升级为 full，
-- leko 不再自己强制整屏刷新，全刷节奏完全由 KOReader 决定。
local PageDirection = { FORWARD = "forward", BACKWARD = "backward" }

local ReaderView = InputContainer:extend{
    covers_fullscreen = true,
    -- Full-screen application pages must remain non-modal.
    -- KOReader keeps modal windows above ordinary dialogs, which would hide ButtonDialog.
    modal = false,
}

function ReaderView:init()
    self.style = Storage:getReaderStyle()
    self.history = {}
    self.menu_visible = false
    self._exit_dialog = nil
    self._closing = false
    self.prefetch_state = nil
    self._progress_dirty = false
    self._footer_dirty = true
    self.page_generation = 0
    -- 段评默认关闭。开启后为番茄 / 七猫 / QQ阅读章节拉取评论计数，并在段末显示 [N] 气泡。
    self.para_review_enabled = self.style.para_review_enabled == true
    -- 段末气泡的屏幕矩形（每次重画正文时重建），routeTap 用它做命中判定。
    self._para_hit_rects = {}
    -- 段评的「代」不在这里记账：由 ParaComments.hostKey(source) 现算。
    -- 原生源请求成功时会记住镜像，所以那张挂在章节模型上的计数表
    -- （以及「取失败，别再试」的标记）天然带着当时那台镜像，换镜像即作废。
    -- 段评取数一律在子进程里跑（Leko/AsyncParaReview），这里只记「挂在屏幕上的
    -- 等待提示」，以及当前这批请求属于哪一次点击 —— 换章 / 关阅读器后回来的
    -- 结果靠 token 判定为过期，直接丢掉。
    self._para_busy = nil
    self._para_busy_token = nil
    self._para_busy_timer = nil
    self._para_request_token = nil
    self._para_counts_token = nil
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = self.ges_events or {}
    self.key_events = self.key_events or {}

    if Device:isTouchDevice() then
        if self.registerTouchZones then
            self:registerTouchZones({
                {
                    id = "leko_reader_tap_router",
                    ges = "tap",
                    screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
                    handler = function(ges) return self:routeTap(ges) end,
                },
                {
                    id = "leko_reader_hold_router",
                    ges = "hold",
                    screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
                    handler = function() return self:toggleMenu(true) end,
                },
                {
                    id = "leko_reader_swipe_router",
                    ges = "swipe",
                    screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
                    handler = function(ges) return self:routeSwipe(ges) end,
                },
            })
        end
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } }
        self.ges_events.Hold = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } }
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } }
    end

    if Device:hasKeys() then
        self.key_events.Close = { { "Back" }, { "Esc" } }
        self.key_events.ReaderMenu = { { "Menu" } }
        self.key_events.PageForward = { { "Right" }, { "RPgFwd" }, { "LPgFwd" }, { "PgFwd" } }
        self.key_events.PageBackward = { { "Left" }, { "RPgBack" }, { "LPgBack" }, { "PgBack" } }
    end

    BookService:observePrefetch(self.book.id, self, function(state)
        self:onPrefetchProgress(state)
    end)

    local position = Util.positionCopy(self.book.position)
    local page, err = Paginator:makePage(self.book, position, self.style)
    if not page then page = self:errorPage(position, err) end
    self:consumeFontFallbackNotice()
    self:setPage(page, "full")
    self.statistics_bridge = KOReaderStatisticsBridge:new{}
    self.statistics_bridge:start(self.book, self:_statisticsVirtualPage())
end

local function clamp01(value)
    return math.max(0, math.min(1, tonumber(value) or 0))
end

function ReaderView:_progressMetrics(use_page_end)
    if not self.page or not self.book then return nil end
    local chapter_index = math.max(1, tonumber(self.page.chapter_index) or 1)
    local chapter_count = #(self.book.chapters or {})
    local model = self.page.chapter_model or BookService:loadChapterModel(self.book, chapter_index)
    local position = use_page_end and (self.page.next_position or self.page.start_position) or self.page.start_position
    local chapter_progress = model and ReaderFooter:percentage(model, position, chapter_index,
        self.page.at_end and use_page_end) or 0
    chapter_progress = clamp01(chapter_progress)
    return {
        chapter_index = chapter_index, chapter_count = chapter_count, model = model,
        chapter_progress = chapter_progress,
        book_progress = chapter_count > 0 and clamp01(((chapter_index - 1) + chapter_progress) / chapter_count) or 0,
    }
end

function ReaderView:_statisticsVirtualPage()
    local metrics = self:_progressMetrics(false)
    if not metrics then return 1 end
    local count = KOReaderStatisticsBridge.VIRTUAL_PAGE_COUNT
    return math.max(1, math.min(count, math.floor(metrics.book_progress * (count - 1)) + 1))
end

function ReaderView:_chapterPageMetrics()
    if not self.page or not self.book then return nil, nil end
    local chapter = tonumber(self.page.chapter_index) or 1
    local cache = self._public_page_metrics
    local signature = tostring(chapter) .. "\0" .. tostring(self.style and self.style.body_font_size or "")
        .. "\0" .. tostring(self.style and self.style.line_spacing or "")
        .. "\0" .. tostring(self.style and self.style.body_weight or 0)
    if not cache or cache.signature ~= signature then
        cache = { signature = signature, starts = {}, total = 0 }
        local position, safety = { chapter = chapter, paragraph = 1, char = 1 }, 0
        while safety < 20000 do
            safety = safety + 1
            local generated = Paginator:makePage(self.book, position, self.style)
            if not generated then break end
            local start = generated.start_position or {}
            local key = table.concat({ tostring(start.chapter or 1), tostring(start.paragraph or 1), tostring(start.char or 1) }, ":")
            cache.total = cache.total + 1
            cache.starts[key] = cache.total
            local next_position = generated.next_position
            if generated.at_end or not next_position or tonumber(next_position.chapter) ~= chapter
                    or Util.positionEqual(next_position, start) then break end
            position = next_position
        end
        self._public_page_metrics = cache
    end
    local current = self.page.start_position or {}
    local key = table.concat({ tostring(current.chapter or 1), tostring(current.paragraph or 1), tostring(current.char or 1) }, ":")
    return cache.starts[key], cache.total > 0 and cache.total or nil
end

function ReaderView:getCurrentReadingContext()
    local metrics = self:_progressMetrics(true)
    if self._closing or not metrics or not self.book or not self.page then return { api_version = 1, active = false } end
    local chapter = self.book.chapters and self.book.chapters[metrics.chapter_index]
    local chapter_page, chapter_pages = self:_chapterPageMetrics()
    local cover_path = tostring(self.book.cover_path or "")
    if cover_path == "" then cover_path = nil end
    return {
        api_version = 1, active = true, book_id = tostring(self.book.id),
        title = tostring(self.book.title or ""), author = tostring(self.book.author or ""),
        cover_path = cover_path, chapter_title = tostring((chapter and chapter.title) or self.page.chapter_title or ""),
        chapter_index = metrics.chapter_index, chapter_count = metrics.chapter_count,
        chapter_page = chapter_page, chapter_pages = chapter_pages,
        chapter_progress = metrics.chapter_progress, book_progress = metrics.book_progress,
        statistics_id = self.statistics_bridge and self.statistics_bridge.statistics_id or nil,
    }
end

function ReaderView:consumeFontFallbackNotice()
    if not self.style or not self.style._font_fallback_pending then return false end
    self.style._font_fallback_pending = nil
    Storage:saveReaderStyle(self.style)
    UIManager:show(Notification:new{ text = "原字体不可用，已恢复系统默认字体" })
    return true
end

function ReaderView:errorPage(position, err)
    local geometry = Paginator:getGeometry(self.style)
    return {
        start_position = Util.positionCopy(position),
        next_position = Util.positionCopy(position),
        elements = {{ type = "line", text = "加载失败：" .. tostring(err), height = geometry.body_line_height }},
        chapter_index = position.chapter,
        chapter_title = self.book.chapters[position.chapter] and self.book.chapters[position.chapter].title or self.book.title,
        geometry = geometry,
        style = self.style,
        used_height = geometry.body_line_height,
        at_end = true,
    }
end

function ReaderView:getMenuMetrics()
    local top_h = math.max(56, math.floor(self.dimen.h * 0.075))
    -- One compact action row. Font/layout controls live in the bottom sheet.
    -- 底部四项菜单条与顶部同高（原来 64 / 0.09 偏高），上下留白收紧、更对称。
    local bottom_h = math.max(56, math.floor(self.dimen.h * 0.075))
    return top_h, bottom_h
end

function ReaderView:_syncPrefetchState()
    if not self.book or type(BookService.getPrefetchState) ~= "function" then
        return self.prefetch_state
    end
    self.prefetch_state = BookService:getPrefetchState(self.book.id)
    return self.prefetch_state
end

function ReaderView:refreshFooterFromCache(refresh_type)
    if self._closing or not self.page then return false end
    self:_settleSwipeRefresh()
    self:_syncPrefetchState()
    self._footer_dirty = true
    local region = self.menu_visible and self.dimen or self:_footerRegion()
    return self:rebuild(refresh_type or "full", region or self.dimen)
end

function ReaderView:_scheduleFooterRefresh(force)
    return UI.defer(self, "footer_restore", function()
        if self._closing or not self.page then return end
        if not force and (self.menu_visible
                or (UIManager.isWidgetShown and not UIManager:isWidgetShown(self))) then
            return
        end
        self:refreshFooterFromCache(force and "full" or "fast")
    end)
end

-- ⭐ 本章页数（页脚 N/M 页）。
-- leko 本身是惰性分页：makePage 从任意位置往后填满一屏。这里用**同一个**
-- Paginator:makePage 从章首顺序跑一遍，得到 {页起点 -> 页号} 与总页数，
-- 所以「第 N 页」和真实翻页严格对齐（另写一套排版必然错位）。
-- 代价是每章要排一次版：分片跑（每 tick 几页），首屏照旧走惰性分页，
-- 页表就绪前页脚仍显示百分比，就绪后自动刷新成 N/M。样式一变签名失配即重排。
local CHAPTER_PAGES_PER_TICK = 3
local CHAPTER_PAGES_MAX = 4000

local function chapterPageKey(position)
    position = position or {}
    return table.concat({
        tostring(position.chapter or 1),
        tostring(position.paragraph or 1),
        tostring(position.char or 1),
    }, ":")
end

local function normalizeChapterPosition(position)
    position = position or {}
    return {
        chapter = tonumber(position.chapter) or 1,
        paragraph = tonumber(position.paragraph) or 1,
        char = tonumber(position.char) or 1,
    }
end

-- 精确命中「这一页的起点」最好；不是跨页位置时（改字体/字号后页面是从旧位置
-- 重排的，起点通常不落在新分页的页边界上）退化为「包含该位置的页」：
-- 取最后一个 <= 当前位置的页起点。这和 KOReader 自带阅读器的口径一致，
-- 也是唯一能避免「一改字体就永远只剩百分比」的做法。
local function chapterPageLookup(cache, position)
    if not cache then return nil end
    position = normalizeChapterPosition(position)
    if tonumber(cache.chapter) and position.chapter ~= tonumber(cache.chapter) then
        return nil
    end
    local exact = cache.starts[chapterPageKey(position)]
    if exact then return exact end
    local order = cache.order
    if not order or #order == 0 then return nil end
    local low, high, found = 1, #order, nil
    while low <= high do
        local mid = math.floor((low + high) / 2)
        if Util.positionLess(order[mid], position) or Util.positionEqual(order[mid], position) then
            found = mid
            low = mid + 1
        else
            high = mid - 1
        end
    end
    return found
end

function ReaderView:_chapterPagesSignature(chapter)
    local style = self.style or {}
    return table.concat({
        tostring(self.book and self.book.id or ""),
        tostring(chapter),
        tostring(Screen:getWidth()), tostring(Screen:getHeight()),
        tostring(style.body_font or ""), tostring(style.body_font_index or 0),
        tostring(style.body_font_size or 0), tostring(style.body_weight or 0),
        tostring(style.line_spacing or 0), tostring(style.paragraph_spacing or 0),
        tostring(style.margin_left or 0), tostring(style.margin_right or 0),
        tostring(style.margin_top or 0), tostring(style.margin_bottom or 0),
        tostring(style.show_header and 1 or 0),
    }, "|")
end

-- 页表可用就返回 (页号, 总页数)，否则返回 nil 并在后台开始构建。
function ReaderView:_footerChapterPages(page)
    if not self.book or not page then return nil, nil end
    local chapter = tonumber(page.chapter_index) or 1
    local signature = self:_chapterPagesSignature(chapter)
    local cache = self._chapter_page_cache
    if not cache or cache.signature ~= signature then
        if self._chapter_pages_failed_sig ~= signature then
            self:_startChapterPageTable(chapter, signature)
        end
        return nil, nil
    end
    local number = chapterPageLookup(cache, page.start_position)
    if not number then return nil, nil end
    return number, cache.total > 0 and cache.total or nil
end

function ReaderView:_startChapterPageTable(chapter, signature)
    local pending = self._chapter_page_build
    if pending and pending.signature == signature then return end
    local state = {
        signature = signature,
        chapter = chapter,
        starts = {},
        order = {},
        total = 0,
        position = { chapter = chapter, paragraph = 1, char = 1 },
    }
    self._chapter_page_build = state
    self:_stepChapterPageTable(state)
end

function ReaderView:_stepChapterPageTable(state)
    if self._closing or self._chapter_page_build ~= state then return end
    local chapter = state.chapter
    local finished = false
    local produced = 0
    while produced < CHAPTER_PAGES_PER_TICK and state.total < CHAPTER_PAGES_MAX do
        local generated = Paginator:makePage(self.book, state.position, self.style)
        if not generated then
            finished = true
            break
        end
        local start = generated.start_position or {}
        state.total = state.total + 1
        state.starts[chapterPageKey(start)] = state.total
        state.order[state.total] = normalizeChapterPosition(start)
        produced = produced + 1
        local next_position = generated.next_position
        if generated.at_end or not next_position
                or tonumber(next_position.chapter) ~= chapter
                or Util.positionEqual(next_position, start) then
            finished = true
            break
        end
        state.position = next_position
    end
    if not finished and state.total < CHAPTER_PAGES_MAX then
        UIManager:nextTick(function()
            if self._chapter_page_build == state then
                self:_stepChapterPageTable(state)
            end
        end)
        return
    end

    self._chapter_page_build = nil
    if state.total > 0 then
        self._chapter_page_cache = state
        self._chapter_pages_failed_sig = nil
    else
        -- 排不出来就记住，避免每次重绘都重试一遍拖慢翻页。
        self._chapter_pages_failed_sig = state.signature
        return
    end
    -- 菜单/弹窗开着时不重绘（下次重建自然会吃到新页表），避免叠加刷新。
    if self.page and tonumber(self.page.chapter_index) == chapter and not self._closing
            and not self.menu_visible then
        self:refreshFooterFromCache("ui")
    end
end

-- 页眉时间不刷新就会停在翻开那一刻。每到一个整分钟只重绘页眉那条窄带，
-- 不做整屏刷新；不在前台/关页/隐藏页眉时自动停表。
function ReaderView:_ensureClockTimer()
    if self._clock_timer or self._closing then return end
    -- 时间已经挪到页脚左下角（Sean 2026-11-02），所以生命线跟着页脚走。
    -- 状态栏细分开关：关了页脚或时间、或关了「每分钟自动刷新」就不起表，
    -- 免得为一条看不见的时钟每分钟重绘一次页脚。
    if not self.page or not self.style.show_footer or self.style.show_time == false
            or self.style.status_minute_refresh == false then return end
    local ok, seconds = pcall(os.date, "%S")
    local delay = 60 - (tonumber(seconds) or 0)
    if delay < 1 then delay = 1 end
    self._clock_timer = function()
        self._clock_timer = nil
        if self._closing or not self.page or not self.style.show_footer
                or self.style.show_time == false
                or self.style.status_minute_refresh == false then return end
        if UIManager.isWidgetShown and not UIManager:isWidgetShown(self) then return end
        -- 时间在页脚左下角：只重绘页脚那条，正文和页眉都不动。
        self:rebuild("ui", self:_footerRegion() or self.dimen)
        self:_ensureClockTimer()
    end
    UIManager:scheduleIn(delay, self._clock_timer)
end

-- Wi-Fi / 充电状态变化时重绘页眉（图标就在那儿）。这类事件很少，整页 ui 重绘可接受。
function ReaderView:_refreshStatusChrome()
    if self._closing or not self.page then return end
    self:_settleSwipeRefresh()
    self:rebuild("ui")
end

function ReaderView:onCharging() self:_refreshStatusChrome() end
function ReaderView:onNotCharging() self:_refreshStatusChrome() end
function ReaderView:onNetworkConnected() self:_refreshStatusChrome() end
function ReaderView:onNetworkDisconnected() self:_refreshStatusChrome() end

function ReaderView:buildFooterStatus(page, geometry)
    self._footer_dirty = false
    local chapter_index = tonumber(page.chapter_index or 1) or 1
    local chapter_percentage = 0
    -- Paginator already loaded the current chapter to create this page. Keep
    -- that reference on the page so an ordinary (non-animated) page turn does
    -- not perform another cache/disk lookup just to draw the footer.
    local model = page.chapter_model or BookService:loadChapterModel(self.book, chapter_index)
    if model then
        local position = page.next_position or page.start_position
        chapter_percentage = ReaderFooter:percentage(model, position, chapter_index, page.at_end)
    elseif page.at_end then
        chapter_percentage = 1
    end

    -- 页脚：左时间 / 中留空 / 右「本章页/总页 全书%」。
    -- Sean 定版（2026-11-01）：不带「本章」「全书」这些中文字，只留数字 ——
    --   `09:20   12/37 32.15%`
    -- 2026-11-02 调整：页眉左上仍是章节名，左下的书名换成时间
    -- （时间从页眉右侧挪下来），右侧数字列不变。
    local chapter_count = #(self.book.chapters or {})
    local book_progress = chapter_count > 0
        and clamp01(((chapter_index - 1) + chapter_percentage) / chapter_count) or 0
    -- 状态栏细分开关：时间 / 页码各自独立，关掉的那一项留空但仍占位，
    -- 这样页脚高度不变、Paginator 分页不受影响（和状态栏开关语义一致）。
    local left_text = self.style.show_time == false and "" or self:_clockText()
    -- 全书进度精确到小数点后两位。
    local book_text = string.format("%.2f%%", book_progress * 100)
    -- 四舍五入会把「最后一章读到 99.996%」显示成 100.00%，看着像读完了。
    if book_progress < 1 and book_progress * 100 >= 99.995 then book_text = "99.99%" end
    -- 页表就绪时是「12/37」，未就绪用等宽的占位符，避免右列文字左右跳动。
    local page_number, page_total = self:_footerChapterPages(page)
    local page_text = page_number and page_total and string.format("%d/%d", page_number, page_total)
        or "--/--"
    -- 「12/37」和「32.15%」之间留两个空格：一个空格太挤，两个才分得开（Sean 要求）。
    local right_text
    if self.style.show_page == false then
        right_text = ""
    else
        right_text = page_text .. "  " .. book_text
    end
    -- The footer no longer renders any cache/prefetch indicator. A progress bar
    -- here meant one footer-only repaint per prefetch tick, and those regional
    -- refreshes could race the chapter-turn full refresh on E Ink.
    -- Keep the status line inside the same horizontal reading margins as the
    -- body. This avoids text touching the panel edges on small Kindle screens.
    local width = math.max(1, geometry.content_width or (geometry.screen_width
        - geometry.left - geometry.right))
    local height = geometry.footer_height
    local chrome_color = self:isNightMode() and Blitbuffer.COLOR_WHITE or nil

    -- ⭐ 右边那串数字长度不固定（「9/12 3.05%」和「456/789 88.88%」差很多），
    -- 所以不按固定比例切左右，而是**先量右格实际宽度，剩下的全给左格**。
    -- 左格现在是时间（固定 5 字符宽），不会因为宽度变化而左右跳动。
    local right_text_widget = TextWidget:new{
        text = right_text,
        face = geometry.chrome_face,
        padding = 0,
        max_width = width,
        fgcolor = chrome_color,
    }
    local gap = Screen:scaleBySize(10)
    local right_width = math.max(1, right_text_widget:getSize().w)
    local left_width = math.max(1, width - right_width - gap)

    local left = LeftContainer:new{
        dimen = Geom:new{ w = left_width, h = height },
        TextWidget:new{
            text = left_text,
            face = geometry.chrome_face,
            padding = 0,
            max_width = left_width,
            fgcolor = chrome_color,
        },
    }
    local right = RightContainer:new{
        dimen = Geom:new{ w = right_width, h = height },
        right_text_widget,
    }

    -- 页脚就两格：时间 + 右侧数字。中间那格（原「第 x / y 章」）已经不需要了，
    -- 空着反而白占宽，直接去掉。
    local footer = HorizontalGroup:new{
        left,
        HorizontalSpan:new{ width = gap },
        right,
    }
    self:_ensureClockTimer()
    return CenterContainer:new{
        dimen = Geom:new{ w = geometry.screen_width, h = height },
        footer,
    }
end

function ReaderView:_footerRegion()
    if not self.page or not self.page.geometry then return nil end
    local geometry = self.page.geometry
    return Geom:new{
        x = 0,
        y = geometry.screen_height - geometry.footer_height,
        w = geometry.screen_width,
        h = geometry.footer_height,
    }
end

-- 页眉条（含顶部偏移）：页眉里的时间每分钟重绘这里，不碰正文。
function ReaderView:_headerRegion()
    if not self.page or not self.page.geometry then return nil end
    local geometry = self.page.geometry
    local height = (geometry.header_offset or 0) + (geometry.header_height or 0)
    if height <= 0 then return nil end
    return Geom:new{ x = 0, y = 0, w = geometry.screen_width, h = height }
end

-- The footer no longer shows anything about the background prefetch, so a
-- progress tick must not trigger a repaint. Each tick used to rebuild the whole
-- reading page and then flush only the footer strip; on E Ink those regional
-- refreshes could race the chapter-turn refresh and leave a half-painted page.
function ReaderView:onPrefetchProgress(state)
    self.prefetch_state = state
end

-- ⭐ 页眉状态图标：直接复用 KOReader 自带 `nerdfonts/symbols.ttf` 里的私有码位
-- （和原生阅读器 footer 的「icons」模式同一套字形），不用额外打包图片资源，
-- 夜间模式跟着文字颜色反色。
local WIFI_SYMBOL_ON = "\xEE\xB2\xA8"   -- U+ECA8 Wi-Fi 已连接
local WIFI_SYMBOL_OFF = "\xEE\xB2\xA9"  -- U+ECA9 Wi-Fi 未连接/已关闭

function ReaderView:_clockText()
    local ok, text = pcall(os.date, "%H:%M")
    if ok and text then return text end
    return ""
end

-- Wi-Fi 状态：拿不到就返回 nil（不显示图标），不要瞎猜成「已断开」。
function ReaderView:_wifiSymbol()
    if type(Device.hasWifiToggle) ~= "function" or not Device:hasWifiToggle() then return nil end
    if type(Device.hasFastWifiStatusQuery) ~= "function" or not Device:hasFastWifiStatusQuery() then
        return nil
    end
    if type(Device.isAndroid) == "function" and Device:isAndroid() then return nil end
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or type(NetworkMgr) ~= "table" or type(NetworkMgr.isWifiOn) ~= "function" then
        return nil
    end
    local ok_state, is_on = pcall(NetworkMgr.isWifiOn, NetworkMgr)
    if not ok_state or type(is_on) ~= "boolean" then return nil end
    return is_on and WIFI_SYMBOL_ON or WIFI_SYMBOL_OFF
end

-- 电池图标：交给 powerd:getBatterySymbol()，它按电量 10% 一档给出字形，
-- 充电/充满也有各自字形 —— 不用我们自己维护映射表。
-- 顺带把电量百分比一起返回，页眉要在图标右边跟一个「85%」。
function ReaderView:_batterySymbol()
    if type(Device.hasBattery) == "function" and not Device:hasBattery() then return nil end
    local ok, powerd = pcall(function() return Device:getPowerDevice() end)
    if not ok or not powerd or type(powerd.getBatterySymbol) ~= "function" then return nil end
    local ok_cap, capacity = pcall(powerd.getCapacity, powerd)
    if not ok_cap or type(capacity) ~= "number" then return nil end
    local ok_charged, charged = pcall(powerd.isCharged, powerd)
    local ok_charging, charging = pcall(powerd.isCharging, powerd)
    local ok_symbol, symbol = pcall(powerd.getBatterySymbol, powerd,
        (ok_charged and charged) or false, (ok_charging and charging) or false, capacity)
    if ok_symbol and type(symbol) == "string" and symbol ~= "" then
        return symbol, math.max(0, math.min(100, math.floor(capacity + 0.5)))
    end
    return nil
end

-- 页眉右侧：Wi-Fi 图标 + 电池图标 + 电量百分比。
-- 时间已经挪到页脚左下角（Sean 2026-11-02 调整），页眉只留状态图标。
function ReaderView:_headerStatusText()
    local parts = {}
    -- 状态栏细分开关：Wi-Fi / 电量各自独立，关掉就不取图标也不显示。
    if self.style.show_wifi ~= false then
        local wifi = self:_wifiSymbol()
        if wifi then parts[#parts + 1] = wifi end
    end
    if self.style.show_battery ~= false then
        local battery, battery_percent = self:_batterySymbol()
        -- 百分比紧贴图标（「🔋85%」），不额外加空格：页眉左边还要留位置给章节名。
        if battery then
            if battery_percent then
                battery = battery .. string.format("%d%%", battery_percent)
            end
            parts[#parts + 1] = battery
        end
    end
    return table.concat(parts, " ")
end

-- ⭐ 夜间模式与 KOReader 全局一致：走 KOReader 全局 Screen.night_mode，
-- 由 framebuffer 级反转（硬件灰度反转 / bb:invert）把整屏日间配色翻成夜间。
-- leko 自己**不再另画黑底白字**，否则会被 framebuffer 再反一次=没效果。
-- 保留这个函数只为兼容既有调用点，恒返回 false（即页面始终按日间色绘制）。
function ReaderView:isNightMode()
    return false
end

-- 前向声明：段评气泡坐标探针的类定义在文件后半段（见下方 `_ParaMarkerAnchor`
-- 的注释），但 buildReadingPage 会用到它。若不在此提前声明，第 599 行的
-- `_ParaMarkerAnchor:new{}` 会绑定到全局 `_ParaMarkerAnchor`（nil），
-- 一旦页面上有段评气泡、翻页重建页面时就报
-- `attempt to index global '_ParaMarkerAnchor' (a nil value)` 并崩溃。
local _ParaMarkerAnchor

function ReaderView:buildReadingPage(page)
    local geometry = page.geometry
    local group = VerticalGroup:new{ align = "left" }
    -- 段评气泡需要它自己的屏幕矩形来做点击命中。正文由 VerticalGroup
    -- 自上而下顺序堆叠（align = "left"，外层 FrameContainer 的 padding /
    -- bordersize 都是 0），所以这里按插入顺序累加高度，就得到每个元素顶边的
    -- y 坐标 —— 和 KOReader 的布局结果逐像素一致。
    local marker_rects = {}
    local cursor_y = 0
    local function vspace_height(height)
        return math.max(0, math.floor(height or 0))
    end

    -- The header stays pinned to the physical top edge under a small offset.
    -- The 上边距 (margin_top / geometry.body_top) is applied to the body
    -- below the header, so changing it never pushes the header down.
    if page.show_header then
        -- Small gap so the header does not touch the physical top edge.
        table.insert(group, UI.vspace(geometry.header_offset or 0))
        cursor_y = cursor_y + vspace_height(geometry.header_offset or 0)
        -- Header: chapter title left-aligned, Wi-Fi + battery (no clock) on the right.
        local chrome_color = self:isNightMode() and Blitbuffer.COLOR_WHITE or nil
        local status = self:_headerStatusText()
        local status_widget = TextWidget:new{
            text = status, face = geometry.chrome_face, padding = 0,
            fgcolor = chrome_color,
        }
        local status_width = status_widget:getSize().w
        local gap = Screen:scaleBySize(10)
        local title_width = math.max(1, geometry.content_width - status_width - gap)
        table.insert(group, HorizontalGroup:new{
            HorizontalSpan:new{ width = geometry.left },
            LeftContainer:new{
                dimen = Geom:new{ w = title_width, h = geometry.header_height },
                TextWidget:new{
                    -- 状态栏细分开关：关掉标题就留空，页眉高度不变。
                    text = self.style.show_title == false and ""
                        or (page.chapter_title or self.book.title),
                    face = geometry.chrome_face, padding = 0,
                    max_width = title_width,
                    fgcolor = chrome_color,
                },
            },
            HorizontalSpan:new{ width = gap },
            RightContainer:new{
                dimen = Geom:new{ w = status_width, h = geometry.header_height },
                status_widget,
            },
        })
        cursor_y = cursor_y + geometry.header_height
        table.insert(group, UI.vspace(geometry.body_top or geometry.top))
        cursor_y = cursor_y + vspace_height(geometry.body_top or geometry.top)
    else
        -- Hidden header: keep the body clear of the physical top edge.
        table.insert(group, UI.vspace(geometry.body_top or geometry.top))
        cursor_y = cursor_y + vspace_height(geometry.body_top or geometry.top)
    end

    for _, element in ipairs(page.elements) do
        if element.type == "title" then
            table.insert(group, UI.vspace(element.top_gap))
            cursor_y = cursor_y + vspace_height(element.top_gap)
            table.insert(group, HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = geometry.left },
                LeftContainer:new{
                    dimen = Geom:new{ w = geometry.content_width, h = element.height },
                    TextBoxWidget:new{
                        text = element.text,
                        face = element.face,
                        bold = element.bold,
                        width = geometry.content_width,
                        height = element.height,
                        line_height = element.line_height or 0.18,
                        lang = "zh-CN",
                        alignment = "left",
                        alignment_strict = true,
                        fgcolor = self:isNightMode() and Blitbuffer.COLOR_WHITE or nil,
                        -- TextBoxWidget paints its own buffer filled with
                        -- bgcolor (default white); night mode must match the
                        -- dark page background or the title becomes a block.
                        bgcolor = self:isNightMode() and Blitbuffer.COLOR_BLACK or nil,
                    },
                },
            })
            cursor_y = cursor_y + element.height
            table.insert(group, UI.vspace(element.bottom_gap))
            cursor_y = cursor_y + vspace_height(element.bottom_gap)
        elseif element.type == "gap" then
            table.insert(group, UI.vspace(element.height))
            cursor_y = cursor_y + vspace_height(element.height)
        elseif element.type == "line" then
            -- v0.15.48's single-line drawing path: paint the fitted text once.
            local text_align = tostring(self.style.text_align or "left")
            local body_widget = TextWidget:new{
                text = element.text,
                face = geometry.body_face,
                padding = 0,
                line_height = self.style.line_spacing or 0.28,
                lang = "zh-CN",
                bold = geometry.body_bold or false,
                fgcolor = self:isNightMode() and Blitbuffer.COLOR_WHITE or nil,
                alignment = "left",
                alignment_strict = true,
            }
            local line_container
            if text_align == "center" then
                line_container = CenterContainer:new{
                    dimen = Geom:new{ w = geometry.content_width, h = element.height },
                    body_widget,
                }
            elseif text_align == "right" then
                line_container = RightContainer:new{
                    dimen = Geom:new{ w = geometry.content_width, h = element.height },
                    body_widget,
                }
            else
                line_container = LeftContainer:new{
                    dimen = Geom:new{ w = geometry.content_width, h = element.height },
                    body_widget,
                }
            end
            local row_widget = line_container
            if element.para_marker then
                -- 段评气泡：紧跟在段末行文字之后。分页器已经为它让出宽度
                -- （见 Paginator.fitBodyLines 的 tail_reserve），所以这里读文字
                -- 实测宽度就能得到精确的落点。用固定尺寸的容器包一层，
                -- 保证 OverlapGroup / HorizontalGroup 算出来的行高仍然是
                -- element.height —— 整个页面的纵向累加不能被打乱。
                local text_size = body_widget:getSize()
                local text_width = math.max(0, math.ceil((text_size and text_size.w) or 0))
                local inline_offset = 0
                if text_align == "center" then
                    inline_offset = math.max(0, math.floor((geometry.content_width - text_width) / 2))
                elseif text_align == "right" then
                    inline_offset = math.max(0, geometry.content_width - text_width)
                end
                local marker_gap = geometry.para_marker_gap or 0
                local marker_widget = TextWidget:new{
                    text = element.para_marker,
                    -- 与分页器预留宽度时用的**同一个** face、同一个 bold 与同一个 gap
                    -- （都在 geometry 里，由 Paginator 一处算出来）。任何一项对不上，
                    -- 气泡宽度就与预留宽度不一致，命中区随之偏移。
                    face = geometry.para_marker_face or geometry.body_face,
                    padding = 0,
                    -- 气泡只有一行，不需要额外的行距裕量；给了反而会把
                    -- CenterContainer 撑高、在正文行里显得偏。
                    line_height = 0,
                    lang = "zh-CN",
                    bold = geometry.para_marker_bold == true,
                    fgcolor = self:isNightMode() and Blitbuffer.COLOR_WHITE or nil,
                }
                local marker_size = marker_widget:getSize()
                local marker_width = math.max(1, math.ceil((marker_size and marker_size.w) or 1))
                local marker_holder = CenterContainer:new{
                    dimen = Geom:new{ w = marker_width, h = element.height },
                    marker_widget,
                }
                -- OverlapGroup 的坐标原点是 HorizontalGroup 里
                -- HorizontalSpan{width = geometry.left} 之后的位置，
                -- 所以这里只需要行内偏移 + 文本宽度 + 一道缝。
                local marker_x = inline_offset + text_width + marker_gap
                marker_holder.overlap_offset = { marker_x, 0 }
                row_widget = OverlapGroup:new{
                    dimen = Geom:new{ w = geometry.content_width, h = element.height },
                    allow_mirroring = false,
                    line_container,
                    marker_holder,
                }
                local marker_rect = {
                    x = geometry.left + marker_x,
                    y = cursor_y,
                    w = marker_width,
                    h = element.height,
                    paragraph = element.paragraph,
                    -- 真实落点由 anchor 在 paintTo 时回填；拿不到就退回上面的复算值。
                    painted_x = nil,
                    painted_y = nil,
                }
                marker_widget = _ParaMarkerAnchor:new{
                    dimen = Geom:new{ w = marker_width, h = element.height },
                    marker_widget,
                    rect = marker_rect,
                }
                marker_holder[1] = marker_widget
                marker_rects[#marker_rects + 1] = marker_rect
            end
            table.insert(group, HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = geometry.left },
                row_widget,
            })
            cursor_y = cursor_y + element.height
        end
    end

    local remaining = geometry.content_height - page.used_height
    if remaining > 0 then table.insert(group, UI.vspace(remaining)) end

    -- Keep the reading margin above the status line, matching the original
    -- 0.15.39 reading geometry; the footer remains flush with the bottom edge.
    if self.style.show_footer then
        table.insert(group, UI.vspace(geometry.bottom))
        table.insert(group, self:buildFooterStatus(page, geometry))
    elseif geometry.footer_height > 0 then
        table.insert(group, UI.vspace(geometry.footer_height))
    end

    -- 这一版页面的段评气泡命中区。routeTap 只认当前这一份。
    self._para_hit_rects = marker_rects

    return FrameContainer:new{
        width = geometry.screen_width,
        height = geometry.screen_height,
        bordersize = 0,
        padding = 0,
        background = self:isNightMode() and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        group,
    }
end

function ReaderView:buildMenuOverlay()
    local width, height = self.dimen.w, self.dimen.h
    local top_h, bottom_h = self:getMenuMetrics()
    -- 简洁风格：菜单项无方框、项间竖细线，上/下各一条 2px 中灰横线与正文分隔。
    -- topBar/bottomBar 内部已给线留 1px，整体高度保持 top_h/bottom_h 不变。
    local top = UI.topBar(width, top_h, {
        left_text = "‹ 书架",
        title = self.book.title or "阅读",
        right_text = "书籍详情",
        on_left = function() self:requestExit() end,
        on_right = function() self:showBookInfo() end,
        title_size = 21,
    })
    top.overlap_offset = { 0, 0 }

    local bottom = FrameContainer:new{
        width = width,
        height = bottom_h,
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        overlap_offset = { 0, height - bottom_h },
        UI.bottomBar(width, bottom_h, {
            -- 四项与顶部「书架 / 书籍详情」按钮完全同款：20pt 常规体、不加粗，
            -- 避免「目录」粗体、其余常规造成的字号/字重不一致（Sean 2026-11-28）。
            { text = "目录", font_size = 20, callback = function() self:showToc() end },
            { text = "排版设置", font_size = 20, callback = function() self:showLayoutMenu() end },
            { text = "设备控制", font_size = 20, callback = function() self:showDeviceMenu() end },
            { text = "刷新本章", font_size = 20, callback = function() self:reloadCurrentChapter() end },
        }),
    }
    return top, bottom
end

--[[--
一次整页重绘该请求哪种波形 / 区域。

开着「避免界面闪烁」时，UIManager 会把**带 region 的** "partial" 降级成 "ui"
（uimanager.lua 的 _refresh：`mode == "partial" and region` → `ui`）。"ui" 是两级
DU 波形，只适合小面积 UI 更新；拿它去刷整页重新折行后的正文，旧字盖不干净 ——
读者看到的就是「新字叠着旧字、行首缺字」，而手动全刷一下又好了。
KOReader 自己的阅读器对整页重绘用的是 `setDirty(view, "partial")` 且**不带 region**，
UIManager 会把没有 region 的刷新自己补成全屏，波形仍停在正规的 partial。

约定：调用方**明确指定** region 的（页脚条等局部刷新）照旧原样传下去；没指定时，
只有 "partial" 省略 region，其余模式仍显式传整屏 dimen（保持既有行为）。
]]--
local function pageRefresh(mode, region, dimen)
    mode = mode or "ui"
    if not region and mode ~= "partial" then region = dimen end
    return mode, region
end

function ReaderView:rebuild(refresh_type, refresh_region)
    -- The callback is not guaranteed to run after a dialog closes or a
    -- reflow reconstructs the ReaderView. Read the service-owned state at
    -- every visual rebuild so the native 0.15.47 footer cannot retain a stale
    -- cache bar when no new notification arrives.
    -- The cache window is established by setPage before the target page is
    -- built. Here we only recover the service-owned state for a redraw.
    self:_syncPrefetchState()
    local page_widget = self:buildReadingPage(self.page)
    if self.menu_visible then
        local top, bottom = self:buildMenuOverlay()
        self[1] = OverlapGroup:new{
            dimen = self.dimen:copy(),
            allow_mirroring = false,
            page_widget,
            top,
            bottom,
        }
    else
        self[1] = page_widget
    end
    local mode, region = pageRefresh(refresh_type, refresh_region, self.dimen)
    UIManager:setDirty(self, mode, region)
    return true
end

-- 屏幕方向：KOReader 原生 rotation 菜单走 UIManager:broadcastEvent，
-- 设备控制页的竖屏/逆时针/顺时针三个按钮也发同一个 SetRotationMode 事件。
-- leko 的 ReaderView 尺寸与分页签名都绑在 Screen 宽高上，转屏后必须就地
-- 更新 dimen 并整页重排，否则正文会按旧尺寸排版、只画半屏。
function ReaderView:onSetRotationMode(mode)
    if self._closing then return false end
    local old_mode = Screen:getRotationMode()
    if mode == nil or mode == old_mode then return false end
    Screen:setRotationMode(mode)
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    -- ⭐ 关键：rebuild 只会用旧的 self.page 重画，页面是按转屏前的宽度折行的。
    -- 横竖切换后必须按当前锚点重新 makePage，正文才会重新折行铺满新屏幕；
    -- 否则只画左侧一部分，右侧露出被旋转 90° 的弹窗残影 —— 翻页时才重排，
    -- 这正是「切换方向后卡屏，翻页才消失」的根因。
    if self.page and self.book then
        local anchor = self.page.start_position
        local page, err = Paginator:makePage(self.book, anchor, self.style)
        if page then
            self.page = page
            self._progress_dirty = true
            self._footer_dirty = true
            self:_syncPrefetchState()
        else
            logger.warn("Leko rotation reflow failed", tostring(err))
        end
    end
    -- full 整屏刷：清掉弹窗旋转后留在 framebuffer 上的旧像素。
    UIManager:setDirty(nil, "full")
    self:rebuild("full")
    return true
end

-- 翻页动画统一交给 KOReader 原生 swipe animation：这里只读写它的全局开关
-- （与 KOReader 原生一致），不再自带刷新后端、档位或动画调度器。
-- 原生动画是一次性标志，由 UIManager:_repaint 消费；下列收尾函数保留原名，
-- 是因为翻页、弹窗、关阅读器等诸多路径都在调用，现在只负责清掉可能残留的
-- 标志，避免把它带给紧接着的菜单/弹窗刷新。
function ReaderView:_settleSwipeRefresh()
    if Device:canDoSwipeAnimation() then Screen:setSwipeAnimations(false) end
    return false
end

function ReaderView:_cancelSwipeRefresh()
    if Device:canDoSwipeAnimation() then Screen:setSwipeAnimations(false) end
    return true
end

function ReaderView:isSwipeAnimationEnabled()
    return G_reader_settings ~= nil and G_reader_settings:isTrue("swipe_animations")
end

function ReaderView:setSwipeAnimationEnabled(enabled)
    enabled = enabled == true
    if G_reader_settings then
        G_reader_settings:saveSetting("swipe_animations", enabled)
        G_reader_settings:flush()
    end
    if not enabled and Device:canDoSwipeAnimation() then
        Screen:setSwipeAnimations(false)
    end
    return enabled
end

-- ── 段评（番茄 / 七猫 / QQ阅读章节的段落评论） ───────────────────────────
-- 数据全在 Leko/ParaComments：这里只负责「什么时候取、取到之后怎么落到页面上」。
-- 计数挂在 chapter model 的 para_counts 上，分页器读它来给段末行挂气泡，
-- 分页过程本身永远是纯本地的。气泡的点击命中走 routeTap 的矩形判定 ——
-- 段评气泡不参与左右翻页分区，命中就直接看评论。

function ReaderView:isParaReviewEnabled()
    return self.para_review_enabled == true
end

function ReaderView:setParaReviewEnabled(enabled)
    enabled = enabled == true
    self.para_review_enabled = enabled
    self.style.para_review_enabled = enabled
    Storage:saveReaderStyle(self.style)
    -- 开关只改「要不要给段末行让出气泡宽度」，必须重排才能生效。
    -- 刚打开时如果本章还没有计数，就先不重排 —— 等计数到了 ensureParaCounts
    -- 会重排一次，省掉一次无意义的二次分页。
    local model = self.page and self.page.chapter_model
    local has_counts = self:_paraCountsFresh(model, BookService:sourceFor(self.book))
        and type(model.para_counts) == "table"
    if not enabled or has_counts then self:reflowForParaReview() end
    if enabled then
        self:ensureParaCounts(true)
    else
        -- 关掉段评后不该再有气泡跳出来：把在飞的计数请求与等待提示一起收掉。
        self._para_counts_token = nil
        self:_endParaWait()
        AsyncParaReview:cancel("counts", "disabled")
    end
    return enabled
end

--[[--
段评开关 / 计数变化后的重排。

刻意不复用 applyStyleChange：那条路会 clearBookCache，而 para_counts 正挂在
章节模型上，也会顺手清空 history。这里只按当前位置重新分页一次，
阅读位置与历史都不动。
]]--
-- 「屏幕上看得见的排版」指纹：元素类型 + 正文 + 气泡文字 + 用掉的高度。
-- 整页重排前后各取一次，就能判断这次重排到底有没有动到屏幕上的东西。
local function pageLayoutSignature(page)
    if type(page) ~= "table" or type(page.elements) ~= "table" then return nil end
    local parts = {}
    for i, element in ipairs(page.elements) do
        parts[i] = tostring(element.type) .. "\1" .. tostring(element.text or "")
            .. "\1" .. tostring(element.para_marker or "")
    end
    return table.concat(parts, "\2") .. "\3" .. tostring(page.used_height or 0)
end

function ReaderView:reflowForParaReview()
    if not self.page then return false end
    self:_settleSwipeRefresh()
    local anchor = self.page.start_position
    local previous_signature = pageLayoutSignature(self.page)
    local page, err = Paginator:makePage(self.book, anchor, self.style)
    if not page then
        logger.warn("Leko para review reflow failed", tostring(err))
        return false
    end
    self.page = page
    self._progress_dirty = true
    self._footer_dirty = true
    if pageLayoutSignature(page) == previous_signature then
        -- 这一章没有任何段落要挂气泡（计数为空，或与本代完全相同）：排版一字未动，
        -- 屏幕上已经是最终画面，页脚百分比也由同一批元素决定。这里就该什么都不刷 ——
        -- 无条件 rebuild 一次等于为「什么都没变」在屏幕上盖一层残影。
        return true
    end
    -- 气泡挤进段末行，那一行的可用宽度变窄，后面每一行都重新折行 —— 屏幕上现有的
    -- 每一个字都已经作废。这种规模的变更只能用整屏闪刷：
    -- 局部 / 快速波形盖不住已经落下的旧字，读者看到的就是「新字叠着旧字、行首缺字」。
    -- 页脚由这次 rebuild 一并重画，不需要再补一次局部刷新。
    self:rebuild("full")
    return true
end

--[[--
章节模型上的段评数据是否「就是当前这一代镜像取的」。

失败时模型上会留 `para_counts = false` 作为「本次会话别再试」的标记；
原生源换过镜像之后这个标记必须失效 —— 否则新镜像永远轮不到重试，读者会以为
这本书没有段评。所以判断依据不是「有没有值」，而是「值是哪台镜像取的」。
]]--
function ReaderView:_paraCountsFresh(model, source)
    if not model or model.para_counts == nil then return false end
    return model.para_counts_epoch == ParaComments.hostKey(source)
end

-- 换到（或首次进入）一章之后，等这一页画完再补拉本章计数：网络等待不塞进
-- 翻页路径，成功后只重排当前页。失败会在模型上留一个 false 标记，
-- 本次会话（同一代镜像）不再自动重试，避免每翻一页都打一次后端。
function ReaderView:_scheduleParaCounts(page)
    if self.para_review_enabled ~= true or not page then return end
    local model = page.chapter_model
    if not model or self:_paraCountsFresh(model, BookService:sourceFor(self.book)) then return end
    local chapter_index = page.chapter_index
    if not ParaComments.isSupported(self.book, chapter_index) then return end
    -- 并行预热已经把这章取回来了（那次请求与正文下载同时进行）：直接用，
    -- 不再多开一个子进程。
    local stash = self._para_counts_stash
    if stash and stash[chapter_index] then
        local counts = stash[chapter_index]
        stash[chapter_index] = nil
        self:_applyParaCounts(model, counts, BookService:sourceFor(self.book))
        return
    end
    UI.defer(self, "para_counts_" .. tostring(chapter_index), function()
        if self._closing then return end
        if not (self.page and self.page.chapter_index == chapter_index) then return end
        self:ensureParaCounts(false)
    end)
end

--[[--
与正文下载并行地把本章计数取回来。

进入一章时正文要等一个子进程（实测约 600ms），计数又要再等一个（约 370ms）。
把计数那个子进程提前到「正文刚开始下载」时启动，两者就重叠了 —— 代价只是
ProcessBudget 里一个受内存闸门限制的伴随名额（Kindle 内存吃紧时自动退回串行）。

这里只负责「把结果放到手边」：页面模型可能还没建好，所以先塞进 stash，
由 _scheduleParaCounts 在页面就绪时取用；如果那时模型已在，就直接挂上去。
]]--
function ReaderView:_prefetchParaCounts(chapter_index)
    if self.para_review_enabled ~= true then return end
    chapter_index = tonumber(chapter_index)
    if not chapter_index then return end
    if not ParaComments.isSupported(self.book, chapter_index) then return end
    local source = BookService:sourceFor(self.book)
    if not source then return end
    if AsyncParaReview:isRunning("counts") then return end
    local stash = self._para_counts_stash
    if not stash then
        stash = {}
        self._para_counts_stash = stash
    end
    if stash[chapter_index] ~= nil then return end

    AsyncParaReview:start("counts", {
        book = self.book,
        source = source,
        chapter_index = chapter_index,
        -- 与前台章节任务并行；没有模型可传，七猫也不再需要段落指纹
        -- （v6 计数来自正文气泡）。
        companion = true,
        timeout_seconds = 45,
    }, function(ok, payload, err)
        if self._closing then return end
        if not ok then
            -- 失败不算结论：不写 stash，页面就绪后照常按原路径重试一次。
            if err then logger.warn("Leko para review prefetch failed", tostring(err)) end
            return
        end
        AsyncParaReview.rememberSourceHost(source, payload.host)
        local counts = payload.counts_map or {}
        local page = self.page
        if page and page.chapter_index == chapter_index and page.chapter_model then
            self:_applyParaCounts(page.chapter_model, counts, source)
        else
            stash[chapter_index] = counts
        end
    end)
end

--[[--
段评等待提示：延迟 0.4 秒才出现，出现后点一下就能取消。

最快的路径（本地缓存命中）只要一两百毫秒，一上来就盖遮罩会白闪一下，所以先
等 0.4 秒。它出现之后会挡住输入 —— 这正是想要的效果：既把「现在在等网络」
说清楚，也避免读者连点同一个气泡发两次请求，还能一次点掉取消，不用干等。

token 用来判定「这条提示属于哪一次请求」：换了一次请求 / 关掉阅读器之后，
晚到的定时器和回调都不会再动屏幕。
]]--
function ReaderView:_beginParaWait(text, token, on_cancel)
    self:_endParaWait()
    self._para_busy_token = token
    local function show()
        self._para_busy_timer = nil
        if self._para_busy_token ~= token or self._closing then return end
        local trap = TrapWidget:new{
            text = text,
            dismiss_callback = function()
                if self._para_busy_token ~= token then return end
                -- 先摘掉自己的那份引用：TrapWidget 关掉自己时也会走 dismiss，
                -- 不摘的话 _endParaWait 会去二次关闭同一个窗口。
                self._para_busy_token = nil
                self._para_busy = nil
                if on_cancel then pcall(on_cancel) end
            end,
        }
        self._para_busy = trap
        UIManager:show(trap)
        UIManager:forceRePaint()
    end
    self._para_busy_timer = show
    UIManager:scheduleIn(0.4, show)
end

function ReaderView:_endParaWait()
    if self._para_busy_timer then
        UIManager:unschedule(self._para_busy_timer)
        self._para_busy_timer = nil
    end
    self._para_busy_token = nil
    local trap = self._para_busy
    if trap then
        self._para_busy = nil
        pcall(function() UIManager:close(trap) end)
        UIManager:forceRePaint()
    end
end

--[[--
确保本章的段评计数就绪（章模型上没有就取一次）。

interactive 为真表示用户主动触发（刚打开开关 / 点了「本页段评」），
这时等待和失败都要给读者交代；章节自动切换时静默处理，取不到就当没有段评。

取数在子进程里跑（Leko/AsyncParaReview），所以这个函数立刻返回 —— 翻页路径
不再为了等网络停住 4–5 秒。on_ready(counts) 在计数到位后于 UI 线程回调；
请求失败、被前台任务挤掉、或读者已经翻走这一章时，它不会被调用
（此时模型上是 nil，下一次进这一章会自动重试）。
]]--
function ReaderView:ensureParaCounts(interactive, on_ready)
    if self.para_review_enabled ~= true then return end
    local page = self.page
    local model = page and page.chapter_model
    if not model then return end
    local source = BookService:sourceFor(self.book)
    if self:_paraCountsFresh(model, source) then
        -- 这一代的计数已经在手上了：不必再打后端，直接把现成的给调用方。
        if type(model.para_counts) == "table" and next(model.para_counts) then
            self:preheatParaAuth(source)
        end
        if on_ready then
            local existing = model.para_counts
            on_ready(type(existing) == "table" and existing or nil)
        end
        return
    end
    local chapter_index = page.chapter_index
    if not ParaComments.isSupported(self.book, chapter_index) then
        if interactive then
            UIManager:show(Notification:new{ text = "本章所在书源没有段评（支持番茄 / QQ阅读 / 七猫 / 书旗 / 半夏）" })
        end
        return
    end
    if not source then
        if interactive then
            UIManager:show(Notification:new{ text = "没有找到可用的书源，无法获取段评" })
        end
        return
    end
    if AsyncParaReview:isRunning("counts") then
        -- 已经有一批在飞（预取、或打开开关 + 刚进章节各触发一次）。再发一次
        -- 只会让两批计数抢同一份缓存；但也不能直接 return —— 交互式调用方
        -- （「本页段评」列表）的 on_ready 会永远等不到。这里等它落地再判一次：
        -- 那时 _paraCountsFresh 已成立，直接回现成结果。
        local attempts = (self._para_counts_wait or 0) + 1
        if attempts > 24 then  -- 0.25s × 24 ≈ 6s 还没回：放弃，别无限排
            self._para_counts_wait = nil
            return
        end
        self._para_counts_wait = attempts
        UIManager:scheduleIn(0.25, function()
            if self._closing then return end
            if not (self.page and self.page.chapter_index == chapter_index) then return end
            self._para_counts_wait = nil
            self:ensureParaCounts(interactive, on_ready)
        end)
        return
    end

    local token = {}
    self._para_counts_token = token
    if interactive then
        self:_beginParaWait("正在获取本章段评…（点按取消）", token, function()
            self._para_counts_token = nil
            self:_endParaWait()
            AsyncParaReview:cancel("counts", "user")
        end)
    end

    AsyncParaReview:start("counts", {
        book = self.book,
        source = source,
        chapter_index = chapter_index,
    }, function(ok, payload, err)
        if self._para_counts_token ~= token then return end
        self._para_counts_token = nil
        self:_endParaWait()
        if self._closing then return end

        if not ok then
            -- 失败标记也带镜像：换镜像后这次失败不再作数，新镜像有机会重试。
            model.para_counts, model.para_counts_epoch = false, ParaComments.hostKey(source)
            logger.warn("Leko para review counts unavailable", tostring(err))
            if interactive then
                UIManager:show(Notification:new{ text = "段评获取失败：" .. tostring(err or "未知错误") })
            end
            return
        end

        -- 子进程里选中的镜像记在它自己的副本上，父进程看不到 —— 不同步回来的话
        -- 下一次请求又会先把失效镜像试一遍（白等一个注定失败的往返），
        -- _paraCountsFresh 也会永远判成过期。
        AsyncParaReview.rememberSourceHost(source, payload.host)

        local counts = self:_applyParaCounts(model, payload.counts_map or {}, source)
        if counts and next(counts) then self:preheatParaAuth(source) end
        if on_ready then on_ready(counts) end
    end)
end

--[[--
段评凭证后台预热。

JWT 只在取评论正文时用得上，而它是子进程登录后写进 runtime 文件的 —— 不预热
的话，读者点下第一段气泡的那一刻才开始「PoW + 登录往返」（没有 libcrypto 快
路径的慢设备上可能要等几十秒）。这里在计数到手（说明本章真有段评可看）之后
就悄悄把凭证备好，首点零等待。

触发是廉价的：hasValidJwt 命中（绝大多数情况）只读一次内存 / 小文件就返回；
只有真缺凭证才会 fork 子进程。10 分钟内不重复检查，失败（比如没配账号）也
不会反复打扰。
]]--
function ReaderView:preheatParaAuth(source)
    if self.para_review_enabled ~= true then return end
    if type(source) ~= "table" then return end
    local now = os.time()
    if self._para_auth_checked_at and now - self._para_auth_checked_at < 600 then return end
    self._para_auth_checked_at = now
    if ShushanAuth:hasValidJwt(source) then return end
    if AsyncParaReview:isRunning("auth") then return end
    AsyncParaReview:start("auth", {
        book = self.book,
        source = source,
        -- PoW 没有 ffi 快路径时（libcrypto 缺失回退纯 Lua）可能要跑几十秒，
        -- 兜底放宽到 150s；有快路径时几秒内就回来。
        timeout_seconds = 150,
    }, function(ok, payload, err)
        if self._closing then return end
        if ok then
            AsyncParaReview.rememberSourceHost(source, payload and payload.host)
            logger.info("Leko para review: auth preheated")
        else
            -- 静默失败：多半是没配书山账号，等读者真点气泡时再给他明确提示。
            logger.warn("Leko para review: auth preheat failed", tostring(err))
        end
    end)
end

--[[--
把一批计数挂到章节模型上（含越界裁剪与必要的重排）。

段落号越界说明服务端的分段与本地不一致：越界项直接丢弃，免得把评论挂到
不存在的段上（分页器只按 pid 查表，不越界取值）。

记账用的是「同步之后」的镜像：下次 _paraCountsFresh 按同一个表达式算，
这样才天然对得上（凭据缺失时它会回落到 "auto"）。章节可能在等待期间被翻走：
只有它还是当前页时才重排。
]]--
function ReaderView:_applyParaCounts(model, counts, source)
    if not model then return counts end
    local paragraph_count = #(model.paragraphs or {})
    local dropped = 0
    for pid in pairs(counts) do
        if pid >= paragraph_count then
            counts[pid] = nil
            dropped = dropped + 1
        end
    end
    if dropped > 0 then
        logger.warn("Leko para review: dropped out-of-range pids", tostring(dropped),
            "of", tostring(paragraph_count), "paragraphs")
    end
    model.para_counts, model.para_counts_epoch = counts, ParaComments.hostKey(source)
    if self.page and self.page.chapter_model == model then
        self:reflowForParaReview()
    end
    return counts
end

-- 段评气泡的坐标探针：命中区按文字宽度复算会偏出几百像素，改为让气泡在
-- paintTo 时上报真实屏幕落点。这层只透传绘制，不改变任何绘制结果。
_ParaMarkerAnchor = WidgetContainer:extend{}

function _ParaMarkerAnchor:getSize()
    return self[1]:getSize()
end

function _ParaMarkerAnchor:paintTo(bb, x, y)
    if self.rect then
        self.rect.painted_x = x
        self.rect.painted_y = y
    end
    self[1]:paintTo(bb, x, y)
end

-- 段末气泡的命中判定。返回 1 基段落号，未命中返回 nil。
function ReaderView:_paraMarkerAt(x, y)
    if self.para_review_enabled ~= true then return nil end
    local rects = self._para_hit_rects
    if type(rects) ~= "table" then return nil end
    -- 气泡只有一行高、几十像素宽，手指落点比它大，两向都留小余量。
    -- 2026-11-23 Sean 要求收紧命中：真正的「点不开」根因是 ffi 守卫失效导致
    -- PoW 超时（已修），不是命中区错位，所以不再需要「整行全宽兜底」——
    -- 那种兜底会让点正文误开弹窗。现在横向也限制在气泡附近。
    local slack_x = math.max(Screen:scaleBySize(12), 0)
    local slack_y = math.max(Screen:scaleBySize(16), 0)
    for index = 1, #rects do
        local rect = rects[index]
        -- 有真实绘制坐标就用它，首帧还没绘制过时退回复算值。
        local rx = rect.painted_x or rect.x
        local ry = rect.painted_y or rect.y
        if x >= rx - slack_x and x <= rx + rect.w + slack_x
                and y >= ry - slack_y and y <= ry + rect.h + slack_y then
            return rect.paragraph
        end
    end
    -- 兜底：painted 坐标可能与落点有轻微错位，纵向放宽到气泡所在行 ± 半行，
    -- 横向仍要求在气泡附近（气泡宽 + 两倍余量），不再全宽误触翻页。
    if #rects > 0 then
        local near, near_dy
        for index = 1, #rects do
            local rect = rects[index]
            local cy = (rect.painted_y or rect.y) + rect.h / 2
            local dy = math.abs(cy - y)
            if near_dy == nil or dy < near_dy then near, near_dy = rect, dy end
        end
        local near_x = near.painted_x or near.x
        local near_cx = near_x + near.w / 2
        if near_dy <= near.h / 2 + slack_y
                and math.abs(x - near_cx) <= near.w / 2 + slack_x * 2 then
            return near.paragraph
        end
        -- 未命中降为 debug：每次点错都 warn 会刷日志（Sean 要求严格后尾随 miss 变多）。
        logger.dbg("Leko para review: bubble tap missed", tostring(x), tostring(y),
            "rects=" .. tostring(#rects),
            string.format("near=%d,%d,%dx%d", near_x, near.painted_y or near.y, near.w, near.h),
            string.format("dx=%d dy=%d", math.floor(x - near_cx), math.floor(near_dy)),
            "real=" .. (near.painted_x and "y" or "n"))
    end
    return nil
end

--[[--
段评弹窗：微信读书「想法」式富排版。

评论正文由 ParaComments 取（番茄 / QQ 两家的协议），排版渲染交给
`Leko/review_popup` 那套管线 —— 顶部是这一段的引文，之后每条评论是
「▸ 昵称 · ♥赞」一行加正文，长内容在底部弹窗里上下滚动。点左右半屏翻页、
点弹窗外面或按返回键关闭。

服务端一次只稳定给 20 条评论，所以首次打开连拉两页（见
ParaComments.FIRST_OPEN_PAGES）；还有余量时弹窗底部会挂一个「继续加载」，
按服务端回的 cursor 续拉后面的。

paragraph_index 是 1 基段落号（与 model.paragraphs 一致），服务端用 0 基，
所以这里 pid = paragraph_index - 1。

options.cursor     续拉起点（续拉时由弹窗的按钮回调传入）
]]--
function ReaderView:showParaComments(paragraph_index, options)
    options = options or {}
    local page = self.page
    if not page or not paragraph_index then return end
    local chapter_index = page.chapter_index
    local model = page.chapter_model
    local pid = paragraph_index - 1
    if pid < 0 then return end

    local known_count = nil
    if model and type(model.para_counts) == "table" then
        known_count = tonumber(model.para_counts[pid])
    end
    local cursor = tonumber(options.cursor)
    local source = BookService:sourceFor(self.book)
    if not source then
        -- 续拉失败也不能把「继续加载」按钮锁死：复位之后再让读者重试。
        if cursor then
            pcall(function() require("Leko/ReviewPopup").releaseMorePending() end)
        end
        UIManager:show(Notification:new{ text = "没有找到可用的书源，无法读取段评" })
        return
    end

    -- 富排版弹窗要用到 freetype / xtext：懒加载。失败了只影响这一个功能，
    -- 不该把整个阅读视图拖下水。
    local ok_popup, ReviewPopup = pcall(require, "Leko/ReviewPopup")
    if not ok_popup or type(ReviewPopup) ~= "table" then
        logger.warn("Leko para review: popup unavailable", tostring(ReviewPopup))
        UIManager:show(Notification:new{ text = "段评弹窗组件加载失败" })
        return
    end

    local function releaseMore()
        if cursor and type(ReviewPopup.releaseMorePending) == "function" then
            pcall(ReviewPopup.releaseMorePending)
        end
    end

    local token = {}
    self._para_request_token = token
    self:_beginParaWait("正在获取段评…（点按取消）", token, function()
        self._para_request_token = nil
        self:_endParaWait()
        AsyncParaReview:cancel("comments", "user")
        releaseMore()
    end)

    AsyncParaReview:start("comments", {
        book = self.book,
        source = source,
        chapter_index = chapter_index,
        pid = pid,
        cursor = cursor,
        -- 七猫按段落内容指纹定位这一段，子进程要用同一份段落文本才算得出同样的
        -- 指纹（fork 复制内存，不带序列化开销）；番茄 / QQ 用不上。
        paragraphs = model and model.paragraphs,
    }, function(ok, payload, err)
        if self._para_request_token ~= token then return end
        self._para_request_token = nil
        self:_endParaWait()
        if self._closing then return end
        if not ok then
            releaseMore()
            UIManager:show(Notification:new{ text = "段评获取失败：" .. tostring(err or "未知错误") })
            return
        end
        -- 续拉是「给屏幕上这个弹窗补货」：弹窗已经不在了（读者切页 / 关掉了）
        -- 就别把它重新弹出来，否则等于在别处凭空跳出一个窗口。
        if cursor and not ReviewPopup.isShowing() then return end
        -- 子进程选中的镜像要同步回父进程，否则下一次请求又会先试失效的那台。
        AsyncParaReview.rememberSourceHost(source, payload.host)
        -- 段评配图目录：<cache>/review_pics/<book_id>/。按书分目录，移出书架时
        -- 可整目录清理（见 ReviewPics）。目录准备失败时 pic_dir 为 nil，弹窗
        -- 自动退回纯文字模式，不影响段评正文阅读。
        local pic_dir
        local ok_rp, ReviewPics = pcall(require, "Leko/ReviewPics")
        if ok_rp and self.book and self.book.id then
            local ok_dir, dir = pcall(ReviewPics.ensure, tostring(self.book.id))
            if ok_dir then pic_dir = dir end
        end
        self:_presentParaComments(paragraph_index, payload, {
            ReviewPopup = ReviewPopup,
            model = model,
            chapter_index = chapter_index,
            known_count = known_count,
            pic_dir = pic_dir,
            source = source,
            continuation = cursor ~= nil,
        })
    end)
    return true
end

--[[--
把一批评论渲染成弹窗。

纯 UI，不发请求 —— 数据来自 AsyncParaReview 的回调，ctx 里带的是发起请求
那一刻的上下文（弹窗模块、章模型、已知条数）。
]]--
function ReaderView:_presentParaComments(paragraph_index, payload, ctx)
    local list, remote_text, page_info = payload.list, payload.para_text or "", payload.page
    local page = self.page
    if page and page.chapter_index ~= ctx.chapter_index then return end
    local model = (page and page.chapter_model) or ctx.model
    if type(list) ~= "table" then return end

    local local_text = model and model.paragraphs and model.paragraphs[paragraph_index] or ""
    -- 引文：**优先本地正文**。读者点的是屏幕上这一段，本地段落就是他眼里的
    -- 原文，永远不会与服务端分段版本对不上；服务端回传的原文只在本地缺失
    -- （章节模型还没就绪）时兜底。曾经反过来「服务端优先」，结果后端把 quote
    -- 包成对象、被 tostring 成 `table: 0x…`，弹窗顶部那行引文就没了。
    local quote = Util.trim(tostring(local_text))
    if quote == "" then quote = Util.trim(tostring(remote_text)) end
    if quote:match("^table: %-?0?x?%x*$") then quote = "" end
    if quote == "" then
        logger.warn("Leko para review: empty quote for pid", tostring(paragraph_index - 1),
            "remote_len", tostring(#tostring(remote_text)))
    end

    local items = {}
    for _, item in ipairs(list) do
        local text = Util.trim(tostring(item.text or ""))
        local pics = type(item.pics) == "table" and item.pics or {}
        -- 纯图评论（无文字但有图）也要收进来，否则段评配图整条丢失。
        if text ~= "" or #pics > 0 then
            items[#items + 1] = {
                abstract = quote,
                author = tostring(item.name or "匿名"),
                content = text,
                likes_count = tonumber(item.likes) or 0,
                comment_id = item.id,
                pics = pics,
                reply_count = tonumber(item.reply_count) or #(item.replies or {}),
                replies = type(item.replies) == "table" and item.replies or {},
                replies_has_more = item.replies_has_more == true,
                -- 书山 v6 的回复已内联在条目里：展开时零请求，直接本地返回。
                replies_inline = true,
            }
        end
    end
    if #items == 0 then
        if ctx.continuation and ctx.ReviewPopup
            and type(ctx.ReviewPopup.releaseMorePending) == "function" then
            pcall(ctx.ReviewPopup.releaseMorePending)
        end
        local known = ctx.known_count
        UIManager:show(Notification:new{ text = (known and known > 0)
            and ("这一段共有 " .. tostring(known) .. " 条评论，目前拿不到可显示的正文。")
            or "这一段还没有评论。" })
        return
    end

    -- 弹窗排版跟随正文的字体 / 字号 / 边距；body_face.size 已是屏幕缩放后的
    -- 像素字号，正好是弹窗字体工厂要的量纲。
    local geometry = (page and page.geometry) or Paginator:getGeometry(self.style)
    local body_face = geometry and geometry.body_face
    local more_text, on_more
    if page_info and page_info.has_more == true then
        local loaded = #list
        local known = ctx.known_count
        local remaining = (known and known > loaded) and (known - loaded) or nil
        more_text = remaining and ("继续加载（还剩 " .. tostring(remaining) .. " 条）")
            or "继续加载更多评论"
        local next_cursor = page_info.next_cursor
        on_more = function()
            self:showParaComments(paragraph_index, { cursor = next_cursor })
        end
    end

    -- 配图下载回调：widget 串行调度，这里只负责「下一张」。
    -- done(ok) 必到达一次（AsyncImageFetch 保证），widget 据此刷新页面位图。
    local fetch_pic = nil
    if ctx.pic_dir then
        fetch_pic = function(url, path, done)
            local function finish(ok) if done then pcall(done, ok == true) end end
            AsyncImageFetch:fetch(url, path, function(ok, _payload, err)
                if not ok then
                    logger.warn("Leko para review: image fetch failed", tostring(err))
                end
                finish(ok)
            end)
        end
    end

    -- 二级回复回调：书山 v6 回复已内联，展开时直接本地返回，零网络请求。
    -- 必须走 nextTick —— 这个回调在 widget 的触摸事件栈里执行，同步重建弹窗
    -- 会和 UIManager 的事件分发互相踩。
    local on_replies = function(item, cursor, done)
        local result = {
            replies = item.replies_inline and item.replies or {},
            total = tonumber(item.reply_count) or #(item.replies or {}),
            has_more = item.replies_has_more == true,
            cursor = nil,
        }
        local function emit()
            if done then pcall(done, true, result) end
        end
        if type(UIManager.nextTick) == "function" then UIManager:nextTick(emit)
        else UIManager:scheduleIn(0, emit) end
    end

    -- 左右滑切段评（1:1 fanqie main.lua:879 navigate_para）：在本章「有段评的
    -- 段落列表」里切上/下一段。leko 的等价数据是 model.para_counts（key = 0 基
    -- pid，value = 该段评论数），按段号升序排好，找到当前段的位置即可导航。
    -- 切段时先关旧弹窗、延迟一帧再开新的（和原版一样，等旧窗从 UIManager 出栈）。
    local para_nav = nil
    if model and type(model.para_counts) == "table" then
        local with_reviews = {}
        for pid, count in pairs(model.para_counts) do
            if (tonumber(count) or 0) > 0 then
                with_reviews[#with_reviews + 1] = tonumber(pid) + 1 -- para_counts 用 0 基 pid
            end
        end
        table.sort(with_reviews)
        local current = 0
        for i, p in ipairs(with_reviews) do
            if p == paragraph_index then current = i break end
        end
        if current > 0 then
            para_nav = function(dir)
                local target = current + (dir == "next" and 1 or -1)
                if target < 1 or target > #with_reviews then return end
                local target_para = with_reviews[target]
                ctx.ReviewPopup.closeVisible()
                UIManager:nextTick(function()
                    self:showParaComments(target_para)
                end)
            end
        end
    end

    ctx.ReviewPopup.show{
        pages = items,
        pic_dir = ctx.pic_dir,
        fetch_pic = fetch_pic,
        on_replies = on_replies,
        para_nav = para_nav,
        -- 段标识：区分「同一段继续加载」与「换了新一段」，决定弹窗是否保留滚动位置。
        paragraph_key = tostring(ctx.chapter_index) .. ":" .. tostring(paragraph_index),
        doc_font_name = self.style.body_font,
        -- 同一字体文件内的字面选择（TTC 等）：正文用 body_font_index 取字面，
        -- 弹窗必须同 index，否则多字面字体下弹窗字形与正文不一致。
        doc_font_index = self.style.body_font_index,
        doc_font_size = (body_face and body_face.size) or Screen:scaleBySize(20),
        doc_margins = {
            left = (geometry and geometry.left) or Screen:scaleBySize(16),
            right = (geometry and geometry.right) or Screen:scaleBySize(16),
            top = Screen:scaleBySize(8),
            bottom = Screen:scaleBySize(8),
        },
        height_ratio = 0.7,
        -- 番茄 2.2.0-fixed.6：弹窗字色与正文对齐。旧值 7 会把作者行的浅灰
        -- 全部压成纯黑，层级全毁；0 = 内容纯黑、辅助信息保持浅灰。
        contrast = 0,
        -- 弹窗字重跟随正文（字重刻度 -3~5.5），face_factory 统一换算仿粗。
        doc_font_weight = self.style.body_weight or 0,
        -- fanqie 原版没有「点左右半屏翻页」，弹窗内只靠上下滑/滚动翻评论。
        -- 保持 1:1：不传 tap_to_page，点击评论正文不再翻页（action 行/图片仍响应）。
        more_text = more_text,
        on_more = on_more,
    }
    return true
end

-- 「本页段评」：把当前页上带评论的段落列出来，直接点进去看。
function ReaderView:showPageParaCommentList()
    if self.para_review_enabled ~= true then
        UIManager:show(Notification:new{ text = "请先打开「段评」" })
        return
    end
    local page = self.page
    local model = page and page.chapter_model
    if type(model and model.para_counts) ~= "table" then
        -- 计数现在是异步取的：直接 return 会让这次点按毫无反应。等结果回来再列一次
        -- （取失败时 on_ready 收到 nil，不递归；失败本身已经提示过了）。
        local chapter_index = page and page.chapter_index
        self:ensureParaCounts(true, function(counts)
            if not counts then return end
            if not (self.page and self.page.chapter_index == chapter_index) then return end
            self:showPageParaCommentList()
        end)
        return
    end
    local seen, entries = {}, {}
    for _, element in ipairs(page.elements or {}) do
        if element.type == "line" and element.para_marker and element.paragraph
                and not seen[element.paragraph] then
            seen[element.paragraph] = true
            entries[#entries + 1] = element.paragraph
        end
    end
    if #entries == 0 then
        UIManager:show(Notification:new{ text = "本页没有带评论的段落" })
        return
    end
    local dialog
    local buttons = {}
    local limit = math.min(#entries, 8)
    for index = 1, limit do
        local paragraph = entries[index]
        local pid = paragraph - 1
        local label = Util.trim(tostring((model.paragraphs and model.paragraphs[paragraph]) or ""))
        if Util.utf8Length(label) > 12 then label = Util.utf8Sub(label, 1, 12) .. "…" end
        local count = tonumber(model.para_counts[pid]) or 0
        -- 100 是「99+」的下界哨兵（服务端把热门段截断成 99+），列表里
        -- 不能再显示成「100 条」，与正文气泡保持一致。
        local count_text = count > 99 and "99+" or tostring(count)
        buttons[#buttons + 1] = { {
            text = "第" .. tostring(pid + 1) .. "段 · " .. count_text .. " 条 · " .. label,
            callback = function()
                UIManager:close(dialog)
                self:showParaComments(paragraph)
            end,
        } }
    end
    dialog = ButtonDialog:new{ title = "本页段评", buttons = buttons }
    UIManager:show(dialog)
end

function ReaderView:_nextPageGeneration()
    self._pending_history = nil
    self.page_generation = (self.page_generation or 0) + 1
    return self.page_generation
end

function ReaderView:isPageGenerationCurrent(generation)
    return generation == nil or generation == self.page_generation
end

function ReaderView:setPage(page, refresh_type, direction, generation)
    if generation and not self:isPageGenerationCurrent(generation) then return false end
    local pending = self._pending_history
    if pending and pending.generation == generation then
        if pending.forward then
            table.insert(self.history, pending.position)
        elseif self.history[#self.history] == pending.position then
            table.remove(self.history)
        end
        self._pending_history = nil
    end
    if not direction then self:_cancelSwipeRefresh() end
    self.page = page
    self._progress_dirty = true
    self._footer_dirty = true
    -- Kindle flash storage is intentionally not touched on page turns. Keep
    -- the exact cursor in memory and write it once when the reader closes.
    BookService:savePosition(self.book, page.start_position, false)
    -- Establish the cache window before constructing the target page. This
    -- lets the footer show the existing unfinished cached/total state on the
    -- first paint of a page turn, instead of waiting for a later event.
    BookService:requestPrefetch(self.book, page.chapter_index, BookService.prefetch_window)
    if self.statistics_bridge then self.statistics_bridge:onPageChanged(self:_statisticsVirtualPage()) end
    self:_syncPrefetchState()
    -- 段评：进入新的一章后，等本页画完再后台补一次本章评论计数。
    self:_scheduleParaCounts(page)
    -- 翻页一律走 KOReader 原生链路（同章 / 跨章都一样）：
    -- 翻页前设好一次性动画标志，随后照常 rebuild（内部 UIManager:setDirty
    -- 触发 _repaint）。刷新类型恒为 "partial" 且不带 region —— KOReader 按
    -- full_refresh_count（设置里的「全刷页数」）自动决定哪一次升级成整屏全刷；
    -- leko 既不自己刷新 framebuffer，也不为跨章另外插一次 full。
    if direction and self:isSwipeAnimationEnabled() and Device:canDoSwipeAnimation() then
        Screen:setSwipeAnimations(true)
        Screen:setSwipeDirection(direction == PageDirection.FORWARD)
    end
    self.menu_visible = false
    self:rebuild(refresh_type or "partial")
    return true
end

function ReaderView:applyPreparedPosition(position, refresh_type, direction, generation)
    if generation and not self:isPageGenerationCurrent(generation) then return true end
    local page, err = Paginator:makePage(self.book, position, self.style)
    if not page then return nil, tostring(err or "章节分页失败") end
    self.menu_visible = false
    return self:setPage(page, refresh_type, direction, generation)
end

function ReaderView:loadPage(position, refresh_type, direction, generation)
    generation = generation or self:_nextPageGeneration()
    if not self:isPageGenerationCurrent(generation) then return true end
    local target_chapter = self.book.chapters and self.book.chapters[position.chapter]
    if not target_chapter then
        self:_settleSwipeRefresh()
        UIManager:show(Notification:new{ text = "章节不存在" })
        return nil, "章节不存在"
    end
    local on_disk = BookService:isChapterDownloaded(self.book, position.chapter)
    local needs_download = not on_disk and target_chapter.url
    -- 段评计数与正文并行：正文那趟在子进程里跑的时候，让计数也在另一个
    -- （受内存闸门限制的）伴随子进程里跑，首次开章少等一次完整往返。
    self:_prefetchParaCounts(position.chapter)
    if needs_download then
        if type(self.onPrepareChapter) ~= "function" then
            self:_settleSwipeRefresh()
            UIManager:show(Notification:new{ text = "这一章尚未下载，现在无法读取" })
            return nil, "异步章节读取器不可用"
        end
        local task, err = self.onPrepareChapter(self, position, refresh_type, {
            direction = direction,
            generation = generation,
        })
        if not task and err then
            self:_settleSwipeRefresh()
            UIManager:show(Notification:new{ text = tostring(err) })
        end
        return task
    end
    local ok, err = self:applyPreparedPosition(position, refresh_type, direction, generation)
    if not ok then
        self:_settleSwipeRefresh()
        UIManager:show(Notification:new{ text = tostring(err) })
    end
    return ok, err
end

function ReaderView:applyTocUpdate(updated_book, change)
    if type(updated_book) ~= "table" then return nil, "目录更新结果无效" end
    self:_settleSwipeRefresh()
    self:_nextPageGeneration()
    local previous = self.book
    local page = self.page
    local current_chapter = page and page.chapter_index
    local current_id = current_chapter and previous.chapters
        and previous.chapters[current_chapter] and previous.chapters[current_chapter].id
    local position = page and Util.positionCopy(page.start_position)
    self.book = updated_book
    BookService:clearBookCache(updated_book.id)
    local target_index
    if current_id then
        for index, chapter in ipairs(updated_book.chapters or {}) do
            if chapter.id == current_id then target_index = index; break end
        end
    end
    target_index = target_index or (updated_book.position and updated_book.position.chapter) or 1
    if position then
        local target = updated_book.chapters and updated_book.chapters[target_index]
        local same_chapter = current_chapter == target_index
            and (not current_id or (target and tostring(current_id) == tostring(target.id)))
        position.chapter = target_index
        position.chapter_id = target and target.id or nil
        if not same_chapter then
            position.paragraph = 1
            position.char = 1
        end
        local rebuilt = Paginator:makePage(updated_book, position, self.style)
        if rebuilt then
            self:setPage(rebuilt, "ui")
        end
    end
    return true
end

function ReaderView:reloadCurrentChapter()
    if self._closing or type(self.onPrepareChapter) ~= "function" or not self.page then return true end
    self:_settleSwipeRefresh()
    local generation = self:_nextPageGeneration()
    local position = Util.positionCopy(self.page.start_position)
    local task, err = self.onPrepareChapter(self, position, "full", {
        force_network = true,
        generation = generation,
        present = function(reader, updated_book, target_position, refresh_type)
            BookService:clearBookCache(updated_book.id)
            return reader:applyPreparedPosition(target_position, refresh_type, nil, generation)
        end,
    })
    if not task and err then UIManager:show(Notification:new{ text = tostring(err) }) end
    return task or true
end

function ReaderView:nextPage()
    if self.page.at_end then
        self:_settleSwipeRefresh()
        if type(self.onRefreshToc) == "function" then
            local task, err = self.onRefreshToc(self, {})
            if not task and err then UIManager:show(Notification:new{ text = tostring(err) }) end
        else
            UIManager:show(Notification:new{ text = "已经是最后一页" })
        end
        return true
    end
    local generation = self:_nextPageGeneration()
    self._pending_history = { generation = generation, forward = true,
        position = Util.positionCopy(self.page.start_position) }
    self:loadPage(self.page.next_position, "partial", PageDirection.FORWARD, generation)
    return true
end

function ReaderView:_showPreviousPage(target_position, refresh_type, generation)
    if generation and not self:isPageGenerationCurrent(generation) then return false end
    local page, err = Paginator:findPreviousPage(self.book, target_position, self.style)
    if not page then return nil, tostring(err or "已经是第一页") end
    self.menu_visible = false
    return self:setPage(page, refresh_type or "partial", PageDirection.BACKWARD, generation)
end

function ReaderView:previousPage()
    local target = self.history[#self.history]
    if target then
        local generation = self:_nextPageGeneration()
        self._pending_history = { generation = generation, position = target }
        self:loadPage(target, "partial", PageDirection.BACKWARD, generation)
        return true
    end

    local current = self.page.start_position
    local generation = self:_nextPageGeneration()
    local crosses_chapter = current.chapter > 1 and Paginator:isChapterStart(self.book, current)
    local previous_chapter = crosses_chapter and (current.chapter - 1) or nil
    if previous_chapter and not BookService:isChapterDownloaded(self.book, previous_chapter) then
        if type(self.onPrepareChapter) ~= "function" then
            self:_settleSwipeRefresh()
            UIManager:show(Notification:new{ text = "上一章尚未下载，现在无法读取" })
            return true
        end
        local task, err = self.onPrepareChapter(self, {
            chapter = previous_chapter, paragraph = 1, char = 1,
        }, "partial", {
            direction = PageDirection.BACKWARD,
            generation = generation,
            present = function(reader)
                return reader:_showPreviousPage(current, "partial", generation)
            end,
        })
        if not task and err then
            self:_settleSwipeRefresh()
            UIManager:show(Notification:new{ text = tostring(err) })
        end
        return true
    end

    local ok, err = self:_showPreviousPage(current, "partial", generation)
    if not ok then
        self:_settleSwipeRefresh()
        UIManager:show(Notification:new{ text = tostring(err) })
    end
    return true
end

function ReaderView:jumpToChapter(chapter_index)
    self:_settleSwipeRefresh()
    self.history = {}
    self.menu_visible = false
    local generation = self:_nextPageGeneration()
    self:loadPage({ chapter = chapter_index, paragraph = 1, char = 1 }, "full", nil, generation)
end

function ReaderView:jumpChapter(delta)
    local index = math.max(1, math.min(#(self.book.chapters or {}), (self.page.chapter_index or 1) + delta))
    if index == self.page.chapter_index then
        self:_settleSwipeRefresh()
        UIManager:show(Notification:new{ text = delta < 0 and "已经是第一章" or "已经是最后一章" })
        return true
    end
    self:jumpToChapter(index)
    return true
end

function ReaderView:showToc()
    self:_settleSwipeRefresh()
    self.menu_visible = false
    self:onReadingPaused()
    -- The full-screen TOC covers this page. Re-shaping the body here delays
    -- the tap response and paints a page the user never needs to see.
    return UI.showLater(self, "toc", function()
        return TocView:new{
            book = self.book,
            current_chapter = self.page.chapter_index,
            onChapterSelected = function(chapter_index)
                self:onReadingResumed()
                self:jumpToChapter(chapter_index)
            end,
            on_return = function()
                self:onReadingResumed()
                self:rebuild("ui")
                self:_scheduleFooterRefresh(true)
            end,
        }
    end, "full")
end

function ReaderView:showBookInfo()
    self:_settleSwipeRefresh()
    self.menu_visible = false
    self:onReadingPaused()
    self:rebuild("ui")
    return UI.defer(self, "book_info", function()
        if self.onShowBookInfo then self.onShowBookInfo(self.book, self) end
    end)
end

function ReaderView:addToBookshelf()
    self:_settleSwipeRefresh()
    if Storage:isInLibrary(self.book.id) then UIManager:show(Notification:new{ text = "本书已在书架" }); return true end
    local book, err = BookService:addToBookshelf(self.book)
    if not book then UIManager:show(Notification:new{ text = "加入书架失败：" .. tostring(err) }); return true end
    self.book = book
    UIManager:show(Notification:new{ text = "已加入书架" })
    if self.onBookAdded then self.onBookAdded(book) end
    self:rebuild("ui")
    return true
end

function ReaderView:toggleMenu(force)
    self:_settleSwipeRefresh()
    self.menu_visible = force == nil and not self.menu_visible or force == true
    self:rebuild("ui")
    if not self.menu_visible then self:_scheduleFooterRefresh(true) end
    return true
end

function ReaderView:applyStyleChange(callback)
    self:_settleSwipeRefresh()
    callback(self.style)
    -- 段间距按 em 语义：移动过段间距滑块后按字号实时换算，
    -- 这样调字号时段落留白跟着一起缩放。老存档没有 em 字段，行为不变。
    if type(self.style.paragraph_spacing_em) == "number" then
        self.style.paragraph_spacing = self.style.paragraph_spacing_em
            * (tonumber(self.style.body_font_size) or 27)
    end
    self.history = {}
    -- 排版变了：页表必然重排，顺手清掉「这版排不出来」的记忆，避免旧签名卡住。
    self._chapter_pages_failed_sig = nil
    BookService:clearBookCache(self.book.id)
    local page, err = Paginator:makePage(self.book, self.page.start_position, self.style)
    self:consumeFontFallbackNotice()
    Storage:saveReaderStyle(self.style)
    if not page then UIManager:show(Notification:new{ text = tostring(err) }); return end
    self.page = page
    self._progress_dirty = true
    self._footer_dirty = true
    self.menu_visible = true
    -- Reflow changes only the in-memory cursor; the close path persists it.
    BookService:savePosition(self.book, page.start_position, false)
    self:rebuild("full")
    self:_scheduleFooterRefresh(true)
end

function ReaderView:applyFontSelection(selection)
    if type(selection) ~= "table" then return end
    self:applyStyleChange(function(style)
        local path = selection.font_path or "cfont"
        local index = selection.face_index
        local display = selection.display_name or FontSelectionView.SYSTEM_DISPLAY_NAME
        style.body_font = path
        style.body_font_index = index
        style.body_font_display_name = display
        style.title_font = path
        style.title_font_index = index
        style.title_font_display_name = display
    end)
end

-- 「阅读状态栏」二级页：时间 / 电量 / Wi-Fi / 页码 / 章节标题 / 每分钟刷新。
-- 语义对齐阅读状态栏设置，但 leko 是自己的页眉页脚渲染，
-- 开关只改 style 字段，不改变 geometry（页眉页脚高度由总开关决定）。
function ReaderView:refreshStatusMenu()
    local dialog = self._status_dialog
    if not dialog then return false end
    return UI.defer(self, "status_menu_refresh", function()
        local d = self._status_dialog
        if self._closing or not d then return end
        if type(d.reinit) == "function" then
            d.buttons = self:makeStatusMenuButtons()
            d:reinit()
            local region = d.movable and d.movable.dimen or d.dimen
            if region then UIManager:setDirty(d, "ui", region) end
        end
    end)
end

function ReaderView:_statusToggle(key, label)
    self:applyStyleChange(function(style)
        style[key] = style[key] == false
    end)
    self:refreshStatusMenu()
end

function ReaderView:makeStatusMenuButtons()
    local style = self.style
    local function row(key, label)
        return { text = label .. "：" .. (style[key] == false and "关" or "开"),
            callback = function() self:_statusToggle(key, label) end }
    end
    return {
        { row("show_title", "章节标题"), row("show_time", "时间") },
        { row("show_battery", "电量"), row("show_wifi", "Wi-Fi") },
        { row("show_page", "页码与进度"), row("status_minute_refresh", "每分钟刷新") },
        {
            { text = self.style.show_header and "页眉：显示" or "页眉：隐藏", callback = function()
                self:applyStyleChange(function(s) s.show_header = not s.show_header end)
            end },
            { text = self.style.show_footer and "页脚：显示" or "页脚：隐藏", callback = function()
                self:applyStyleChange(function(s) s.show_footer = not s.show_footer end)
            end },
        },
        { { text = "返回排版", callback = function()
            local dialog = self._status_dialog
            if dialog then UIManager:close(dialog) end
            self._status_dialog = nil
            self:showLayoutMenu()
        end } },
    }
end

function ReaderView:showStatusMenu()
    self:_settleSwipeRefresh()
    local dialog = self._status_dialog
    if dialog and UIManager.isWidgetShown and UIManager:isWidgetShown(dialog) then return true end
    local new_dialog = ButtonDialog:new{
        title = "阅读状态栏",
        modal = true,
        buttons = self:makeStatusMenuButtons(),
        tap_close_callback = function()
            self._status_dialog = nil
            self:showLayoutMenu()
        end,
    }
    self._status_dialog = new_dialog
    return UI.showModalLater(self, "status_menu", function() return new_dialog end)
end

function ReaderView:hasFrontlightControl()
    if type(Device.hasFrontlight) ~= "function" then return false end
    local ok, available = pcall(Device.hasFrontlight, Device)
    return ok and available == true
end

function ReaderView:showFontSelection()
    self:_settleSwipeRefresh()
    self:_scheduleFooterRefresh(true)
    return UI.showLater(self, "font_selection", function()
        return FontSelectionView:new{
            style = self.style,
            on_selected = function(selection) self:applyFontSelection(selection) end,
            on_return = function()
                self:_scheduleFooterRefresh(true)
                if not self._closing then self:showLayoutMenu() end
            end,
        }
    end, "full")
end

-- 排版 / 设备控制都是简洁风格底部弹窗（正文仍可见），不再是 ButtonDialog。
-- 从页面返回后重新显示阅读页的菜单浮层，读者不必再点一次屏幕。
function ReaderView:showLayoutMenu()
    self:_settleSwipeRefresh()
    if self._layout_page and UIManager.isWidgetShown
            and UIManager:isWidgetShown(self._layout_page) then return true end
    return UI.showLater(self, "layout_page", function()
        local page = LayoutSettingsView:new{
            style = self.style,
            onApply = function(fn) self:applyStyleChange(fn) end,
            onFont = function() self:showFontSelection() end,
            onStatus = function() self:showStatusMenu() end,
            onClosed = function()
                self._layout_page = nil
                if not self._closing then
                    self.menu_visible = true
                    self:rebuild("ui")
                end
            end,
        }
        self._layout_page = page
        return page
    end, "ui")
end

function ReaderView:showDeviceMenu()
    self:_settleSwipeRefresh()
    if self._device_page and UIManager.isWidgetShown
            and UIManager:isWidgetShown(self._device_page) then return true end
    return UI.showLater(self, "device_page", function()
        local page = DeviceControlView:new{
            style = self.style,
            onApply = function(fn) self:applyStyleChange(fn) end,
            onParaReviewChanged = function(v) self:setParaReviewEnabled(v) end,
            onClosed = function()
                self._device_page = nil
                if not self._closing then
                    self.menu_visible = true
                    self:rebuild("ui")
                end
            end,
        }
        self._device_page = page
        return page
    end, "ui")
end

function ReaderView:routeTap(ges)
    local x = ges and ges.pos and ges.pos.x or self.dimen.w / 2
    local y = ges and ges.pos and ges.pos.y or self.dimen.h / 2
    if self.menu_visible then return self:toggleMenu(false) end
    -- 段评气泡优先于翻页分区判定：点在气泡上就打开这一段的评论。
    local paragraph = self:_paraMarkerAt(x, y)
    if paragraph then
        self:showParaComments(paragraph)
        return true
    end
    local width, height = self.dimen.w, self.dimen.h
    -- Kindle/KOReader-style tap map: narrow left gutter goes backward, most
    -- of the page goes forward, and only a compact centre target
    -- open controls. Keep this in one router so registered and fallback touch
    -- paths always share exactly the same geometry.
    if x >= width * 0.38 and x <= width * 0.62
            and y >= height * 0.36 and y <= height * 0.64 then
        return self:toggleMenu(true)
    end
    if x < width * 0.16 then return self:previousPage() end
    return self:nextPage()
end

function ReaderView:routeSwipe(ges)
    if self.menu_visible then return self:toggleMenu(false) end
    local direction = ges and ges.direction
    if direction == "west" then return self:nextPage() end
    if direction == "east" then return self:previousPage() end
    if direction == "north" or direction == "south" then return self:toggleMenu(true) end
    return true
end

function ReaderView:onTap(_, ges) return self:routeTap(ges) end
function ReaderView:onHold() return self:toggleMenu(true) end
function ReaderView:onSwipe(_, ges) return self:routeSwipe(ges) end
function ReaderView:onReaderMenu() return self:toggleMenu() end
function ReaderView:onPageForward() return self:nextPage() end
function ReaderView:onPageBackward() return self:previousPage() end

-- ── 遥控器 / Dispatcher 事件 ──────────────────────────────────────────────
-- KOReader HTTP Inspector（/koreader/event/<事件名>/<参数>）和 Dispatcher 的
-- 动作都用 UIManager:sendEvent 发事件 —— 它只把事件交给窗口栈最上面那个非
-- toast 窗口。leko 阅读时自己就是栈顶，但 leko 不加载 ReaderUI，于是
-- ReaderPaging / ReaderToc / ReaderFrontLight 里的 onGotoViewRel、onShowToc
-- 那些处理函数统统不在场，遥控器点下去就石沉大海。这里按 leko 自己的实现
-- 把事件接住。每个处理完必须返回 true 消费掉，否则还会漏给底层窗口。

-- 翻页。leko 一次只取一屏（取页本身可能触发跨章下载），不像 crengine 那样能
-- 一次跳 N 页，所以只认方向：正数前进、负数后退。
function ReaderView:onGotoViewRel(diff)
    if self._closing then return false end
    local step = tonumber(diff)
    if step == nil or step == 0 then return false end
    if self.menu_visible then self:toggleMenu(false) end
    if step > 0 then return self:nextPage() end
    return self:previousPage()
end

function ReaderView:onShowToc()
    if self._closing then return false end
    if self.menu_visible then self:toggleMenu(false) end
    return self:showToc()
end

-- 章节跳转：leko 一章一章地缓存，没有 crengine 那种「翻到下一章首屏」之外的
-- 概念，所以 next/prev chapter 就是 jumpChapter(±1)。
function ReaderView:onGotoNextChapter()
    if self._closing then return false end
    if self.menu_visible then self:toggleMenu(false) end
    return self:jumpChapter(1)
end

function ReaderView:onGotoPrevChapter()
    if self._closing then return false end
    if self.menu_visible then self:toggleMenu(false) end
    return self:jumpChapter(-1)
end

-- 「首页 / 末页」在 leko 里落到第一章 / 最后一章的开头。
function ReaderView:onGoToBeginning()
    if self._closing then return false end
    if self.menu_visible then self:toggleMenu(false) end
    self:jumpToChapter(1)
    return true
end

function ReaderView:onGoToEnd()
    if self._closing then return false end
    if self.menu_visible then self:toggleMenu(false) end
    self:jumpToChapter(math.max(1, #(self.book.chapters or {})))
    return true
end

function ReaderView:onShowMenu()
    if self._closing then return false end
    return self:toggleMenu()
end

function ReaderView:onFullRefresh()
    if self._closing then return false end
    self:_settleSwipeRefresh()
    -- 遥控器主动全刷：传 nil widget 的 "full" 就是 KOReader 自己的整屏刷新，
    -- 顺带把 refresh_count 归零，不会紧接着再黑闪一次。
    if type(UIManager.setDirty) == "function" then UIManager:setDirty(nil, "full") end
    return true
end

function ReaderView:onToggleNightMode()
    if self._closing then return false end
    -- 与设备控制页一致：走 KOReader 全局反转，不再改 leko 自己的 style.night_mode。
    pcall(function()
        require("device/devicelistener"):new{}:onToggleNightMode()
    end)
    return true
end

function ReaderView:onRequestSuspend()
    if self._closing then return false end
    if type(UIManager.suspend) ~= "function" then return false end
    UIManager:suspend()
    return true
end

-- 前光。leko 没有 ReaderFrontLight 模块，直接操作设备的 powerd。
function ReaderView:_powerDevice()
    if not self:hasFrontlightControl() then return nil end
    if type(Device.getPowerDevice) ~= "function" then return nil end
    local ok, powerd = pcall(Device.getPowerDevice, Device)
    if not ok or type(powerd) ~= "table" then return nil end
    return powerd
end

-- 越界贴边。拿不到量程上限时把原值原样交给 powerd，让它自己夹 ——
-- 总比猜一个量程要好。
local function clampFrontlight(powerd, field, value)
    local min = tonumber(powerd[field .. "_min"] or powerd.fl_min) or 0
    local max = tonumber(powerd[field .. "_max"] or powerd.fl_max)
    if not max then return value end
    return math.max(min, math.min(max, value))
end

-- value 为 nil 表示「按 delta 走一步」，否则按绝对值设置。
function ReaderView:_applyFrontlight(field, setter, value, delta)
    local powerd = self:_powerDevice()
    if not powerd then return false end
    if type(powerd[setter]) ~= "function" then return false end
    local current = tonumber(powerd[field])
    if current == nil then return false end
    local target = value
    if target == nil then
        if not delta or delta == 0 then return false end
        target = current + delta
    end
    return pcall(powerd[setter], powerd, clampFrontlight(powerd, field, target)) == true
end

function ReaderView:onIncreaseFlIntensity(delta)
    return self:_applyFrontlight("fl_intensity", "setIntensity", nil, tonumber(delta) or 1)
end

function ReaderView:onDecreaseFlIntensity(delta)
    return self:_applyFrontlight("fl_intensity", "setIntensity", nil, -(tonumber(delta) or 1))
end

function ReaderView:onSetFlIntensity(value)
    return self:_applyFrontlight("fl_intensity", "setIntensity", tonumber(value))
end

function ReaderView:onIncreaseFlWarmth(delta)
    return self:_applyFrontlight("fl_warmth", "setWarmth", nil, tonumber(delta) or 1)
end

function ReaderView:onDecreaseFlWarmth(delta)
    return self:_applyFrontlight("fl_warmth", "setWarmth", nil, -(tonumber(delta) or 1))
end

function ReaderView:onSetFlWarmth(value)
    return self:_applyFrontlight("fl_warmth", "setWarmth", tonumber(value))
end

function ReaderView:onToggleFrontlight()
    local powerd = self:_powerDevice()
    if not powerd then return false end
    if type(powerd.toggleOnOff) ~= "function" then return false end
    return pcall(powerd.toggleOnOff, powerd) == true
end

function ReaderView:onFlushSettings()
    if self.page and self._progress_dirty then
        local pos = self.page.start_position or {}
        local saved = BookService:savePosition(self.book, pos, true)
        if saved ~= false then
            self._progress_dirty = false
        else
            self._progress_dirty = true
        end
    end
    if self.statistics_bridge then self.statistics_bridge:checkpoint() end
end

function ReaderView:onSuspend()
    self:_settleSwipeRefresh()
    if self.statistics_bridge then self.statistics_bridge:pause() end
    -- Power/suspend is the other safe persistence boundary. Do not write on
    -- every page turn; save the latest in-memory cursor before sleep.
    self:onFlushSettings()
end

function ReaderView:onResume()
    if self.statistics_bridge then self.statistics_bridge:resume(self:_statisticsVirtualPage()) end
end

function ReaderView:onReadingPaused()
    if self.statistics_bridge then self.statistics_bridge:pause() end
end

function ReaderView:onReadingResumed()
    if self.statistics_bridge then self.statistics_bridge:resume(self:_statisticsVirtualPage()) end
end

-- Rotation actions are dispatched by the host before the screen geometry is
-- rebuilt.  Settle any old-dimension strip callback first.
function ReaderView:onIterateRotation()
    self:_settleSwipeRefresh()
    return false
end

function ReaderView:onSwapRotation()
    self:_settleSwipeRefresh()
    return false
end

function ReaderView:onInvertRotation()
    self:_settleSwipeRefresh()
    return false
end

function ReaderView:onRotation()
    self:_settleSwipeRefresh()
    return false
end

function ReaderView:closeReaderNow()
    if self._closing then return true end
    self._closing = true
    -- 段评的子进程要在关阅读器时立刻收掉：Kindle 的可用内存本来就紧，
    -- 让一个还在跑 HTTP 的子进程活到书架上去毫无意义。等待提示也必须摘掉，
    -- 否则它会盖在书架上，而点它已经没有阅读器可以取消了。
    self._para_request_token = nil
    self._para_counts_token = nil
    self:_endParaWait()
    AsyncParaReview:release()
    self:_cancelSwipeRefresh()
    if self._exit_dialog then UIManager:close(self._exit_dialog); self._exit_dialog = nil end
    for _, key in ipairs({ "_layout_page", "_device_page", "_status_dialog" }) do
        local page = self[key]
        if page then UIManager:close(page) end
        self[key] = nil
    end

    BookService:cancelPrefetch(self.book.id)
    BookService:unobservePrefetch(self.book.id, self)
    if self.statistics_bridge then self.statistics_bridge:close() end
    self:onFlushSettings()

    -- 横屏只用于阅读：退出前先回竖屏，让下面的书架重建直接按竖屏尺寸排，
    -- 避免横屏书架/KOReader 布局错乱与残影（Sean 2026-11-28）。
    UI.resetPortrait()
    -- Rebuild the covered bookshelf before removing the reader. UIManager will
    -- then reveal it with a single full refresh instead of repainting it twice.
    if self.onBeforeReaderClose then self.onBeforeReaderClose(self.book) end

    local book_id = self.book.id
    self.history = {}
    self.prefetch_state = nil
    self.page = nil
    self[1] = nil
    UIManager:close(self, "full")

    BookService:clearBookCache(book_id)
    BookService:releaseRuntimeSource(book_id)
    if self.onReaderClosed then self.onReaderClosed(self.book) end

    -- Incremental GC avoids a long synchronous pause on older Kindles.
    for step = 1, 4 do
        UIManager:scheduleIn(step * 0.12, function() collectgarbage("step", 180) end)
    end
    return true
end

function ReaderView:requestExit()
    if Storage:isInLibrary(self.book.id) then return self:closeReaderNow() end
    self:_settleSwipeRefresh()
    if self._exit_dialog then
        if UIManager.isWidgetShown and UIManager:isWidgetShown(self._exit_dialog) then return true end
        self._exit_dialog = nil
    end
    self:onReadingPaused()
    return UI.showModalLater(self, "exit_dialog", function()
        local dialog
        dialog = ButtonDialog:new{
            modal = true,
            title = "退出试读",
            buttons = {
                {
                    { text = "加入书架并退出", callback = function()
                        UIManager:close(dialog); self._exit_dialog = nil
                        self:addToBookshelf(); self:closeReaderNow()
                    end },
                },
                {
                    { text = "仅退出", callback = function()
                        UIManager:close(dialog); self._exit_dialog = nil; self:closeReaderNow()
                    end },
                    { text = "继续阅读", callback = function()
                        UIManager:close(dialog); self._exit_dialog = nil
                        self:onReadingResumed()
                    end },
                },
            },
            tap_close_callback = function() self._exit_dialog = nil; self:onReadingResumed() end,
        }
        self._exit_dialog = dialog
        return dialog
    end)
end

function ReaderView:onClose()
    if self.menu_visible then return self:toggleMenu(false) end
    return self:requestExit()
end
function ReaderView:onCloseWidget()
    self._para_request_token = nil
    self._para_counts_token = nil
    -- 页脚时钟：关页必须停表，否则回调会在已销毁的视图上重绘。
    if self._clock_timer then
        UIManager:unschedule(self._clock_timer)
        self._clock_timer = nil
    end
    self:_endParaWait()
    AsyncParaReview:release()
    self:_cancelSwipeRefresh()
    if self.statistics_bridge then self.statistics_bridge:close() end
    self:onFlushSettings()
end

return ReaderView
