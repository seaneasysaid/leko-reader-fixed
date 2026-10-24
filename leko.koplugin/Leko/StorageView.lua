local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local AsyncStorageStats = require("Leko/AsyncStorageStats")
local BookService = require("Leko/BookService")
local CoverService = require("Leko/CoverService")
local Diagnostics = require("Leko/Diagnostics")
local MemoryGuard = require("Leko/MemoryGuard")
local Storage = require("Leko/Storage")
local SourceBackupView = require("Leko/SourceBackupView")
local UI = require("Leko/UI")

local StorageView = Menu:extend{
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    title_bar_fm_style = true,
    -- Full-screen application pages must remain non-modal.
    -- KOReader keeps modal windows above ordinary dialogs, which would hide InputDialog/ButtonDialog.
    modal = false,
}

local function sizeLabel(stats, field)
    return stats and Storage:formatBytes(stats[field] or 0) or "正在统计…"
end

local function cleanResult(ok, count, freed, unit)
    unit = unit or "项"
    if count == 0 then return "没有需要清理的内容" end
    local text = "已清理 " .. tostring(count) .. " " .. unit
        .. (freed and freed > 0 and ("，释放 " .. Storage:formatBytes(freed)) or "")
    if not ok then text = text .. "（部分文件未能删除）" end
    return text
end

function StorageView:buildItems(stats)
    stats = stats or Storage:getCachedStorageStats()
    local logs_deletable = stats and math.max(0, (stats.logs or 0) - (stats.logs_keep or 0)) or 0
    local books_total = stats and Storage:formatBytes((stats.books_toc or 0) + (stats.books_chapters or 0))
        or "正在统计…"
    local tidy_total = stats and Storage:formatBytes(logs_deletable + (stats.exports or 0)) or "正在统计…"
    -- The page used to list every cache kind as a top-level row (14 rows, 9 of
    -- them cleanup).  Group by data nature instead: temporary caches, per-book
    -- caches, logs/exports, diagnostics.  Every action still exists, just one
    -- level down; the first row of each cleanup group is the "clear all" path.
    return {
        { text = "存储占用", mandatory = sizeLabel(stats, "total"), action = "stats" },
        { text = "清理临时缓存", mandatory = sizeLabel(stats, "cache") .. " ›", group = "temp",
            sub_item_table = { _group = "temp",
                { text = "全部临时缓存", mandatory = sizeLabel(stats, "cache"), action = "clear_all" },
                { text = "搜索缓存", mandatory = sizeLabel(stats, "cache_search"), action = "clear_search" },
                { text = "详情与目录临时缓存", mandatory = stats and Storage:formatBytes(
                    (stats.cache_bookinfo or 0) + (stats.cache_toc or 0)
                ) or "正在统计…", action = "clear_metadata" },
                { text = "图片缓存", mandatory = sizeLabel(stats, "cache_images"), action = "clear_images" },
                { text = "临时下载", mandatory = sizeLabel(stats, "cache_tmp"), action = "clear_tmp" },
            } },
        { text = "清理书籍缓存", mandatory = books_total .. " ›", group = "books",
            sub_item_table = { _group = "books",
                { text = "目录缓存", mandatory = sizeLabel(stats, "books_toc"), action = "clear_tocs" },
                -- Show the chapters' own size, not the whole books/ directory:
                -- the old label advertised 12 MB while the action freed 58 KB.
                { text = "已下载章节", mandatory = sizeLabel(stats, "books_chapters"), action = "clear_chapters" },
                { text = "目录缓存和已下载章节", mandatory = books_total, action = "clear_books_all" },
            } },
        { text = "清理日志与导出", mandatory = tidy_total .. " ›", group = "tidy",
            sub_item_table = { _group = "tidy",
                { text = "日志文件", mandatory = stats and Storage:formatBytes(logs_deletable)
                    .. (stats.logs_keep and stats.logs_keep > 0 and " · 保留最近错误" or "") or "正在统计…",
                    action = "clear_logs" },
                { text = "导出文件", mandatory = sizeLabel(stats, "exports"), action = "clear_exports" },
            } },
        { text = "书源备份", mandatory = stats and (tostring(stats.backup_count or 0)
            .. " 份 · " .. Storage:formatBytes(stats.sources) .. " ›") or "正在统计…", action = "source_backups" },
        { text = "诊断信息", mandatory = "内存 / 封面 / 错误 ›", group = "diag",
            sub_item_table = { _group = "diag",
                { text = "查看内存占用", mandatory = "当前使用情况", action = "memory" },
                { text = "封面加载状态", mandatory = "查看下载和缓存情况", action = "cover_diag" },
                { text = "最近一次错误", mandatory = "查看出错原因", action = "last_error" },
            } },
    }
end

function StorageView:_applyStats(stats)
    self.item_table_stack = self.item_table_stack or {}
    local stack = self.item_table_stack
    local current_group = self.item_table and self.item_table._group
    local items = self:buildItems(stats)
    self.item_table = items
    if #stack > 0 and current_group then
        -- Stats arrive asynchronously and every cleanup re-queries them.  When
        -- the user is inside a group, rebuild that group's rows in place
        -- instead of bouncing them back to the top level.
        for _, item in ipairs(items) do
            if item.group == current_group and item.sub_item_table then
                items.title = self.title
                stack[#stack] = items
                self:switchItemTable(item.text, item.sub_item_table)
                return
            end
        end
    end
    self:updateItems()
end

function StorageView:refresh(force)
    self:_applyStats(Storage:getCachedStorageStats())
    AsyncStorageStats:start(function(ok, stats)
        if ok and stats and not self._closed then self:_applyStats(stats) end
    end, force == true)
end

function StorageView:init()
    self.title = "Leko · 存储与缓存"
    self.title_bar_left_icon = "home"
    self.onLeftButtonTap = function()
        if self.item_table_stack and #self.item_table_stack > 0 then
            local parent = table.remove(self.item_table_stack)
            self:switchItemTable(parent.title, parent)
            return
        end
        self:onReturn()
    end
    self.item_table = self:buildItems(Storage:getCachedStorageStats())
    self.onMenuSelect = function(menu, item)
        if item.sub_item_table then
            -- Native group navigation: push the current table and switch.
            return Menu.onMenuSelect(menu, item)
        end
        return UI.defer(menu, "storage_" .. tostring(item.action), function()
        if item.action == "memory" then
            local memory = BookService:getMemoryStats()
            local kernel = MemoryGuard:snapshot()
            local available = kernel.available_kb and Storage:formatBytes(kernel.available_kb * 1024) or "不可读取"
            local rss = kernel.rss_kb and Storage:formatBytes(kernel.rss_kb * 1024) or "不可读取"
            local peak = kernel.peak_rss_kb and Storage:formatBytes(kernel.peak_rss_kb * 1024) or "不可读取"
            UIManager:show(InfoMessage:new{
                text = "系统可用内存：" .. available
                    .. "\nKOReader 当前占用：" .. rss
                    .. "\nKOReader 最高占用：" .. peak
                    .. "\n应用脚本占用：" .. Storage:formatBytes(memory.lua_kb * 1024)
                    .. "\nLeko 已打开章节：" .. tostring(memory.cached_models)
                    .. "\n章节文字：" .. Storage:formatBytes(memory.paragraph_bytes)
                    .. "\n书源详细数据：" .. (Storage._source_settings and "已载入" or "已释放")
                    .. "\n封面缩略图：" .. tostring(CoverService:getMemoryStats().entries)
                    .. " 张，估算 " .. Storage:formatBytes(CoverService:getMemoryStats().bytes)
                    .. "\n\n应用脚本占用也包含 KOReader 和其他插件，不全是 Leko 使用的内存。",
            })
            return
        end
        if item.action == "cover_diag" then
            UIManager:show(InfoMessage:new{ text = CoverService:getStatsText() })
            return
        end
        if item.action == "last_error" then
            local detail, path = Diagnostics:readLast()
            UIManager:show(InfoMessage:new{
                text = detail and ("最近一次完整错误：\n\n" .. detail .. "\n文件：" .. tostring(path))
                    or ("尚无已记录错误。\n文件位置：" .. tostring(path)),
            })
            return
        end
        if item.action == "stats" then
            local stats = Storage:getCachedStorageStats()
            if not stats then
                UIManager:show(InfoMessage:new{ text = "正在后台统计存储占用，请稍后再试。" })
                self:refresh(true)
                return
            end
            local size = function(value) return Storage:formatBytes(value or 0) end
            UIManager:show(InfoMessage:new{
                text = "数据目录：\n" .. Storage.root_dir
                    .. "\n\n已下载章节：" .. size(stats.books_chapters)
                    .. "\n目录缓存：" .. size(stats.books_toc)
                    .. "\n书籍信息：" .. size(stats.books_metadata)
                    .. "\n封面：" .. size(stats.covers)
                    .. "\n日志：" .. size(stats.logs)
                    .. (stats.logs_keep and stats.logs_keep > 0
                        and ("（其中 " .. size(stats.logs_keep) .. " 为最近错误记录，会保留）") or "")
                    .. "\n导出文件：" .. size(stats.exports)
                    .. "\n书源备份：" .. size(stats.sources)
                    .. "\n临时缓存：" .. size(stats.cache)
                    .. "\n\n合计：" .. size(stats.total)
                    .. "\n\n清理按「临时缓存 / 书籍缓存 / 日志与导出」分组；"
                    .. "\n临时缓存不碰书架、进度和已下载章节；"
                    .. "\n目录缓存与已下载章节在「清理书籍缓存」里，清理后需联网重新获取。",
            })
            return
        end
        if item.action == "source_backups" then
            UIManager:show(SourceBackupView:new{
                on_changed = function()
                    Storage:clearCachedStorageStats()
                    menu:refresh(true)
                    if menu.on_sources_changed then pcall(menu.on_sources_changed) end
                end,
            }, "full")
            return
        end
        if item.action == "clear_logs" then
            local stats = Storage:getCachedStorageStats()
            local deletable = stats and math.max(0, (stats.logs or 0) - (stats.logs_keep or 0)) or 0
            UIManager:show(ConfirmBox:new{
                text = "清理日志文件（" .. Storage:formatBytes(deletable) .. "）？\n\n"
                    .. "「最近一次错误」记录会保留，导出日志后仍可回看。",
                ok_text = "清理",
                ok_callback = function()
                    local ok, removed, freed = Storage:clearLogs()
                    Storage:clearCachedStorageStats()
                    UIManager:show(Notification:new{ text = cleanResult(ok, removed, freed) })
                    menu:refresh(true)
                end,
            })
            return
        end
        if item.action == "clear_exports" then
            local entries, total = Storage:getExportsInfo()
            UIManager:show(ConfirmBox:new{
                text = "清理导出的书籍文件（" .. tostring(#entries) .. " 本 · "
                    .. Storage:formatBytes(total) .. "）？\n\n"
                    .. "只删除 Leko 导出的文件；导出目录里的其他文档不会被删除。",
                ok_text = "清理",
                ok_callback = function()
                    local ok, removed, freed, failures = Storage:clearExports()
                    Storage:clearCachedStorageStats()
                    local text = cleanResult(ok, removed, freed, "个文件")
                    if failures and failures > 0 then text = text .. "（" .. tostring(failures) .. " 个占用中）" end
                    UIManager:show(Notification:new{ text = text })
                    menu:refresh(true)
                end,
            })
            return
        end
        local kinds
        if item.action == "clear_search" then kinds = { "search" }
        elseif item.action == "clear_metadata" then kinds = { "bookinfo", "toc" }
        elseif item.action == "clear_images" then kinds = { "images" }
        elseif item.action == "clear_tmp" then kinds = { "tmp", "http" }
        elseif item.action == "clear_all" then kinds = false
        elseif item.action == "clear_tocs" then
            local stats = Storage:getCachedStorageStats()
            UIManager:show(ConfirmBox:new{
                text = "清理全部目录缓存（" .. sizeLabel(stats, "books_toc") .. "）？\n\n"
                    .. "阅读进度、书架和已下载章节都会保留。\n"
                    .. "下次打开书籍需要联网重新解析目录，断网时暂时打不开已下载章节的书。",
                ok_text = "清理",
                ok_callback = function()
                    local before = Storage:getPathSize(Storage:getBooksDir())
                    local book_count, files, failures = Storage:clearAllBookTocs()
                    local freed = math.max(0, before - Storage:getPathSize(Storage:getBooksDir()))
                    Storage:clearCachedStorageStats()
                    UIManager:show(Notification:new{ text = "已清理 " .. tostring(book_count)
                        .. " 本书的目录缓存，释放 " .. Storage:formatBytes(freed)
                        .. (failures > 0 and ("，" .. tostring(failures) .. " 个文件失败") or "") })
                    menu:refresh(true)
                end,
            })
            return
        elseif item.action == "clear_books_all" then
            local stats = Storage:getCachedStorageStats()
            local total_label = stats and Storage:formatBytes(
                (stats.books_toc or 0) + (stats.books_chapters or 0)) or "正在统计…"
            UIManager:show(ConfirmBox:new{
                text = "清理全部目录缓存和已下载章节（" .. total_label .. "）？\n\n"
                    .. "书架和阅读进度都会保留。\n"
                    .. "之后打开书籍需要联网重新解析目录并重新下载章节，断网时暂时看不了。",
                ok_text = "清理",
                ok_callback = function()
                    local before = Storage:getPathSize(Storage:getBooksDir())
                    local cancelled = 0
                    for _, id in ipairs(Storage:listBookDataIds()) do
                        if BookService:cancelFullBookCache(id) then cancelled = cancelled + 1 end
                    end
                    local book_count, _, failures = Storage:clearAllBookTocs()
                    Storage:clearAllBookChapters()
                    local freed = math.max(0, before - Storage:getPathSize(Storage:getBooksDir()))
                    CoverService:clearMemory()
                    Storage:clearCachedStorageStats()
                    UIManager:show(Notification:new{ text = "已清理 " .. tostring(book_count)
                        .. " 本书的目录与章节，释放 " .. Storage:formatBytes(freed)
                        .. (failures > 0 and ("，" .. tostring(failures) .. " 个文件失败") or "")
                        .. (cancelled > 0 and ("，停止 " .. tostring(cancelled) .. " 个整本缓存任务") or "") })
                    menu:refresh(true)
                end,
            })
            return
        elseif item.action == "clear_chapters" then
            local stats = Storage:getCachedStorageStats()
            local chapter_label = stats and stats.books_chapters
                and Storage:formatBytes(stats.books_chapters) or sizeLabel(stats, "books")
            UIManager:show(ConfirmBox:new{
                text = "清理全部已下载章节（" .. chapter_label .. "）？\n\n"
                    .. "书架、阅读进度和目录都会保留，重新打开章节时会自动重新下载。正在整本缓存的书籍会被停止。",
                ok_text = "清理",
                ok_callback = function()
                    local cancelled = 0
                    for _, id in ipairs(Storage:listBookDataIds()) do
                        if BookService:cancelFullBookCache(id) then cancelled = cancelled + 1 end
                    end
                    local cleared = Storage:clearAllBookChapters()
                    CoverService:clearMemory()
                    Storage:clearCachedStorageStats()
                    UIManager:show(Notification:new{ text = "已清理 " .. tostring(cleared)
                        .. " 本书的章节" .. (cancelled > 0 and ("，停止 " .. tostring(cancelled) .. " 个整本缓存任务") or "") })
                    menu:refresh(true)
                end,
            })
            return
        else return end

        UIManager:show(ConfirmBox:new{
            text = item.action == "clear_all"
                and "清理全部临时缓存？不会删除已下载章节。"
                or "清理“" .. item.text .. "”？",
            ok_text = "清理",
            ok_callback = function()
                local freed, failed = 0, 0
                local function clear_kind(kind)
                    local before = Storage:getPathSize(Storage:getCacheDir(kind))
                    local ok = Storage:clearCache(kind)
                    freed = freed + before
                    if not ok then failed = failed + 1 end
                end
                if kinds == false then
                    CoverService:clearMemory()
                    clear_kind(nil)
                else
                    for _, kind in ipairs(kinds) do
                        if kind == "images" then CoverService:clearMemory() end
                        clear_kind(kind)
                    end
                end
                Storage:clearCachedStorageStats()
                UIManager:show(Notification:new{
                    text = "缓存已清理" .. (freed > 0 and ("，释放 " .. Storage:formatBytes(freed)) or "")
                        .. (failed > 0 and "（部分文件未能删除）" or ""),
                })
                menu:refresh(true)
            end,
        })
        end)
    end
    self.close_callback = function() UIManager:close(self, "full") end
    Menu.init(self)
    UIManager:nextTick(function()
        if not self._closed then self:refresh(false) end
    end)
end

function StorageView:onReturn()
    self._closed = true
    UIManager:close(self, "full")
    return true
end

return StorageView
