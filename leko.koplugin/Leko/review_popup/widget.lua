--[[--
Thought popup widget (bottom position).

Renders review items by shaping each text block with the document font (or a
fallback chain) and paginating once; pages are blitted into a bitmap viewport
that scrolls. Long content scrolls directly, with no button navigation.

Pagination, layout, page and piece caches live in Leko/review_popup/
pages.lua (PageRenderer), shared with the centered popup
(center_widget.lua). This module composes the renderer into the bottom bar:
a solid top border, a scrollable page viewport (scroll_container.lua), and
bottom/tap/Back gestures.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Button = require("ui/widget/button")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local PageRenderer = require("Leko/review_popup/pages")
local ScrollContainer = require("Leko/review_popup/scroll_container")
local Size = require("ui/size")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local PluginUtil = require("Leko/review_popup/i18n")
local _ = PluginUtil.tr

local ok_ReviewPics, ReviewPics = pcall(require, "Leko/ReviewPics")
if not ok_ReviewPics then ReviewPics = nil end

local TOP_BORDER_SIZE = Size.line.thick
local PADDING_TOP = Size.padding.large
local PADDING_BOTTOM = Size.padding.large

local ThoughtPopupWidget = InputContainer:extend{
    items = nil,
    doc_font_name = nil,
    -- 同一字体文件内的字面选择（TTC 等，style.body_font_index）：nil = 默认字面。
    doc_font_index = nil,
    doc_font_size = Screen:scaleBySize(18),
    doc_margins = {
        left = Screen:scaleBySize(20),
        right = Screen:scaleBySize(20),
        top = Screen:scaleBySize(10),
        bottom = Screen:scaleBySize(10),
    },
    height_ratio = 0.70,
    contrast = 9,
    -- 正文字重 0-3（style.body_weight）：弹窗跟随正文加仿粗，见 face_factory。
    doc_font_weight = 0,
    close_callback = nil,
    dialog = nil,
    -- Optional Leko navigation: when set, a horizontal swipe calls
    -- para_nav("next") / para_nav("prev") instead of closing. Swiping to
    -- close stays available through tap-outside and the Back key.
    para_nav = nil,
    -- 「继续加载」：服务端还有余量时底部挂一个按钮，more_text 是按钮文字
    -- （含剩余条数），on_more 是回调。番茄按条数偏移续拉，QQ 按毫秒时间戳
    -- 游标续拉（2026-11-07 接通），七猫一次给全、不挂按钮。
    more_text = nil,
    on_more = nil,
    -- 段评配图：缓存目录 + 下载回调（nil 则纯文字模式）
    pic_dir = nil,
    fetch_pic = nil,
    -- 二级回复数据回调 function(item, cursor, done)。nil 时不显示展开入口的加载态。
    on_replies = nil,

    _pages = nil,
    _scroll_container = nil,
    -- 当前展示的段标识（chapter_index:paragraph_index），用于区分「同一段续拉」
    -- 与「换了新一段」：只有前者才保留滚动位置，后者一律从第一页看起。
    _para_key = nil,

    covers_footer = true,
}

function ThoughtPopupWidget:init()
    self.height_ratio = math.max(0.1, math.min(0.9, self.height_ratio or 0.70))
    self.width = Screen:getWidth()
    self.height = math.floor(Screen:getHeight() * self.height_ratio)

    if Device:isTouchDevice() then
        local range = Geom:new{
            x = 0, y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        }
        self.ges_events = {
            TapClose = {
                GestureRange:new{
                    ges = "tap",
                    range = range,
                }
            },
            SwipeClose = {
                GestureRange:new{
                    ges = "swipe",
                    range = range,
                }
            },
            -- 长按不做任何事（番茄 2.2.0-fixed.6：读评论的手感接近普通正文），
            -- hold 不注册，长按落到阅读器自己的手势里也无副作用。
        }
    end

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end

    -- 图片下载队列状态（常驻，跨布局重建延续；见 _startImageDownloads 注释）。
    self._img_queue = {}
    self._img_inflight = {}
    self._img_running = false
    self._img_gen = 0
    self._img_refresh_pending = false

    self._pages = PageRenderer:new{
        items = self.items,
        doc_font_name = self.doc_font_name,
        doc_font_index = self.doc_font_index,
        doc_font_size = self.doc_font_size,
        doc_margins = self.doc_margins,
        height_ratio = self.height_ratio,
        contrast = self.contrast,
        doc_weight = self.doc_font_weight,
        pic_dir = self.pic_dir,
        estimate_viewport_h = self:_estimateViewportH(),
    }
    self._pages:ensureLayout()
    -- _buildLayout 末尾会调 _startImageDownloads（布局就绪后再拉图）。
    self:_buildLayout()
end

--- 估算内容视口高度（给图片几何用：竖图高不超过半个弹窗）。
--- 这里只估，不依赖最终布局（布局依赖图片几何，避免循环）。
function ThoughtPopupWidget:_estimateViewportH()
    local ratio_h = math.floor(Screen:getHeight() * self.height_ratio)
    local chrome = TOP_BORDER_SIZE + PADDING_TOP + PADDING_BOTTOM
    -- fanqie 原版：按钮高按固定 36+14px 估，不跟字号走（图片几何的视口上限）。
    if self.more_text and self.on_more then
        chrome = chrome + Screen:scaleBySize(36) + Screen:scaleBySize(14)
    end
    return math.max(1, ratio_h - chrome)
end

function ThoughtPopupWidget:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.container.dimen
    end)
end

function ThoughtPopupWidget:_reopen(opts)
    -- 同一段「继续加载」：内容只会在尾部变长，旧滚动位置依然有效，保留它
    -- （否则每点一次都被弹回顶部，得重新往下翻）。换了新一段则一律从第一页
    -- 看起，不继承上一个弹窗滚到一半的位置。
    local same_para = opts.paragraph_key ~= nil and opts.paragraph_key == self._para_key
    local prev_offset = 0
    if same_para then
        prev_offset = self._scroll_container and self._scroll_container.scroll_offset or 0
    end
    self._more_pending = false
    self.items = opts.items or {}
    if opts.doc_font_name then self.doc_font_name = opts.doc_font_name end
    if opts.doc_font_index ~= nil then self.doc_font_index = opts.doc_font_index end
    if opts.doc_font_size then self.doc_font_size = opts.doc_font_size end
    if opts.doc_margins then self.doc_margins = opts.doc_margins end
    if opts.height_ratio then self.height_ratio = opts.height_ratio end
    if opts.contrast ~= nil then self.contrast = opts.contrast end
    if opts.doc_font_weight ~= nil then self.doc_font_weight = opts.doc_font_weight end
    if opts.dialog then self.dialog = opts.dialog end
    self.close_callback = opts.close_callback
    self.para_nav = opts.para_nav
    -- 与首次构造保持一致：每次都按新段数据覆盖（含 nil）。否则切到「没有更多」
    -- 的段时，旧段残留的 more_text/on_more 会让底部「继续加载」按钮继续显示，
    -- 而且按钮回调仍指向旧段的下一页 cursor（点了拉错段）。
    self.more_text = opts.more_text
    self.on_more = opts.on_more
    self.on_replies = opts.on_replies
    if opts.fetch_pic then self.fetch_pic = opts.fetch_pic end
    -- 配图目录换书时作废在跑的队列：旧任务会把图写进旧书目录白耗流量，
    -- 且新目录的 _pendingImageUrls 会被旧 inflight 标记挡住。
    if opts.pic_dir and self.pic_dir and opts.pic_dir ~= self.pic_dir then
        self._img_gen = (self._img_gen or 0) + 1
        self._img_queue = {}
        self._img_inflight = {}
        self._img_running = false
    end
    self.pic_dir = opts.pic_dir or self.pic_dir
    if self._pages then
        self._pages.pic_dir = self.pic_dir
        self._pages.estimate_viewport_h = self:_estimateViewportH()
    end
    self.height_ratio = math.max(0.1, math.min(0.9, self.height_ratio or 0.70))
    self.height = math.floor(Screen:getHeight() * self.height_ratio)

    self._pages:setContent(self.items, self.doc_font_name, self.doc_font_size,
        self.doc_margins, self.height_ratio, nil, self.contrast, self.doc_font_weight,
        self.doc_font_index)
    self:_buildLayout()
    if prev_offset > 0 and self._scroll_container then
        self._scroll_container:_setOffset(prev_offset)
    end
    self._para_key = opts.paragraph_key
end

--- 底部「继续加载（还剩 N 条）」按钮。加载中禁用回调，避免连点打出多次请求。
--- 样式对齐 fanqie 原版 widget.lua：宽度左右各留 12px、按钮文字不加粗。
function ThoughtPopupWidget:_buildMoreButton()
    local widget = self
    return Button:new{
        text = self.more_text or "",
        width = self.width - Screen:scaleBySize(24),
        text_font_bold = false,
        callback = function()
            widget:_onMoreTapped()
        end,
    }
end

function ThoughtPopupWidget:_onMoreTapped()
    if self._more_pending then return end
    self._more_pending = true
    local callback = self.on_more
    if callback then
        callback()
    end
end

-- ── 段评配图：下载队列 / 全屏预览 / 刷新 ──────────────────────────────

--- 本段评里所有还没落盘的配图（去重）。回复里的图也算：展开时它们才进 items，
--- 展开会重建布局再次调用本函数，所以这里按「已拿到的回复」扫一遍即可。
function ThoughtPopupWidget:_pendingImageUrls()
    if not self.pic_dir or not ReviewPics then return {} end
    local seen, out = {}, {}
    local function take(pics)
        if type(pics) ~= "table" then return end
        for _, p in ipairs(pics) do
            local url = p and p.url
            if type(url) == "string" and url ~= "" and not seen[url] then
                seen[url] = true
                local name = ReviewPics.filename(url)
                local path = name and (self.pic_dir .. "/" .. name)
                if path and not ReviewPics.file_exists(path) then
                    out[#out + 1] = { url = url, fetch = p.fetch or url, path = path }
                end
            end
        end
    end
    for _, item in ipairs(self.items or {}) do
        take(item.pics)
        if type(item.replies) == "table" then
            for _, r in ipairs(item.replies) do take(r and r.pics) end
        end
    end
    return out
end

--- 串行下载未缓存的配图。队列常驻（跨布局重建延续），同一 url 永不同时两份：
--- 两个子进程同写一个文件会留下半截图（file_exists 为真 → 永不重下）。
function ThoughtPopupWidget:_startImageDownloads()
    if not self.pic_dir or type(self.fetch_pic) ~= "function" then return end
    self._img_queue = self._img_queue or {}
    self._img_inflight = self._img_inflight or {}
    local added = 0
    for _, job in ipairs(self:_pendingImageUrls()) do
        if not self._img_inflight[job.url] then
            self._img_inflight[job.url] = true
            self._img_queue[#self._img_queue + 1] = job
            added = added + 1
        end
    end
    if self._img_running or #self._img_queue == 0 then return end
    self._img_running = true
    local widget = self
    local gen = self._img_gen or 0
    local function step()
        if gen ~= widget._img_gen then
            widget._img_queue = {}
            widget._img_inflight = {}
            widget._img_running = false
            return
        end
        local job = table.remove(widget._img_queue, 1)
        if not job then widget._img_running = false return end
        local finished = false
        local function done(ok)
            if finished then return end
            finished = true
            widget._img_inflight[job.url] = nil
            if gen ~= widget._img_gen then return end
            if ok then
                widget._pages:invalidateImage(job.url)
                widget:_queueImageRefresh()
            end
            step() -- 一张坏图不挡后面的
        end
        local ok_call = pcall(self.fetch_pic, job.fetch or job.url, job.path, done)
        if not ok_call then
            widget._pages:invalidateImage(job.url)
            done(false)
        end
    end
    step()
end

--- 图片落盘后重画：页面位图里烤的是旧占位框，清掉再让它重绘。
--- 用 "ui" 而非 "partial"：partial 计入 flashing promotion，REAGL 设备上会被
--- 提升成全屏闪白（上方正文像蒙了层白纱）。
function ThoughtPopupWidget:_refreshImageArea()
    if not self._scroll_container then return end
    self._pages:_freePageBBs()
    UIManager:setDirty(self, function()
        return "ui", self._scroll_container.dimen
    end)
end

--- 批量下载时的合并刷新：串行队列每下一张都整页重排太贵，攒到 0.35s 一次。
function ThoughtPopupWidget:_queueImageRefresh()
    if self._img_refresh_pending then return end
    self._img_refresh_pending = true
    local widget = self
    local gen = self._img_gen
    local function flush()
        widget._img_refresh_pending = false
        if gen ~= widget._img_gen then return end
        if widget._scroll_container then widget:_refreshImageArea() end
    end
    local ok = pcall(function() UIManager:scheduleIn(0.35, flush) end)
    if not ok then flush() end
end

--- 命中测试：只找带 action 的行（展开/收起/更多回复）。
function ThoughtPopupWidget:_findActionPieceAtContentY(y)
    local pieces = self._pages and self._pages.layout and self._pages.layout.pieces
    if not pieces then return nil end
    for _, piece in ipairs(pieces) do
        if piece.action and piece.y and piece.piece_h
            and piece.y <= y and y < piece.y + piece.piece_h then
            return piece
        end
    end
    return nil
end

--- 命中测试：图片块。返回 piece（含 layout / pics / x / y）。
function ThoughtPopupWidget:_findImagePieceAtContentXY(x, y)
    local pieces = self._pages and self._pages.layout and self._pages.layout.pieces
    if not pieces then return nil end
    for _, piece in ipairs(pieces) do
        if piece.kind == "image" and piece.layout and piece.layout.cells then
            local rel_x = x - (piece.x or 0)
            local rel_y = y - (piece.y or 0)
            if rel_y >= 0 and rel_y <= piece.piece_h then
                for _, cell in ipairs(piece.layout.cells) do
                    if rel_x >= cell.x and rel_x < cell.x + cell.w
                        and rel_y >= cell.y and rel_y < cell.y + cell.h then
                        return piece
                    end
                end
            end
        end
    end
    return nil
end

--- 点击配图：已缓存 → 全屏 ImageViewer；未缓存 → 就地入队下载；0 字节残骸删掉重下。
function ThoughtPopupWidget:_handleImageAction(piece, content_x, content_y)
    local lay = piece.layout
    if not lay or not lay.cells or not ReviewPics then return end
    local pics = piece.pics or {}
    local rel_x = (content_x or 0) - (piece.x or 0)
    local rel_y = (content_y or 0) - (piece.y or 0)
    local idx = 1
    for i = 1, #lay.cells do
        local cell = lay.cells[i]
        if pics[i] and rel_x >= cell.x and rel_x < cell.x + cell.w
            and rel_y >= cell.y and rel_y < cell.y + cell.h then
            idx = i break
        end
    end
    local pic = pics[idx]
    if not pic then return end
    local name = ReviewPics.filename(pic.url)
    local path = (self.pic_dir and name) and (self.pic_dir .. "/" .. name) or nil
    local function refetch()
        if not (path and type(self.fetch_pic) == "function") then return end
        if self._img_inflight and self._img_inflight[pic.url] then return end
        pcall(self.fetch_pic, pic.fetch or pic.url, path, function(ok)
            if ok then
                self._pages:invalidateImage(pic.url)
                self:_refreshImageArea()
            end
        end)
    end
    -- 0 字节残骸：删掉重下
    if path and ReviewPics.file_exists(path) then
        local f = io.open(path, "rb")
        local size = 0
        if f then size = f:seek("end") or 0 f:close() end
        if size <= 0 then pcall(os.remove, path) refetch() return end
    end
    if not (path and ReviewPics.file_exists(path)) then refetch() return end
    -- ImageViewer 的 image 形参要 BlitBuffer，文件路径必须给 file（给 image=path 会崩）。
    local ok, viewer = pcall(function()
        return require("ui/widget/imageviewer"):new{ file = path, fullscreen = true }
    end)
    if ok and viewer then UIManager:show(viewer) end
end

--- 重新分页并重建布局，保留当前滚动位置。
function ThoughtPopupWidget:_refreshAfterReplyChange()
    local offset = (self._scroll_container and self._scroll_container.scroll_offset) or 0
    self._restore_offset = offset
    self._pages:setContent(self.items, self.doc_font_name, self.doc_font_size,
        self.doc_margins, self.height_ratio, nil, self.contrast, self.doc_font_weight,
        self.doc_font_index)
    self:_buildLayout()
    -- _buildLayout 重建了 scroll 容器（offset 归零）：展开/收起后恢复原位置，
    -- 否则读者正读到一半会被弹回顶部。
    if offset > 0 and self._scroll_container then
        self._scroll_container:_setOffset(offset)
    end
    UIManager:setDirty(self, function()
        return "ui", self.container.dimen
    end)
end

--- 二级回复展开 / 收起 / 加载更多。
function ThoughtPopupWidget:_handleReplyAction(piece)
    local item = self.items and self.items[tonumber(piece.item_index) or 0]
    if not item then return false end
    if piece.action == "toggle_replies" then
        if item.replies_loading then return true end
        if item.replies_expanded then
            item.replies_expanded = false
            self:_refreshAfterReplyChange()
            return true
        end
        if type(item.replies) == "table" and #item.replies > 0 then
            item.replies_expanded = true
            self:_refreshAfterReplyChange()
            return true
        end
        -- 首次展开：先显示「正在加载」再取数（v6 内联数据走 nextTick，很快）。
        item.replies_expanded = true
        item.replies_loading = true
        self:_refreshAfterReplyChange()
        self:_fetchReplies(item, nil)
        return true
    end
    if piece.action == "more_replies" then
        if item.replies_loading then return true end
        item.replies_loading = true
        self:_refreshAfterReplyChange()
        self:_fetchReplies(item, item.replies_cursor)
        return true
    end
    return false
end

function ThoughtPopupWidget:_fetchReplies(item, cursor)
    if type(self.on_replies) ~= "function" then
        item.replies_loading = false
        item.replies_expanded = false
        self:_refreshAfterReplyChange()
        return
    end
    local widget = self
    local function done(ok, result, err)
        item.replies_loading = false
        if ok and type(result) == "table" and type(result.replies) == "table" then
            item.replies = item.replies or {}
            for _, r in ipairs(result.replies) do item.replies[#item.replies + 1] = r end
            item.replies_total = tonumber(result.total) or #item.replies
            item.replies_more = result.has_more == true
            item.replies_cursor = result.cursor
            item.replies_expanded = true
        else
            item.replies_expanded = false
            item.replies_error = tostring(err or result or "未知原因")
        end
        widget:_refreshAfterReplyChange()
    end
    local ok_call = pcall(self.on_replies, item, cursor, done)
    if not ok_call then
        item.replies_loading = false
        item.replies_expanded = false
        self:_refreshAfterReplyChange()
    end
end

function ThoughtPopupWidget:_buildLayout()
    self:clear()

    local item_width = math.min(math.ceil(self.doc_margins.right * 2 / 5), Screen:scaleBySize(10))
    local text_w = self._pages.text_w
    local content_h = self._pages.content_h

    local ratio_h = math.floor(Screen:getHeight() * self.height_ratio)
    -- 「继续加载」按钮占的纵向空间要一起计进去，否则视口会把按钮挤出屏幕。
    local more_button
    local more_h = 0
    if self.on_more and self.more_text and self.more_text ~= "" then
        more_button = self:_buildMoreButton()
        local size = more_button:getSize()
        more_h = math.max(0, math.ceil((size and size.h) or 0))
    end
    -- fanqie 原版：按钮上下各留 4px / 10px VerticalSpan，chrome 再补 14px。
    if more_button then more_h = more_h + Screen:scaleBySize(14) end
    local chrome = TOP_BORDER_SIZE + PADDING_TOP + PADDING_BOTTOM + more_h
    local blank_tolerance = math.ceil((self.doc_font_size or Screen:scaleBySize(18)) * 1.2)

    local viewport_h
    if content_h + chrome <= ratio_h - blank_tolerance then
        viewport_h = content_h
        self.height = content_h + chrome
    else
        viewport_h = ratio_h - chrome
        self.height = ratio_h
    end
    if viewport_h < 1 then viewport_h = 1 end

    local scroll = ScrollContainer:new{
        content_h = content_h,
        viewport_h = viewport_h,
        scrollbar_w = item_width,
        margin_left = self.doc_margins.left,
        text_w = text_w,
        dialog = self,
        boundaries = self._pages.boundaries,
        page_bb_getter = function(page_idx)
            local pages = self._scroll_container and self._scroll_container.pages
            return self._pages:renderPage(page_idx, pages)
        end,
    }
    self._scroll_container = scroll

    local vgroup_children = {
        LineWidget:new{
            dimen = Geom:new{ w = self.width, h = TOP_BORDER_SIZE },
        },
        VerticalSpan:new{ width = PADDING_TOP },
        scroll,
        VerticalSpan:new{ width = PADDING_BOTTOM },
    }
    if more_button then
        -- 与 chrome 里补的 14px 对应（fanqie 原版：4px + 按钮 + 10px）。
        vgroup_children[#vgroup_children + 1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }
        vgroup_children[#vgroup_children + 1] = more_button
        vgroup_children[#vgroup_children + 1] = VerticalSpan:new{ width = Screen:scaleBySize(10) }
    end

    local vgroup = VerticalGroup:new(vgroup_children)

    self.container = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        margin = 0,
        padding = 0,
        vgroup,
    }

    self[1] = BottomContainer:new{
        dimen = Screen:getSize(),
        self.container
    }
    -- 布局重建后（首开 / 展开回复 / 续拉）扫一遍有没有新图要下。
    -- 队列常驻 + inflight 去重，重复调用不会重复下载。
    self:_startImageDownloads()
end

function ThoughtPopupWidget:onCloseWidget()
    -- 关窗即停下载队列：否则关掉后还会把这段的图全部在后台下完，每张还
    -- setDirty 一次已经不在窗口栈上的 widget。切段落走 _reopen 不靠关窗保活。
    self._img_gen = (self._img_gen or 0) + 1
    self._img_queue = {}
    self._img_inflight = {}
    self._img_running = false
    self._img_refresh_pending = false
    -- 有图时全刷：图片是大面积深色块，区域内 full 也擦不干净，关窗后正文
    -- 会留残影 / 发灰。纯文字维持原来的 ui 刷新。
    if (self._pages and self._pages._drawn_images or 0) > 0 then
        UIManager:setDirty("all", "full")
    else
        UIManager:setDirty(self, function()
            return "ui", self.container.dimen
        end)
    end
    if self.close_callback then
        local callback = self.close_callback
        self.close_callback = nil
        callback(self.height)
    end
end

function ThoughtPopupWidget:onClose()
    UIManager:close(self)
    return true
end

function ThoughtPopupWidget:onTapClose(_, ges)
    -- Tap outside the bottom bar closes the popup.
    if not ges.pos:intersectWith(self.container.dimen) then
        UIManager:close(self)
        return true
    end
    -- 图片块 / 回复动作行优先拦截：把屏幕坐标换算成内容坐标（减滚动偏移，
    -- 加当前 scroll_offset），再按 piece 的 y 命中。命中后不再翻页。
    local scroll = self._scroll_container
    if scroll and scroll.dimen and ges.pos:intersectWith(scroll.dimen) then
        local content_x = (ges.pos.x - scroll.dimen.x) - (scroll.margin_left or 0)
        local content_y = (ges.pos.y - scroll.dimen.y) + (scroll.scroll_offset or 0)
        local img_piece = self:_findImagePieceAtContentXY(content_x, content_y)
        if img_piece then
            self:_handleImageAction(img_piece, content_x, content_y)
            return true
        end
        local action_piece = self:_findActionPieceAtContentY(content_y)
        if action_piece and self:_handleReplyAction(action_piece) then
            return true
        end
    end
    -- fanqie 原版点到评论正文不做任何事（不翻页）。翻页只走上下滑/滚动。
    return true
end

function ThoughtPopupWidget:onSwipeClose(_, ges)
    local BD = require("ui/bidi")
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "west" or direction == "east" then
        if self.para_nav then
            -- Leko: horizontal swipe navigates to an adjacent paragraph.
            self.para_nav(direction == "east" and "prev" or "next")
        else
            UIManager:close(self)
        end
        return true
    end
    if ges.pos:intersectWith(self.container.dimen) then
        return true
    end
    return false
end

function ThoughtPopupWidget:free(full)
    WidgetContainer.free(self, full)
end

function ThoughtPopupWidget:_freeContentCaches()
    self._pages:freeContentCaches()
end

return ThoughtPopupWidget
