local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
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
local Screen = Device.screen

local AsyncParaReview = require("Leko/AsyncParaReview")
local BookService = require("Leko/BookService")
local FontSelectionView = require("Leko/FontSelectionView")
local KOReaderStatisticsBridge = require("Leko/KOReaderStatisticsBridge")
local Paginator = require("Leko/Paginator")
local ParaComments = require("Leko/ParaComments")
local ReaderMargins = require("Leko/ReaderMargins")
local ReaderFooter = require("Leko/ReaderFooter")
local Storage = require("Leko/Storage")
local TocView = require("Leko/TocView")
local UI = require("Leko/UI")
local Util = require("Leko/Util")

-- Keep the semantic direction constants available even when an older or
-- mixed plugin directory cannot load the optional transition coordinator.
-- The real module is loaded only when a ReaderView is created.
local SwipeRefresh = { FORWARD = "forward", BACKWARD = "backward" }
local swipe_refresh_module
local swipe_refresh_load_error

local function loadSwipeRefresh()
    if swipe_refresh_module ~= nil then
        return swipe_refresh_module ~= false and swipe_refresh_module or nil,
            swipe_refresh_load_error
    end
    local ok, module = pcall(require, "Leko/SwipeRefresh")
    if not ok or type(module) ~= "table" or type(module.new) ~= "function" then
        swipe_refresh_load_error = tostring(ok and "transition coordinator API is invalid" or module)
        swipe_refresh_module = false
        return nil, swipe_refresh_load_error
    end
    swipe_refresh_module = module
    SwipeRefresh = module
    return module
end

local ReaderView = InputContainer:extend{
    covers_fullscreen = true,
    -- Full-screen application pages must remain non-modal.
    -- KOReader keeps modal windows above ordinary dialogs, which would hide InputDialog/ButtonDialog.
    modal = false,
}

function ReaderView:init()
    self.style = Storage:getReaderStyle()
    self.history = {}
    self.menu_visible = false
    self._exit_dialog = nil
    self._layout_dialog = nil
    self._closing = false
    self.prefetch_state = nil
    self._progress_dirty = false
    self._footer_dirty = true
    self.page_generation = 0
    self._pending_rebuild = nil
    self.swipe_animation_enabled = self.style.page_transition_enabled ~= false
    self.chapter_clean_wave_enabled = self.style.chapter_clean_wave_enabled ~= false
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
    local swipe_module, swipe_error = loadSwipeRefresh()
    if swipe_module then
        local constructed, coordinator = pcall(swipe_module.new, swipe_module, {
            screen = Screen,
            ui_manager = UIManager,
        })
        if constructed and type(coordinator) == "table" then
            self.swipe_refresh = coordinator
        else
            self.swipe_refresh = nil
            swipe_error = tostring(coordinator or "transition coordinator initialization failed")
        end
    end
    self._swipe_refresh_load_error = swipe_error
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
    if self._swipe_refresh_load_error then
        local message = "动画效果模块加载失败，已回退普通刷新。请完全退出并重新打开 KOReader 后，重新复制完整的 leko.koplugin 文件夹。"
        logger.warn("Leko transition coordinator disabled:", self._swipe_refresh_load_error)
        if type(UIManager.nextTick) == "function" then
            UIManager:nextTick(function()
                if not self._closing then
                    UIManager:show(Notification:new{ text = message })
                end
            end)
        else
            UIManager:show(Notification:new{ text = message })
        end
    end
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
    -- One compact action row. Font controls live inside the layout dialog.
    local bottom_h = math.max(64, math.floor(self.dimen.h * 0.09))
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

function ReaderView:buildFooterStatus(page, geometry)
    local total_chapters = #(self.book.chapters or {})
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

    local left_text = string.format("第 %d / %d 章", chapter_index, total_chapters)
    local right_text = string.format("本章 %d%%", math.floor(chapter_percentage * 100 + 0.5))
    -- The footer no longer renders any cache/prefetch indicator. A progress bar
    -- here meant one footer-only repaint per prefetch tick, and those regional
    -- refreshes could race the chapter-turn full refresh on E Ink.
    -- Keep the status line inside the same horizontal reading margins as the
    -- body. This avoids text touching the panel edges on small Kindle screens.
    local width = math.max(1, geometry.content_width or (geometry.screen_width
        - geometry.left - geometry.right))
    local height = geometry.footer_height
    local left_width = math.floor(width * 0.34)
    local right_width = math.floor(width * 0.24)
    local middle_width = math.max(1, width - left_width - right_width)
    local chrome_color = self:isNightMode() and Blitbuffer.COLOR_WHITE or nil

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
        TextWidget:new{
            text = right_text,
            face = geometry.chrome_face,
            padding = 0,
            max_width = right_width,
            fgcolor = chrome_color,
        },
    }

    -- Middle column stays empty: the footer only shows 「第 x / y 章」 and
    -- 「本章 n%」. Nothing about the background prefetch is rendered anymore.
    local middle_content = TextWidget:new{ text = "", face = geometry.chrome_face, padding = 0 }

    local footer = HorizontalGroup:new{
        left,
        CenterContainer:new{
            dimen = Geom:new{ w = middle_width, h = height },
            middle_content,
        },
        right,
    }
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

-- The footer no longer shows anything about the background prefetch, so a
-- progress tick must not trigger a repaint. Each tick used to rebuild the whole
-- reading page and then flush only the footer strip; on E Ink those regional
-- refreshes could race the chapter-turn refresh and leave a half-painted page.
function ReaderView:onPrefetchProgress(state)
    self.prefetch_state = state
end

-- Time + battery for the right side of the header. Battery is shown as
-- "[nn%]" (bracketed percent) when available; otherwise only the time shows.
function ReaderView:_headerStatusText()
    local time_text = ""
    local ok_time, time = pcall(os.date, "%H:%M")
    if ok_time and time then time_text = time end

    local battery_text = ""
    local ok, powerd = pcall(function() return Device:getPowerDevice() end)
    if ok and powerd and type(powerd.getCapacity) == "function" then
        local ok_cap, capacity = pcall(powerd.getCapacity, powerd)
        if ok_cap and capacity ~= nil then
            battery_text = string.format("[%d%%]", math.max(0, math.min(100, math.floor(capacity))))
        end
    end
    return time_text .. battery_text
end

-- 夜间模式: dark background with light text (黑底白字).
function ReaderView:isNightMode()
    return self.style and self.style.night_mode == true
end

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
        -- Header: chapter title left-aligned, time + battery on the right.
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
                    text = page.chapter_title or self.book.title,
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
                bold = false,
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
                marker_rects[#marker_rects + 1] = {
                    x = geometry.left + marker_x,
                    y = cursor_y,
                    w = marker_width,
                    h = element.height,
                    paragraph = element.paragraph,
                }
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
    local top = UI.header(width, top_h, {
        left_text = "‹ 书架",
        title = self.book.title or "阅读",
        right_text = "书籍详情",
        on_left = function() self:requestExit() end,
        on_right = function() self:showBookInfo() end,
        title_size = 21,
    })
    top.overlap_offset = { 0, 0 }

    local actions = UI.footer(width, bottom_h, {
        { text = "目录", bold = true, callback = function() self:showToc() end },
        { text = "上一章", callback = function() self:jumpChapter(-1) end },
        { text = "下一章", callback = function() self:jumpChapter(1) end },
        { text = "阅读设置", font_size = 16, callback = function() self:showLayoutMenu() end },
        { text = "刷新本章", font_size = 16, callback = function() self:reloadCurrentChapter() end },
    })
    local bottom = FrameContainer:new{
        width = width,
        height = bottom_h,
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        overlap_offset = { 0, height - bottom_h },
        actions,
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
    -- The ordinary path must remain independent of transition state. This is
    -- especially important immediately after the user turns animation off:
    -- a stale visual coordinator flag must not turn a direct rebuild into a
    -- pending repaint.
    if self:isSwipeAnimationEnabled() and self.swipe_refresh
            and self.swipe_refresh:isRunning() then
        self._pending_rebuild = {
            refresh_type = refresh_type or "ui",
            refresh_region = refresh_region,
        }
        return false
    end
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

-- The transition callback means that Screen.bb now owns the submitted pixels;
-- it is not a physical E Ink waveform-complete notification.
function ReaderView:_finishSwipeSubmission()
    if self._closing or not self.page then return end
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
    local pending = self._pending_rebuild
    self._pending_rebuild = nil
    if pending then
        local mode, region = pageRefresh(pending.refresh_type, pending.refresh_region, self.dimen)
        UIManager:setDirty(self, mode, region)
    end
end

function ReaderView:_settleSwipeRefresh()
    return self.swipe_refresh and self.swipe_refresh:settle() or false
end

function ReaderView:_cancelSwipeRefresh()
    return self.swipe_refresh and self.swipe_refresh:cancel() or false
end

function ReaderView:isSwipeAnimationEnabled()
    return self.swipe_animation_enabled ~= false
end

function ReaderView:setSwipeAnimationEnabled(enabled)
    enabled = enabled == true
    self.swipe_animation_enabled = enabled
    self.style.page_transition_enabled = enabled
    Storage:saveReaderStyle(self.style)
    if not enabled and self.swipe_refresh and self.swipe_refresh:isRunning() then
        -- Disabling animation must not wait for the physical waveform.  Drop
        -- the visual transition and repaint the current logical page through
        -- the ordinary ReaderView path.
        self:_cancelSwipeRefresh()
        self._pending_rebuild = nil
        if self.page then self:rebuild("partial") end
    end
    if not self:_refreshLayoutToggle("page_animation_toggle",
            enabled and "动画效果：开" or "动画效果：关") then
        self:refreshLayoutMenu()
    end
    return enabled
end

-- 「跨章净屏」现在直接调用 KOReader 的全局刷新（整屏 full 刷新，即
-- Screen.refreshFull），不再由本模块播放条带波。样式键沿用历史名字，
-- 老配置无需迁移。
function ReaderView:isChapterCleanEnabled()
    return self.chapter_clean_wave_enabled ~= false
end

function ReaderView:setChapterCleanEnabled(enabled)
    enabled = enabled == true
    self.chapter_clean_wave_enabled = enabled
    self.style.chapter_clean_wave_enabled = enabled
    Storage:saveReaderStyle(self.style)
    if not enabled and self.swipe_refresh and self.swipe_refresh:isRunning() then
        self:_cancelSwipeRefresh()
        if self.page then self:rebuild("partial") end
    end
    if not self:_refreshLayoutToggle("chapter_clean_toggle",
            enabled and "跨章净屏：开" or "跨章净屏：关") then
        self:refreshLayoutMenu()
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
    if not self:_refreshLayoutToggle("para_review_toggle",
            enabled and "段评：开" or "段评：关") then
        self:refreshLayoutMenu()
    end
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
    -- 每一个字都已经作废。这种规模的变更只能用整屏闪刷（和「跨章净屏」同一条路径）：
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
    UI.defer(self, "para_counts_" .. tostring(chapter_index), function()
        if self._closing then return end
        if not (self.page and self.page.chapter_index == chapter_index) then return end
        self:ensureParaCounts(false)
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
        if on_ready then
            local existing = model.para_counts
            on_ready(type(existing) == "table" and existing or nil)
        end
        return
    end
    local chapter_index = page.chapter_index
    if not ParaComments.isSupported(self.book, chapter_index) then
        if interactive then
            UIManager:show(Notification:new{ text = "本章没有段评（目前支持番茄 / 七猫 / QQ阅读）" })
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
        -- 已经有一批在飞（同一章重复触发很常见：打开开关 + 刚进章节各一次）。
        -- 再发一次只会让两批计数抢同一份缓存，等前一批回来就够了。
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
        -- 七猫的计数是按段落内容指纹给的，子进程要用同一份段落文本才能换算成
        -- 段号（见 ParaComments.qmCountsByParagraph）。
        paragraphs = model and model.paragraphs,
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

        local counts = payload.counts_map or {}
        -- 段落号越界说明服务端的分段与本地不一致：越界项直接丢弃，
        -- 免得把评论挂到不存在的段上（分页器只按 pid 查表，不越界取值）。
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
        -- 记账用「同步之后」的镜像：下次 _paraCountsFresh 是按同一个表达式算的，
        -- 这样才天然对得上（凭据缺失时它会回落到 "auto"）。
        model.para_counts, model.para_counts_epoch = counts, ParaComments.hostKey(source)
        -- 章节可能在等待期间被翻走：只有它还是当前页时才重排。
        if self.page and self.page.chapter_model == model then
            self:reflowForParaReview()
        end
        if on_ready then on_ready(counts) end
    end)
end

function ReaderView:_paraServerLabel()
    local source = BookService:sourceFor(self.book)
    if not source then return "镜像：无书源" end
    return "镜像：" .. ParaComments.hostLabel(ParaComments.host(source))
end

-- 段末气泡的命中判定。返回 1 基段落号，未命中返回 nil。
function ReaderView:_paraMarkerAt(x, y)
    if self.para_review_enabled ~= true then return nil end
    if self.swipe_refresh and self.swipe_refresh:isRunning() then return nil end
    local rects = self._para_hit_rects
    if type(rects) ~= "table" then return nil end
    -- 气泡本身只有几十像素宽，给一点横向余量，免得读者点了个寂寞。
    local slack = Screen:scaleBySize(6)
    for index = 1, #rects do
        local rect = rects[index]
        if x >= rect.x - slack and x <= rect.x + rect.w + slack
                and y >= rect.y and y <= rect.y + rect.h then
            return rect.paragraph
        end
    end
    -- 页面上明明画着气泡却没命中：多半是排版与命中区对不上（换行规则、字体
    -- 度量、行高任一处变了都会这样）。这种情况必须留下证据 —— 否则读者只会
    -- 觉得「点气泡变成了翻页」，而日志里什么都没有。
    --
    -- 只打第一个矩形没法判断偏在 x 还是 y（读者报「点不动」时只能靠猜），
    -- 所以打的是「纵向最接近的那个」以及相对它的右边缘 / 中心线差多少：
    --   dx > 0 说明点在气泡右边（气泡画得比命中区窄，或点在气泡外的空白）
    --   dy > h/2 说明纵向整行都错位（那才是真的排版与命中区不一致）
    if #rects > 0 then
        local near, near_dy
        for index = 1, #rects do
            local rect = rects[index]
            local dy = math.abs((rect.y + rect.h / 2) - y)
            if near_dy == nil or dy < near_dy then near, near_dy = rect, dy end
        end
        logger.warn("Leko para review: bubble tap missed", tostring(x), tostring(y),
            "rects=" .. tostring(#rects),
            string.format("near=%d,%d,%dx%d", near.x, near.y, near.w, near.h),
            string.format("dx=%d dy=%d", math.floor(x - (near.x + near.w)), math.floor(near_dy)))
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
    local source = BookService:sourceFor(self.book)
    if not source then
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

    local cursor = tonumber(options.cursor)
    local token = {}
    self._para_request_token = token
    self:_beginParaWait("正在获取段评…（点按取消）", token, function()
        self._para_request_token = nil
        self:_endParaWait()
        AsyncParaReview:cancel("comments", "user")
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
            UIManager:show(Notification:new{ text = "段评获取失败：" .. tostring(err or "未知错误") })
            return
        end
        -- 续拉是「给屏幕上这个弹窗补货」：弹窗已经不在了（读者切页 / 关掉了）
        -- 就别把它重新弹出来，否则等于在别处凭空跳出一个窗口。
        if cursor and not ReviewPopup.isShowing() then return end
        -- 子进程选中的镜像要同步回父进程，否则下一次请求又会先试失效的那台。
        AsyncParaReview.rememberSourceHost(source, payload.host)
        self:_presentParaComments(paragraph_index, payload, {
            ReviewPopup = ReviewPopup,
            model = model,
            chapter_index = chapter_index,
            known_count = known_count,
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
    -- 引文：优先用服务端回传的段落原文（拿不到就退回本地正文）。
    local quote = Util.trim(tostring(remote_text ~= "" and remote_text or local_text))

    local items = {}
    for _, item in ipairs(list) do
        local text = Util.trim(tostring(item.text or ""))
        if text ~= "" then
            items[#items + 1] = {
                abstract = quote,
                author = tostring(item.name or "匿名"),
                content = text,
                likes_count = tonumber(item.likes) or 0,
            }
        end
    end
    if #items == 0 then
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

    ctx.ReviewPopup.show{
        pages = items,
        -- 段标识：区分「同一段继续加载」与「换了新一段」，决定弹窗是否保留滚动位置。
        paragraph_key = tostring(ctx.chapter_index) .. ":" .. tostring(paragraph_index),
        doc_font_name = self.style.body_font,
        doc_font_size = (body_face and body_face.size) or Screen:scaleBySize(20),
        doc_margins = {
            left = (geometry and geometry.left) or Screen:scaleBySize(16),
            right = (geometry and geometry.right) or Screen:scaleBySize(16),
            top = Screen:scaleBySize(8),
            bottom = Screen:scaleBySize(8),
        },
        height_ratio = 0.7,
        contrast = 7,
        tap_to_page = true,
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
        buttons[#buttons + 1] = { {
            text = "第" .. tostring(pid + 1) .. "段 · " .. tostring(count) .. " 条 · " .. label,
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
    local previous_chapter = self.page and self.page.chapter_index
    local chapter_changed = previous_chapter ~= nil and previous_chapter ~= page.chapter_index
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
    -- 「跨章净屏」走 KOReader 自己的全局刷新，不再是一次本地动画：新章第一页
    -- 照常经由 widget 重绘，刷新用整屏 "full"（Screen.refreshFull）。它刻意与
    -- 「动画效果」解耦 —— 「动画效果」只负责同章内的擦除渐显。
    if direction and chapter_changed and self:isChapterCleanEnabled() then
        self:_cancelSwipeRefresh()
        self.menu_visible = false
        self:rebuild("full")
        -- 传 nil widget 的 "full" 入队就是 KOReader 对角线滑动全刷用的那个调用：
        -- 它会把 UIManager.refresh_count 归零，避免周期性提升紧挨着再来一次
        -- 黑闪（成对连闪）。两条入队会合并成同一次整屏刷新。
        if type(UIManager.setDirty) == "function" then
            UIManager:setDirty(nil, "full")
        end
        return true
    end

    if direction and self:isSwipeAnimationEnabled() and self.swipe_refresh then
        self.menu_visible = false
        local target_widget = self:buildReadingPage(page)
        local begin_ok, started, begin_err = pcall(self.swipe_refresh.begin,
            self.swipe_refresh,
            target_widget,
            direction,
            function() self:_finishSwipeSubmission() end,
            {
                page_animation_enabled = self:isSwipeAnimationEnabled(),
            })
        if not begin_ok then
            begin_err = tostring(started)
            started = nil
            logger.warn("Leko transition backend failed; disabling it for this reader:", begin_err)
            pcall(self.swipe_refresh.cancel, self.swipe_refresh)
            self.swipe_refresh = nil
        end
        if not started then
            self:rebuild(refresh_type or "partial")
        end
    else
        if direction and self:isSwipeAnimationEnabled()
                and self.swipe_refresh and self.swipe_refresh:isRunning() then
            self:_cancelSwipeRefresh()
        end
        -- This is the 0.15.44/0.15.39 direct path.  No-animation turns do
        -- not consult, schedule or settle the transition coordinator.
        self:rebuild(refresh_type or "partial")
    end
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
    self:loadPage(self.page.next_position, "partial", SwipeRefresh.FORWARD, generation)
    return true
end

function ReaderView:_showPreviousPage(target_position, refresh_type, generation)
    if generation and not self:isPageGenerationCurrent(generation) then return false end
    local page, err = Paginator:findPreviousPage(self.book, target_position, self.style)
    if not page then return nil, tostring(err or "已经是第一页") end
    self.menu_visible = false
    return self:setPage(page, refresh_type or "partial", SwipeRefresh.BACKWARD, generation)
end

function ReaderView:previousPage()
    local target = self.history[#self.history]
    if target then
        local generation = self:_nextPageGeneration()
        self._pending_history = { generation = generation, position = target }
        self:loadPage(target, "partial", SwipeRefresh.BACKWARD, generation)
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
            direction = SwipeRefresh.BACKWARD,
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
    self.history = {}
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
    self:refreshLayoutMenu()
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

function ReaderView:_refreshLayoutToggle(id, text)
    local dialog = self._layout_dialog
    if not dialog then return false end

    -- ButtonDialog exposes the lookup itself on current KOReader releases;
    -- older hosts only expose the child ButtonTable.  Resolve either form so
    -- the callback can repaint the existing row immediately.
    local button
    if type(dialog.getButtonById) == "function" then
        local ok, found = pcall(dialog.getButtonById, dialog, id)
        if ok then button = found end
    end
    if not button then
        local button_table = dialog.buttontable or dialog.button_table
        if button_table and type(button_table.getButtonById) == "function" then
            local ok, found = pcall(button_table.getButtonById, button_table, id)
            if ok then button = found end
        end
    end
    if not button or type(button.setText) ~= "function" then return false end

    local ok = pcall(button.setText, button, text, button.width)
    if not ok then return false end

    -- Button:refresh() invalidates exactly the button's own label region.  It
    -- is important here: rebuilding the whole dialog from inside its click
    -- callback can leave the old button tree painted until a later UI event.
    if type(button.refresh) == "function" then
        local refreshed = pcall(button.refresh, button)
        if refreshed then return true end
    end

    local child = button[1]
    local region = child and child.dimen or button.dimen
    if child and child.dimen and type(UIManager.widgetRepaint) == "function" then
        pcall(UIManager.widgetRepaint, UIManager, child, child.dimen.x, button.dimen.y)
    end
    if region then UIManager:setDirty(nil, "ui", region) end
    return true
end

-- ButtonDialog materializes non-dynamic labels when it is constructed. For
-- layout changes, rebuild the open dialog on the next UI tick so a callback is
-- not rebuilding the dialog tree while that same button is still dispatching.
function ReaderView:refreshLayoutMenu()
    if not self._layout_dialog then return false end
    return UI.defer(self, "layout_menu_refresh", function()
        local dialog = self._layout_dialog
        if self._closing or not dialog then return end
        if type(dialog.reinit) == "function" then
            dialog.buttons = self:makeLayoutMenuButtons()
            dialog:reinit()
            -- ButtonDialog's geometry is recomputed by reinit().  Pass the
            -- concrete region; the callback-form setDirty used by newer
            -- widgets is not understood by every 0.15.x host.
            local region = dialog.movable and dialog.movable.dimen or dialog.dimen
            if region then UIManager:setDirty(dialog, "ui", region) end
            return
        end
        -- Compatibility fallback for an older host without ButtonDialog:reinit.
        self._layout_dialog = nil
        UIManager:close(dialog)
        self:showLayoutMenu()
        self:_scheduleFooterRefresh(true)
    end)
end

function ReaderView:makeLayoutMenuButtons()
    local line_values = { 0.12, 0.20, 0.28, 0.38, 0.50 }
    local line_labels = { "最窄", "窄", "中", "宽", "最宽" }
    local margin_values = ReaderMargins.values
    local margin_labels = ReaderMargins.labels
    local vertical_margin_values = { 6, 12, 18, 24, 30 }
    local vertical_margin_labels = { "最窄", "窄", "中", "宽", "最宽" }
    local paragraph_values = { 0, 6, 10, 16, 24 }
    local paragraph_labels = { "无", "0.25 行", "0.5 行", "0.75 行", "一行" }

    local function cycle(values, current)
        local closest = 1
        current = tonumber(current) or values[1]
        for index, value in ipairs(values) do
            if math.abs(value - current) < math.abs(values[closest] - current) then closest = index end
        end
        return values[(closest % #values) + 1]
    end

    local function choiceLabel(values, labels, current)
        local closest = 1
        current = tonumber(current) or values[1]
        for index, value in ipairs(values) do
            if math.abs(value - current) < math.abs(values[closest] - current) then closest = index end
        end
        return labels[closest]
    end

    -- First-line indent cycles through 关 / 2 字符 / 4 字符. The legacy
    -- boolean true is treated as the 2-character default.
    local function indentLabel(current)
        if current == false then return "关" end
        local count = tonumber(current)
        if count ~= nil and count >= 4 then return "4 字符" end
        return "2 字符"
    end

    local function cycleIndent(current)
        if current == false then return 2 end
        local count = tonumber(current)
        if count ~= nil and count >= 4 then return false end
        return 4
    end

    local function apply(fn)
        self:applyStyleChange(fn)
    end

    local function close()
        local dialog = self._layout_dialog
        if dialog then UIManager:close(dialog) end
        self._layout_dialog = nil
        self:_scheduleFooterRefresh(true)
    end

    local function chooseFont()
        self:showFontSelection()
    end

    -- Prompt for a custom body font size as a number.
    local function promptFontSize()
        self:_settleSwipeRefresh()
        local current = tonumber(self.style.body_font_size) or 27
        local dialog
        dialog = InputDialog:new{
            modal = true,
            title = "设置字号",
            input_hint = "请输入字号（例如 27）",
            input_type = "number",
            text = tostring(current),
            buttons = {
                {
                    { text = "取消", id = "close", callback = function() UIManager:close(dialog) end },
                    { text = "确定", callback = function()
                        local raw = dialog:getInputText()
                        UIManager:close(dialog)
                        local size = tonumber(raw)
                        if not size then
                            UIManager:show(Notification:new{ text = "请输入有效数字" })
                            return
                        end
                        size = math.max(14, math.min(72, math.floor(size)))
                        apply(function(s) s.body_font_size = size end)
                    end },
                },
            },
        }
        UIManager:show(dialog)
        pcall(function() dialog:onShowKeyboard() end)
    end

    -- Row 2 pairs the brightness entry (when the device has a frontlight)
    -- with the night-mode toggle; both affect light/colors together.
    local night_button = {
        text = "夜间模式：" .. (self:isNightMode() and "开" or "关"),
        callback = function() apply(function(s)
            s.night_mode = not (s.night_mode == true)
        end) end,
    }
    local brightness_button
    if self:hasFrontlightControl() then
        brightness_button = {
            text = "屏幕亮度",
            callback = function()
                close()
                UIManager:broadcastEvent(Event:new("ShowFlDialog"))
            end,
        }
    end
    local light_row = brightness_button
        and { brightness_button, night_button }
        or { night_button }

    local buttons = {
        {
            { text = "字体", callback = chooseFont },
            { text = "字号：" .. tostring(self.style.body_font_size or 27), callback = promptFontSize },
        },
        light_row,
        {
            { text = "首行缩进：" .. indentLabel(self.style.indent), callback = function() apply(function(s)
                s.indent = cycleIndent(s.indent)
            end) end },
            { text = "行距：" .. choiceLabel(line_values, line_labels, self.style.line_spacing), callback = function() apply(function(s)
                s.line_spacing = cycle(line_values, s.line_spacing or 0.28)
            end) end },
        },
        {
            { text = "页边距：" .. choiceLabel(margin_values, margin_labels, self.style.margin_left), callback = function() apply(function(s)
                local margin = cycle(margin_values, s.margin_left or 28)
                s.margin_left, s.margin_right = margin, margin
            end) end },
            { text = "段间距：" .. choiceLabel(paragraph_values, paragraph_labels, self.style.paragraph_spacing), callback = function() apply(function(s)
                s.paragraph_spacing = cycle(paragraph_values, s.paragraph_spacing or 10)
            end) end },
        },
        {
            { text = "上边距：" .. choiceLabel(vertical_margin_values, vertical_margin_labels, self.style.margin_top), callback = function() apply(function(s)
                s.margin_top = cycle(vertical_margin_values, s.margin_top or 12)
            end) end },
            { text = "下边距：" .. choiceLabel(vertical_margin_values, vertical_margin_labels, self.style.margin_bottom), callback = function() apply(function(s)
                s.margin_bottom = cycle(vertical_margin_values, s.margin_bottom or 12)
            end) end },
        },
        {
            { text = self.style.show_header and "页眉：显示" or "页眉：隐藏", callback = function() apply(function(s)
                s.show_header = not s.show_header
            end) end },
            { text = self.style.show_footer and "页脚：显示" or "页脚：隐藏", callback = function() apply(function(s)
                s.show_footer = not s.show_footer
            end) end },
        },
        {
            { id = "page_animation_toggle", text = self:isSwipeAnimationEnabled() and "动画效果：开" or "动画效果：关", callback = function()
                self:setSwipeAnimationEnabled(not self:isSwipeAnimationEnabled())
            end },
            { id = "chapter_clean_toggle", text = self:isChapterCleanEnabled() and "跨章净屏：开" or "跨章净屏：关", callback = function()
                self:setChapterCleanEnabled(not self:isChapterCleanEnabled())
            end },
        },
    }
    -- 段评只对支持的平台章节有意义（番茄 / 七猫 / QQ阅读）。不支持的书就不显示
    -- 这一行，免得读者打开开关却什么都看不到。
    local para_chapter_index = self.page and self.page.chapter_index
    if para_chapter_index and ParaComments.isSupported(self.book, para_chapter_index) then
        buttons[#buttons + 1] = {
            { id = "para_review_toggle", text = self:isParaReviewEnabled() and "段评：开" or "段评：关", callback = function()
                self:setParaReviewEnabled(not self:isParaReviewEnabled())
            end },
            { text = "本页段评", callback = function()
                close()
                self:showPageParaCommentList()
            end },
        }
        -- 书山聚合有多台镜像，段评和正文必须落在同一台（原生源自己保证）。
        -- 这里把当前生效的镜像摆出来，方便读者判断「是不是这台取不到数据」。
        buttons[#buttons + 1] = {
            { id = "para_server_button", text = self:_paraServerLabel(), callback = function()
                UIManager:show(Notification:new{ text = "镜像由书山原生源自动轮换" })
            end },
        }
    end
    buttons[#buttons + 1] = { { text = "关闭", callback = close } }
    return buttons
end

function ReaderView:hasFrontlightControl()
    if type(Device.hasFrontlight) ~= "function" then return false end
    local ok, available = pcall(Device.hasFrontlight, Device)
    return ok and available == true
end

function ReaderView:showFontSelection()
    self:_settleSwipeRefresh()
    local dialog = self._layout_dialog
    if dialog then UIManager:close(dialog) end
    self._layout_dialog = nil
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

function ReaderView:showLayoutMenu()
    self:_settleSwipeRefresh()
    if self._layout_dialog then
        if UIManager.isWidgetShown and UIManager:isWidgetShown(self._layout_dialog) then return true end
        self._layout_dialog = nil
        self:_scheduleFooterRefresh(true)
    end
    return UI.showModalLater(self, "layout_menu", function()
        local dialog = ButtonDialog:new{
            title = "阅读设置",
            modal = true,
            rows_per_page = 8,
            buttons = self:makeLayoutMenuButtons(),
            tap_close_callback = function()
                self._layout_dialog = nil
                self:_scheduleFooterRefresh(true)
            end,
        }
        self._layout_dialog = dialog
        return dialog
    end)
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
    -- 与「跨章净屏」同一条路：传 nil widget 的 "full" 就是 KOReader 自己的
    -- 整屏刷新，顺带把 refresh_count 归零，不会紧接着再黑闪一次。
    if type(UIManager.setDirty) == "function" then UIManager:setDirty(nil, "full") end
    return true
end

function ReaderView:onToggleNightMode()
    if self._closing then return false end
    local menu_was_visible = self.menu_visible
    self:applyStyleChange(function(style)
        style.night_mode = not (style.night_mode == true)
    end)
    -- applyStyleChange 是给设置弹窗准备的，会顺手把底部菜单打开；
    -- 遥控器触发时不应该弹出菜单。
    if not menu_was_visible and self.menu_visible then self:toggleMenu(false) end
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
    if self._layout_dialog then UIManager:close(self._layout_dialog); self._layout_dialog = nil end

    BookService:cancelPrefetch(self.book.id)
    BookService:unobservePrefetch(self.book.id, self)
    if self.statistics_bridge then self.statistics_bridge:close() end
    self:onFlushSettings()

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
    self:_endParaWait()
    AsyncParaReview:release()
    self:_cancelSwipeRefresh()
    if self.statistics_bridge then self.statistics_bridge:close() end
    self:onFlushSettings()
end

return ReaderView
