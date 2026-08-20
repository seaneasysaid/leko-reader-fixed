local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Notification = require("ui/widget/notification")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local BookService = require("Leko/BookService")
local FontSelectionView = require("Leko/FontSelectionView")
local Paginator = require("Leko/Paginator")
local Storage = require("Leko/Storage")
local TocView = require("Leko/TocView")
local UI = require("Leko/UI")
local Util = require("Leko/Util")

local ReaderView = InputContainer:extend{
    covers_fullscreen = true,
    -- Full-screen application pages must remain non-modal.
    -- KOReader keeps modal windows above ordinary dialogs, which would hide InputDialog/ButtonDialog.
    modal = false,
}

function ReaderView:init()
    self.style = Storage:getReaderStyle()
    self.history = {}
    self.pages_since_save = 0
    self.last_progress_flush_at = os.time()
    self.menu_visible = false
    self._exit_dialog = nil
    self._layout_dialog = nil
    self._closing = false
    self.prefetch_state = nil
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
        self.key_events.PageForward = { { "Right" }, { "RPgFwd" }, { "PgFwd" } }
        self.key_events.PageBackward = { { "Left" }, { "LPgBack" }, { "PgBack" } }
    end

    BookService:observePrefetch(self.book.id, self, function(state)
        self:onPrefetchProgress(state)
    end)

    local position = Util.positionCopy(self.book.position)
    local page, err = Paginator:makePage(self.book, position, self.style)
    if not page then page = self:errorPage(position, err) end
    self:consumeFontFallbackNotice()
    self:setPage(page, "full")
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

function ReaderView:buildFooterStatus(page, geometry)
    local total_chapters = #(self.book.chapters or {})
    local state = self.prefetch_state
    local text = string.format("第 %d / %d 章", page.chapter_index or 1, total_chapters)
    local percentage = 0
    local show_bar = false

    if state and tonumber(state.total or 0) > 0 then
        local cached = math.max(0, math.min(state.total, tonumber(state.cached or 0) or 0))
        percentage = cached / state.total
        show_bar = true
        if state.status == "downloading" or state.status == "waiting" then
            text = text .. string.format("  ·  邻章缓存 %d/%d", cached, state.total)
        elseif state.status == "partial" then
            text = text .. string.format("  ·  邻章已缓存 %d/%d", cached, state.total)
        else
            text = text .. string.format("  ·  前后邻章已缓存 %d/%d", cached, state.total)
        end
    elseif state and state.status == "end" then
        text = text .. "  ·  无需缓存邻章"
        percentage = 1
        show_bar = true
    end

    local group = HorizontalGroup:new{ align = "center" }
    local bar_width = math.max(Screen:scaleBySize(54), math.floor(geometry.content_width * 0.22))
    local text_width = geometry.content_width - (show_bar and (bar_width + Screen:scaleBySize(10)) or 0)
    table.insert(group, TextWidget:new{
        text = text,
        face = geometry.chrome_face,
        padding = 0,
        max_width = math.max(Screen:scaleBySize(120), text_width),
    })
    if show_bar then
        table.insert(group, HorizontalSpan:new{ width = Screen:scaleBySize(10) })
        table.insert(group, ProgressWidget:new{
            width = bar_width,
            height = math.max(3, Screen:scaleBySize(5)),
            padding = 0,
            margin = 0,
            fillcolor = Blitbuffer.COLOR_BLACK,
            percentage = percentage,
        })
    end
    return CenterContainer:new{
        dimen = Geom:new{ w = geometry.screen_width, h = geometry.footer_height },
        group,
    }
end

function ReaderView:onPrefetchProgress(state)
    self.prefetch_state = state
    if self._closing or self.menu_visible or not self.page or not self.style.show_footer then return end
    if UIManager.isWidgetShown and not UIManager:isWidgetShown(self) then return end
    local geometry = self.page.geometry
    local footer_region = Geom:new{
        x = 0,
        y = geometry.screen_height - geometry.bottom - geometry.footer_height,
        w = geometry.screen_width,
        h = geometry.footer_height + geometry.bottom,
    }
    self:rebuild("fast", footer_region)
end

function ReaderView:buildReadingPage(page)
    local geometry = page.geometry
    local group = VerticalGroup:new{ align = "left" }
    table.insert(group, UI.vspace(geometry.top))

    if page.show_header then
        table.insert(group, CenterContainer:new{
            dimen = Geom:new{ w = geometry.screen_width, h = geometry.header_height },
            TextWidget:new{
                text = page.chapter_title or self.book.title,
                face = geometry.chrome_face,
                padding = 0,
                max_width = geometry.content_width,
            },
        })
    end

    for _, element in ipairs(page.elements) do
        if element.type == "title" then
            table.insert(group, UI.vspace(element.top_gap))
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
                    },
                },
            })
            table.insert(group, UI.vspace(element.bottom_gap))
        elseif element.type == "gap" then
            table.insert(group, UI.vspace(element.height))
        elseif element.type == "line" then
            table.insert(group, HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = geometry.left },
                LeftContainer:new{
                    dimen = Geom:new{ w = geometry.content_width, h = element.height },
                    TextWidget:new{
                        text = element.text,
                        face = geometry.body_face,
                        padding = 0,
                        line_height = self.style.line_spacing or 0.28,
                        lang = "zh-CN",
                        bold = false,
                    },
                },
            })
        end
    end

    local remaining = geometry.content_height - page.used_height
    if remaining > 0 then table.insert(group, UI.vspace(remaining)) end

    -- Keep the reading margin above the status line, so the chapter indicator
    -- itself is flush with the physical bottom edge.
    table.insert(group, UI.vspace(geometry.bottom))
    if self.style.show_footer then
        table.insert(group, self:buildFooterStatus(page, geometry))
    elseif geometry.footer_height > 0 then
        table.insert(group, UI.vspace(geometry.footer_height))
    end

    return FrameContainer:new{
        width = geometry.screen_width,
        height = geometry.screen_height,
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
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
        { text = "排版", callback = function() self:showLayoutMenu() end },
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

function ReaderView:rebuild(refresh_type, refresh_region)
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
    UIManager:setDirty(self, refresh_type or "ui", refresh_region or self.dimen)
end

function ReaderView:setPage(page, refresh_type)
    local previous_chapter = self.page and self.page.chapter_index
    self.page = page
    self.pages_since_save = (self.pages_since_save or 0) + 1
    local now_time = os.time()
    local chapter_changed = previous_chapter ~= nil and previous_chapter ~= page.chapter_index
    local flush_position = chapter_changed or now_time - (self.last_progress_flush_at or 0) >= 60
    BookService:savePosition(self.book, page.start_position, flush_position)
    if flush_position then
        self.pages_since_save = 0
        self.last_progress_flush_at = now_time
        self._last_persisted_position = table.concat({
            tostring(page.start_position.chapter or 1),
            tostring(page.start_position.paragraph or 1),
            tostring(page.start_position.char or 1),
        }, ":")
    end
    self:rebuild(refresh_type or "partial")
    BookService:requestPrefetch(self.book, page.chapter_index, BookService.prefetch_window)
end

function ReaderView:applyPreparedPosition(position, refresh_type)
    local page, err = Paginator:makePage(self.book, position, self.style)
    if not page then return nil, tostring(err or "章节分页失败") end
    self.menu_visible = false
    self:setPage(page, refresh_type)
    return true
end

function ReaderView:loadPage(position, refresh_type)
    local target_chapter = self.book.chapters and self.book.chapters[position.chapter]
    if not target_chapter then
        UIManager:show(Notification:new{ text = "章节不存在" })
        return nil, "章节不存在"
    end
    local on_disk = BookService:isChapterDownloaded(self.book, position.chapter)
    local needs_download = not on_disk and target_chapter.url
    if needs_download then
        if type(self.onPrepareChapter) ~= "function" then
            UIManager:show(Notification:new{ text = "这一章尚未下载，现在无法读取" })
            return nil, "异步章节读取器不可用"
        end
        local task, err = self.onPrepareChapter(self, position, refresh_type)
        if not task and err then UIManager:show(Notification:new{ text = tostring(err) }) end
        return task
    end
    local ok, err = self:applyPreparedPosition(position, refresh_type)
    if not ok then UIManager:show(Notification:new{ text = tostring(err) }) end
    return ok, err
end

function ReaderView:applyTocUpdate(updated_book, change)
    if type(updated_book) ~= "table" then return nil, "目录更新结果无效" end
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
        position.chapter = target_index
        local target = updated_book.chapters and updated_book.chapters[target_index]
        position.chapter_id = target and target.id or nil
        local rebuilt = Paginator:makePage(updated_book, position, self.style)
        if rebuilt then
            self.page = rebuilt
            self:rebuild("ui")
        end
    end
    return true
end

function ReaderView:reloadCurrentChapter()
    if self._closing or type(self.onPrepareChapter) ~= "function" or not self.page then return true end
    local position = Util.positionCopy(self.page.start_position)
    local task, err = self.onPrepareChapter(self, position, "full", {
        force_network = true,
        present = function(reader, updated_book, target_position, refresh_type)
            BookService:clearBookCache(updated_book.id)
            return reader:applyPreparedPosition(target_position, refresh_type)
        end,
    })
    if not task and err then UIManager:show(Notification:new{ text = tostring(err) }) end
    return task or true
end

function ReaderView:nextPage()
    if self.page.at_end then
        if type(self.onRefreshToc) == "function" then
            local task, err = self.onRefreshToc(self, {})
            if not task and err then UIManager:show(Notification:new{ text = tostring(err) }) end
        else
            UIManager:show(Notification:new{ text = "已经是最后一页" })
        end
        return true
    end
    table.insert(self.history, Util.positionCopy(self.page.start_position))
    self:loadPage(self.page.next_position, "partial")
    return true
end

function ReaderView:_showPreviousPage(target_position, refresh_type)
    local page, err = Paginator:findPreviousPage(self.book, target_position, self.style)
    if not page then return nil, tostring(err or "已经是第一页") end
    self.menu_visible = false
    self:setPage(page, refresh_type or "partial")
    return true
end

function ReaderView:previousPage()
    local target = table.remove(self.history)
    if target then self:loadPage(target, "partial"); return true end

    local current = self.page.start_position
    local crosses_chapter = current.paragraph == 1 and current.char == 1 and current.chapter > 1
    local previous_chapter = crosses_chapter and (current.chapter - 1) or nil
    if previous_chapter and not BookService:isChapterDownloaded(self.book, previous_chapter) then
        if type(self.onPrepareChapter) ~= "function" then
            UIManager:show(Notification:new{ text = "上一章尚未下载，现在无法读取" })
            return true
        end
        local task, err = self.onPrepareChapter(self, {
            chapter = previous_chapter, paragraph = 1, char = 1,
        }, "partial", {
            present = function(reader)
                return reader:_showPreviousPage(current, "partial")
            end,
        })
        if not task and err then UIManager:show(Notification:new{ text = tostring(err) }) end
        return true
    end

    local ok, err = self:_showPreviousPage(current, "partial")
    if not ok then UIManager:show(Notification:new{ text = tostring(err) }) end
    return true
end

function ReaderView:jumpToChapter(chapter_index)
    self.history = {}
    self.menu_visible = false
    self:loadPage({ chapter = chapter_index, paragraph = 1, char = 1 }, "full")
end

function ReaderView:jumpChapter(delta)
    local index = math.max(1, math.min(#(self.book.chapters or {}), (self.page.chapter_index or 1) + delta))
    if index == self.page.chapter_index then
        UIManager:show(Notification:new{ text = delta < 0 and "已经是第一章" or "已经是最后一章" })
        return true
    end
    self:jumpToChapter(index)
    return true
end

function ReaderView:showToc()
    self.menu_visible = false
    self:rebuild("ui")
    return UI.showLater(self, "toc", function()
        return TocView:new{
            book = self.book,
            current_chapter = self.page.chapter_index,
            onChapterSelected = function(chapter_index) self:jumpToChapter(chapter_index) end,
        }
    end, "full")
end

function ReaderView:showBookInfo()
    self.menu_visible = false
    self:rebuild("ui")
    return UI.defer(self, "book_info", function()
        if self.onShowBookInfo then self.onShowBookInfo(self.book, self) end
    end)
end

function ReaderView:addToBookshelf()
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
    self.menu_visible = force == nil and not self.menu_visible or force == true
    self:rebuild("ui")
    return true
end

function ReaderView:applyStyleChange(callback)
    callback(self.style)
    self.history = {}
    BookService:clearBookCache(self.book.id)
    local page, err = Paginator:makePage(self.book, self.page.start_position, self.style)
    self:consumeFontFallbackNotice()
    Storage:saveReaderStyle(self.style)
    if not page then UIManager:show(Notification:new{ text = tostring(err) }); return end
    self.page = page
    self.menu_visible = true
    BookService:savePosition(self.book, page.start_position, true)
    self:rebuild("full")
    self:refreshLayoutMenu()
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

-- ButtonDialog materializes button labels when it is constructed. Rebuild the
-- open dialog in place after a style mutation so its controls immediately
-- show the newly applied values without requiring a close/reopen gesture.
function ReaderView:refreshLayoutMenu()
    local dialog = self._layout_dialog
    if not dialog then return false end
    if type(dialog.reinit) == "function" then
        dialog.buttons = self:makeLayoutMenuButtons()
        dialog:reinit()
        UIManager:setDirty(dialog, "ui", dialog.dimen)
        return true
    end
    -- Compatibility fallback for an older host without ButtonDialog:reinit.
    self._layout_dialog = nil
    UIManager:close(dialog)
    return UI.defer(self, "layout_menu_refresh", function()
        if self._closing then return end
        self:showLayoutMenu()
    end)
end

function ReaderView:makeLayoutMenuButtons()
    local line_values = { 0.12, 0.20, 0.28, 0.38, 0.50 }
    local line_labels = { "最窄", "窄", "中", "宽", "最宽" }
    local margin_values = { 12, 20, 28, 36, 48 }
    local margin_labels = { "最窄", "窄", "中", "宽", "最宽" }
    local paragraph_values = { 0, 6, 10, 16, 24 }
    local paragraph_labels = { "无", "0.25 行", "0.5 行", "0.75 行", "一行" }
    local font_values = { 18, 22, 27, 32, 38, 44 }
    local font_labels = { "很小", "小", "中", "大", "很大", "特大" }

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

    local function apply(fn)
        self:applyStyleChange(fn)
    end

    local function close()
        local dialog = self._layout_dialog
        if dialog then UIManager:close(dialog) end
        self._layout_dialog = nil
    end

    local function chooseFont()
        self:showFontSelection()
    end

    return {
        {
            { text = "字体", callback = chooseFont },
            { text = "字号：" .. choiceLabel(font_values, font_labels, self.style.body_font_size), callback = function() apply(function(s)
                s.body_font_size = cycle(font_values, s.body_font_size or 27)
            end) end },
        },
        {
            { text = self.style.indent == false and "首行缩进：关" or "首行缩进：开", callback = function() apply(function(s)
                s.indent = not (s.indent ~= false)
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
            { text = self.style.show_header and "页眉：显示" or "页眉：隐藏", callback = function() apply(function(s)
                s.show_header = not s.show_header
            end) end },
            { text = self.style.show_footer and "页脚：显示" or "页脚：隐藏", callback = function() apply(function(s)
                s.show_footer = not s.show_footer
            end) end },
        },
        { { text = "关闭", callback = close } },
    }
end

function ReaderView:showFontSelection()
    local dialog = self._layout_dialog
    if dialog then UIManager:close(dialog) end
    self._layout_dialog = nil
    return UI.showLater(self, "font_selection", function()
        return FontSelectionView:new{
            style = self.style,
            on_selected = function(selection) self:applyFontSelection(selection) end,
            on_return = function()
                if not self._closing then self:showLayoutMenu() end
            end,
        }
    end, "full")
end

function ReaderView:showLayoutMenu()
    if self._layout_dialog then
        if UIManager.isWidgetShown and UIManager:isWidgetShown(self._layout_dialog) then return true end
        self._layout_dialog = nil
    end
    return UI.showModalLater(self, "layout_menu", function()
        local dialog = ButtonDialog:new{
            title = "排版设置",
            modal = true,
            rows_per_page = 6,
            buttons = self:makeLayoutMenuButtons(),
            tap_close_callback = function() self._layout_dialog = nil end,
        }
        self._layout_dialog = dialog
        return dialog
    end)
end

function ReaderView:routeTap(ges)
    local x = ges and ges.pos and ges.pos.x or self.dimen.w / 2
    if self.menu_visible then return self:toggleMenu(false) end
    if x < self.dimen.w * 0.27 then return self:previousPage() end
    if x > self.dimen.w * 0.73 then return self:nextPage() end
    return self:toggleMenu(true)
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

function ReaderView:onFlushSettings()
    if self.page then
        local pos = self.page.start_position or {}
        local signature = table.concat({
            tostring(pos.chapter or 1), tostring(pos.paragraph or 1), tostring(pos.char or 1),
        }, ":")
        if signature ~= self._last_persisted_position then
            BookService:savePosition(self.book, pos, true)
            self._last_persisted_position = signature
        end
        self.pages_since_save = 0
        self.last_progress_flush_at = os.time()
    end
end

function ReaderView:onSuspend() self:onFlushSettings() end

function ReaderView:closeReaderNow()
    if self._closing then return true end
    self._closing = true
    if self._exit_dialog then UIManager:close(self._exit_dialog); self._exit_dialog = nil end
    if self._layout_dialog then UIManager:close(self._layout_dialog); self._layout_dialog = nil end

    BookService:cancelPrefetch(self.book.id)
    BookService:unobservePrefetch(self.book.id, self)
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
    if self._exit_dialog then
        if UIManager.isWidgetShown and UIManager:isWidgetShown(self._exit_dialog) then return true end
        self._exit_dialog = nil
    end
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
                    end },
                },
            },
            tap_close_callback = function() self._exit_dialog = nil end,
        }
        self._exit_dialog = dialog
        return dialog
    end)
end

function ReaderView:onClose()
    if self.menu_visible then return self:toggleMenu(false) end
    return self:requestExit()
end
ReaderView.onCloseWidget = ReaderView.onFlushSettings

return ReaderView
