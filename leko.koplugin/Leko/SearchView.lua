local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")

local BookInfoView = require("Leko/BookInfoView")
local BookService = require("Leko/BookService")
local SearchResultFormatter = require("Leko/SearchResultFormatter")
local SearchCandidateContext = require("Leko/SearchCandidateContext")
local SourceSearchController = require("Leko/SourceSearchController")
local StreamingResultList = require("Leko/StreamingResultList")
local UI = require("Leko/UI")

local SearchResults = StreamingResultList:extend{
    max_results = nil,
    immediate_refresh_threshold = 0,
}

function SearchResults:buildItems()
    local items = {}
    local count = #(self.results or {})
    items[#items + 1] = {
        text = "刷新本次搜索",
        refresh_search = true,
        separator = false,
    }
    if self.searching then
        items[#items + 1] = {
            text = self.total_sources > 0
                and SearchResultFormatter:progressText(self.scanned, self.total_sources, count)
                or tostring(self.search_stage or "正在准备书源……"),
            dim = true,
            separator = false,
        }
    end
    for _, result in ipairs(self.results or {}) do
        local formatted = SearchResultFormatter:bookItem(result, { mode = "global" })
        formatted.result = result
        items[#items + 1] = formatted
    end
    if not self.searching and count == 0 then
        items[#items + 1] = {
            text = self.search_stage and self.search_stage ~= "" and self.search_stage or "没有搜索结果",
            dim = true,
        }
    end
    return items
end

function SearchResults:_installMenuCallbacks()
    StreamingResultList._installMenuCallbacks(self)
    local select = self.onMenuSelect
    self.onMenuSelect = function(menu, item)
        if item.refresh_search then
            return menu:requestManualRefresh()
        end
        return select(menu, item)
    end
end

function SearchResults:_sortResultsIfNeeded()
    if not self._results_dirty then return end
    -- Search results are streamed from sources with different latency. Keep
    -- the order in which the user first saw them: sorting by score here made a
    -- late source jump above already visible rows and made the list feel
    -- unstable. Source preference still controls the scan queue, not display
    -- order.
    self._results_dirty = false
end

function SearchResults:_setForegroundLoading(active)
    self.foreground_loading = active == true
    if not self.foreground_loading then
        self:_cancelPendingRefresh()
        self:refreshItems()
    end
end

function SearchResults:refreshItems()
    self:_sortResultsIfNeeded()
    local count = #(self.results or {})
    self.title = "搜索书籍 · " .. tostring(self.keyword or "") .. " · " .. tostring(count) .. " 个结果"
    self.item_table = self:buildItems()
    if not self._initializing_menu and self.updateItems then self:updateItems() end
end

function SearchResults:setSearchProgress(scanned, total, stage, done, details, overflow_count)
    if type(details) ~= "table" then
        details = { discovered_count = details, overflow_count = overflow_count }
    end
    self.scanned = tonumber(scanned or self.scanned or 0) or 0
    self.total_sources = tonumber(total or self.total_sources or 0) or 0
    self.search_stage = stage or self.search_stage
    self.discovered_count = tonumber(details.discovered_count
        or self.discovered_count or #self.results) or #self.results
    self.overflow_count = tonumber(details.overflow_count or self.overflow_count or 0) or 0
    if done then self.searching = false end
    if self.foreground_loading then return end
    local last = tonumber(self._last_progress_paint or -6) or -6
    if done or self.scanned - last >= 6 then
        self._last_progress_paint = self.scanned
        self:refreshItems()
    end
end

function SearchResults:onResultSelected(result)
    return self:openResult(result, false)
end

function SearchResults:onResultHeld(result)
    return self:showSourceResultActions(result, {
        primary_text = "查看书籍详情",
        primary_callback = function(candidate) self:openResult(candidate, true) end,
        on_toggled = function(candidate, enabled)
            if self.onSourceToggled then self.onSourceToggled(candidate, enabled) end
        end,
        on_priority_changed = function(candidate)
            if self.onSourcePriorityChanged then self.onSourcePriorityChanged(candidate) end
        end,
    })
end

function SearchResults:openResult(result, show_details)
    -- Details are an in-memory projection. Network/TOC/chapter work belongs to
    -- ReadingCoordinator and never to the list row callback.
    if self.foreground_loading then return true end
    self._book_operation_generation = (tonumber(self._book_operation_generation or 0) or 0) + 1
    local generation = self._book_operation_generation
    local function isCurrent()
        return generation == self._book_operation_generation
    end
    self.opening_result = show_details and nil or result
    self:_setForegroundLoading(true)
    -- Paint the selected row before process cleanup or network work begins.
    -- The real cancellable progress layer follows on the next UI turn.
    if not show_details then self:refreshItems() end
    return UI.defer(self, "open_result", function()
        if not isCurrent() then return end
        local resolved_result, context_err = SearchCandidateContext:hydrate(result)
        if not resolved_result then
            self.opening_result = nil
            self:_setForegroundLoading(false)
            UIManager:show(InfoMessage:new{ text = "无法恢复这条搜索结果：\n" .. tostring(context_err) })
            return
        end
        local book, err = BookService:createSearchTrial(resolved_result)
        if not isCurrent() then return end
        if not book then
            self.opening_result = nil
            self:_setForegroundLoading(false)
            UIManager:show(InfoMessage:new{ text = "无法打开这本书：\n" .. tostring(err) })
            return
        end
        if show_details and self.onDetailsOpened then pcall(self.onDetailsOpened, resolved_result, book) end
        if self.onForegroundSuccess then pcall(self.onForegroundSuccess, resolved_result, book, show_details) end
        if show_details then
            UIManager:show(BookInfoView:new{
                book = book,
                defer_cover = true,
                onBeforeEnterReader = function()
                    if self.onBeforeEnterReader then pcall(self.onBeforeEnterReader, result, book) end
                end,
                onDetailsClosed = function()
                    if self.onDetailsClosed then pcall(self.onDetailsClosed, result, book) end
                    self:_setForegroundLoading(false)
                end,
                onHeavyTaskStart = function(kind)
                    if self.onHeavyTaskStart then pcall(self.onHeavyTaskStart, kind, result, book) end
                end,
                onHeavyTaskDone = function(kind)
                    if self.onHeavyTaskDone then pcall(self.onHeavyTaskDone, kind, result, book) end
                end,
                onRead = function(target, read_options)
                    if self.onReadBook then
                        read_options = read_options or {}
                        -- Close the detail page when entering the reader, but
                        -- keep this search list as the return route.
                        read_options.return_view = read_options.return_view or self
                        return self.onReadBook(target, read_options)
                    end
                end,
                onBookAdded = function(target)
                    if self.onBookAdded then self.onBookAdded(target) end
                end,
            }, "full")
        elseif self.onReadBook then
            if self.onHeavyTaskStart then pcall(self.onHeavyTaskStart, "opening", result, book) end
            local function restoreSearch(err)
                if not isCurrent() then return end
                self._book_operation_task = nil
                self.opening_result = nil
                self:_setForegroundLoading(false)
                if self.onHeavyTaskDone then pcall(self.onHeavyTaskDone, "opening", result, book) end
                if err then
                    UIManager:show(InfoMessage:new{ text = "无法打开这本书：\n" .. tostring(err) })
                end
            end
            local task = self.onReadBook(book, {
                origin_view = self,
                return_view = self,
                title = "正在打开《" .. tostring(book.title or result.title or "这本书") .. "》",
                cancel_text = "取消打开",
                on_cancel = function() restoreSearch() end,
                on_failure = function(open_err) restoreSearch(open_err) end,
                on_reader_shown = function()
                    if not isCurrent() then return end
                    self._book_operation_task = nil
                    self.opening_result = nil
                    if self.onBeforeEnterReader then pcall(self.onBeforeEnterReader, result, book) end
                    -- Keep arrivals in the existing list while it is covered, but
                    -- do not leave the list's paint gate locked until it returns.
                    self:_setForegroundLoading(false)
                end,
            })
            self._book_operation_task = task
            if not task then restoreSearch(err) end
        else
            self.opening_result = nil
            self:_setForegroundLoading(false)
        end
    end)
end

function SearchResults:cancelBookOperation()
    self._book_operation_generation = (tonumber(self._book_operation_generation or 0) or 0) + 1
    local task = self._book_operation_task
    self._book_operation_task = nil
    if task and type(task.cancel) == "function" then pcall(task.cancel, task) end
    self.opening_result = nil
    if self.foreground_loading then self:_setForegroundLoading(false) end
    -- Incrementing the generation deliberately suppresses the asynchronous
    -- task callback above. Resume the paused shared search explicitly here;
    -- otherwise cancelling an opening attempt leaves new source batches in
    -- memory but never lets the remaining source queue continue.
    if task and self.onHeavyTaskDone then pcall(self.onHeavyTaskDone, "opening") end
    return true
end

function SearchResults:releaseSearchMemory()
    self:releaseResults()
end

function SearchResults:onReaderReturned()
    self.opening_result = nil
    self:_setForegroundLoading(false)
    if self.onResumeAfterReader then pcall(self.onResumeAfterReader) end
    return true
end

local SearchView = { recent_keyword = "" }

-- Kept private-by-convention so the streaming-order contract can be tested
-- without exposing another production entry point.
SearchView._SearchResults = SearchResults

function SearchView:prompt(options)
    if type(options) == "function" then options = { onBookAdded = options } end
    options = options or {}
    return UI.defer(options.owner or self, "search_prompt", function()
        local dialog
        dialog = InputDialog:new{
            input = tostring(self.recent_keyword or ""),
            modal = true,
            title = "搜索网络小说",
            input_hint = "输入书名或作者",
            buttons = {
                {
                    { text = "取消", id = "close", callback = function() UIManager:close(dialog) end },
                    { text = "搜索", callback = function()
                        local keyword = dialog:getInputText()
                        UIManager:close(dialog)
                        UI.defer(self, "execute_search", function() self:search(keyword, options) end)
                    end },
                },
            },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end)
end

function SearchView:search(keyword, options)
    options = options or {}
    keyword = tostring(keyword or "")
    if keyword == "" then return end
    self.recent_keyword = keyword

    NetworkMgr:runWhenConnected(function()
        pcall(BookService.clearTransientMemory, BookService)
        collectgarbage("collect")
        local details_open = false
        local reader_open = false
        local controller = SourceSearchController:new{
            mode = "global",
            keyword = keyword,
            max_results = nil,
            force_refresh = options.force_refresh == true,
        }
        -- `view` must be declared *before* the constructor call.  Lua's scope
        -- for a local starts after its declaration statement, so a closure
        -- created inside the initialiser would capture a global `view` (nil)
        -- instead of this one; every callback below that touches `view` would
        -- then die with "attempt to index global 'view'".  The pcall-wrapped
        -- callbacks hid that (search pause/resume silently stopped working),
        -- while the menu-driven refresh surfaced it as a UI error.
        local view
        view = SearchResults:new{
            keyword = keyword,
            results = {},
            searching = true,
            total_sources = 0,
            search_stage = "优先搜索常用、快速与部分探索书源；搜到即显示",
            onReadBook = options.onReadBook,
            onBookAdded = options.onBookAdded,
            onDetailsOpened = function()
                details_open = true
                controller:pause("书籍详情页已打开")
            end,
            onDetailsClosed = function()
                details_open = false
                if not reader_open and view.searching then controller:resume() end
            end,
            onHeavyTaskStart = function(kind)
                controller:pause(tostring(kind or "前台任务") .. "正在占用前台")
            end,
            onHeavyTaskDone = function()
                if not details_open and not reader_open then controller:resume() end
            end,
            onBeforeEnterReader = function()
                controller:pause("阅读器已打开")
                reader_open = true
                details_open = false
                view.searching = controller:isActive()
                view.search_stage = "试读期间暂停搜索；返回后从原进度继续"
                view:refreshItems()
            end,
            onResumeAfterReader = function()
                reader_open = false
                details_open = false
                view.searching = controller:isActive()
                if view.searching then
                    view.search_stage = "已返回搜索，正在从原进度继续"
                    controller:resume()
                end
                view:refreshItems()
            end,
            onSourceToggled = function(result, enabled)
                if not enabled then
                    controller:cancel()
                    view.searching = false
                    view.search_stage = "已停用“" .. tostring(result.source_name or "此书源") .. "”；本次搜索已停止"
                end
            end,
            onSourcePriorityChanged = function()
                controller:applySourcePreference()
            end,
            onManualRefresh = function()
                -- Register the replacement with the shared catalogue worker
                -- before cancelling the old generation.  If the catalogue is
                -- still being built, its child stays owned and is reused;
                -- refresh never overlaps it with a second child on KT2.
                local previous_controller = controller
                local replacement = SourceSearchController:new{
                    mode = "global",
                    keyword = keyword,
                    max_results = nil,
                    force_refresh = true,
                    view = view,
                }
                controller = replacement
                -- Register a new catalogue waiter before cancelling the old
                -- generation, then retire the old workers before releasing
                -- their visible candidate sidecars.
                replacement:start()
                previous_controller:cancel()
                if view._disposed then replacement:cancel(); return end
                view:releaseResults()
                view._arrival_sequence = 0
                view.discovered_count = 0
                view.overflow_count = 0
                view._last_progress_paint = nil
                view:_initializeResults()
                view.searching = true
                view.scanned = 0
                view.total_sources = 0
                view.search_stage = "正在清除本次缓存并重新搜索"
                view:refreshItems()
            end,
            onCancelSearch = function() controller:cancel() end,
        }
        controller.options.view = view
        UIManager:show(view, "full")
        controller:start()
    end)
end

return SearchView
