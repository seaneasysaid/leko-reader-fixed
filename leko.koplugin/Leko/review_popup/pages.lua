--[[--
Thought popup pagination and page rendering (shared by both popup positions).

The bottom bar (widget.lua) and the centered dialog (center_widget.lua) render
the same review content with the same fonts and size settings; this module
owns the pipeline they share:

  * one-shot pagination of the review blocks (ContentBuilder + Paginator),
    cached in a koreader Cache keyed by (items, font, margins, height_ratio);
  * per-piece glyph bitmaps (piece cache);
  * lazy page bitmaps (page cache), where a page is a y-slice of the flowing
    content, so a single long thought may span several pages.

Widgets ask for page starts with computePages(viewport_h) and render page
bitmaps on demand with renderPage(page_idx, page_starts). The page -> piece
inverted index is rebuilt whenever the page_starts table changes (i.e. when
the viewport height changes), while layout and piece caches are freed only
when the content or geometry key changes.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Cache = require("cache")
local CacheItem = require("cacheitem")
local ContentBuilder = require("Leko/review_popup/content_builder")
local Device = require("device")
local FaceFactory = require("Leko/review_popup/face_factory")
local ImgSize = require("Leko/review_popup/img_size")
local Paginator = require("Leko/review_popup/paginator")
local Screen = Device.screen
local logger = require("logger")

local ok_ReviewPics, ReviewPics = pcall(require, "Leko/ReviewPics")
if not ok_ReviewPics then ReviewPics = nil end
local ok_ImageWidget, ImageWidget = pcall(require, "ui/widget/imagewidget")
if not ok_ImageWidget then ImageWidget = nil end
local ok_RenderImage, RenderImage = pcall(require, "ui/renderimage")
if not ok_RenderImage then RenderImage = nil end

local PAGE_BB_CACHE_MAX = 8
local PIECE_CACHE_MAX = 200
local LAYOUT_CACHE_MAX = 6
local IMG_CACHE_MAX = 12

local PieceItem = CacheItem:extend{}
function PieceItem:onFree()
    if self.bb and self.bb.free then self.bb:free() end
end

local PageItem = CacheItem:extend{}
function PageItem:onFree()
    if self.bb and self.bb.free then self.bb:free() end
end

local LayoutItem = CacheItem:extend{}
function LayoutItem:onFree()
    Paginator.freeTextPieces(self.pieces)
end

local ImgItem = CacheItem:extend{}
function ImgItem:onFree()
    if self.bb and self.bb.free then self.bb:free() end
end

local function newPieceCache()
    return Cache:new{ slots = PIECE_CACHE_MAX, enable_eviction_cb = true }
end

local function newPageCache()
    return Cache:new{ slots = PAGE_BB_CACHE_MAX, enable_eviction_cb = true }
end

local function newLayoutCache()
    return Cache:new{ slots = LAYOUT_CACHE_MAX, enable_eviction_cb = true }
end

local function newImgCache()
    return Cache:new{ slots = IMG_CACHE_MAX, enable_eviction_cb = true }
end

local function itemsKey(items)
    local parts = {}
    for _, item in ipairs(items or {}) do
        -- 缓存键必须纳入图片与回复状态：否则图下完了 / 回复展开了，items 的
        -- 文字字段没变，布局缓存命中旧的 → 图片和回复永远不显示。
        local pic_sig = {}
        for _, p in ipairs(type(item.pics) == "table" and item.pics or {}) do
            pic_sig[#pic_sig + 1] = tostring(p.url or "") .. "x" .. tostring(p.w or 0) .. "x" .. tostring(p.h or 0)
        end
        local reply_sig = {}
        for _, r in ipairs(type(item.replies) == "table" and item.replies or {}) do
            reply_sig[#reply_sig + 1] = tostring(r.text or "") .. ":" .. tostring(r.user_name or "")
        end
        parts[#parts + 1] = string.format("%s|%s|%s|%d|%s|%s|%s|%s|%d",
            tostring(item.abstract or ""),
            tostring(item.author or ""),
            tostring(item.content or ""),
            tonumber(item.likes_count) or 0,
            tostring(item.comment_id or ""),
            table.concat(pic_sig, ","),
            table.concat(reply_sig, ","),
            tostring(item.replies_expanded or false) .. "/" .. tostring(item.replies_loading or false),
            tonumber(item.reply_count) or 0)
    end
    return table.concat(parts, "\n")
end

-- ── 段评配图排版（纯函数，移植自 fanqie.review_popup.pages）─────────────
-- 硬约束：分页阶段绝不读图，只用接口 width/height 定占位比例；真实比例在
-- 绘制时用文件头修正（contain），所以「图下完了」不需要重排，只刷新位图。
-- Sean 定版：竖图高 ≤ 半个内容视口；横图宽 ≤ 半个内容区宽。
local IMG_HALF_H_RATIO = 0.5
local IMG_HALF_W_RATIO = 0.5
local IMG_WIDTH_RATIO = 0.92
local IMG_GRID_COLS = 3

local function singleImageBox(pic, text_w, viewport_h)
    local avail_w = math.floor(text_w * IMG_WIDTH_RATIO)
    if avail_w < 1 then avail_w = 1 end
    local half_h = math.max(1, math.floor((viewport_h or 0) * IMG_HALF_H_RATIO))
    local half_w = math.max(1, math.floor(text_w * IMG_HALF_W_RATIO))
    -- 优先用裁后有效尺寸，否则 800×166 会排成 380×79 矮框，裁完又被压回。
    local pw = tonumber(pic and (pic._cw or pic.w)) or 0
    local ph = tonumber(pic and (pic._ch or pic.h)) or 0
    if pw > 0 and ph > 0 then
        if ph >= pw then
            local h = math.min(half_h, math.floor(avail_w * ph / pw + 0.5))
            h = math.max(1, h)
            local w = math.max(1, math.floor(h * pw / ph + 0.5))
            if w > avail_w then w = avail_w end
            return w, h
        end
        local w = math.min(avail_w, half_w)
        local h = math.max(1, math.floor(w * ph / pw + 0.5))
        if h > half_h then
            h = half_h
            w = math.max(1, math.floor(h * pw / ph + 0.5))
        end
        return w, h
    end
    return math.max(1, math.min(avail_w, half_w)), math.max(1, math.floor(half_h * 0.75))
end

local function gridMetrics(text_w)
    local gap = Screen:scaleBySize(4)
    local avail = math.floor(text_w)
    local cell = math.floor((avail - (IMG_GRID_COLS - 1) * gap) / IMG_GRID_COLS)
    if cell < 1 then cell = 1 end
    return cell, gap
end

--- 一个 image block 的几何：{ cells={{x,y,w,h}}, box_h }。
local function imageLayout(pics, text_w, viewport_h)
    local n = #pics
    if n == 1 then
        local w, h = singleImageBox(pics[1], text_w, viewport_h)
        return { cells = { { x = 0, y = 0, w = w, h = h } }, box_h = h }
    end
    local cell, gap = gridMetrics(text_w)
    local half_h = math.max(1, math.floor((viewport_h or 0) * IMG_HALF_H_RATIO))
    local half_w = math.max(1, math.floor(text_w * IMG_HALF_W_RATIO))
    if cell > half_h then cell = half_h end
    if cell > half_w then cell = half_w end
    local rows = math.ceil(n / IMG_GRID_COLS)
    local cells = {}
    for i = 1, n do
        local r = math.floor((i - 1) / IMG_GRID_COLS)
        local c = (i - 1) % IMG_GRID_COLS
        cells[i] = { x = c * (cell + gap), y = r * (cell + gap), w = cell, h = cell }
    end
    return { cells = cells, box_h = rows * cell + (rows - 1) * gap }
end

--- 图片块的分页边界：单图整块原子边界；网格按行切，行间不留缝。
local function imageBoundaries(lay)
    local cells = lay.cells or {}
    if #cells == 0 then return {} end
    local rows, order = {}, {}
    for i = 1, #cells do
        local c = cells[i]
        local row = rows[c.y]
        if not row then
            rows[c.y] = { top = c.y, bottom = c.y + c.h }
            order[#order + 1] = c.y
        elseif c.y + c.h > row.bottom then
            row.bottom = c.y + c.h
        end
    end
    table.sort(order)
    local out = {}
    for k = 1, #order do
        local next_top = (k < #order) and rows[order[k + 1]].top or lay.box_h
        out[k] = { top = rows[order[k]].top, bottom = next_top }
    end
    return out
end

local function geomKey(doc_font_name, doc_font_size, margins, height_ratio, content_width, contrast, doc_weight, doc_font_index)
    local m = margins or {}
    return string.format("%s|%d|%d_%d_%d_%d|%.4f|%d|%d|%d|%s",
        doc_font_name or "", doc_font_size or 0,
        m.left or 0, m.right or 0, m.top or 0, m.bottom or 0,
        height_ratio or 0.35,
        content_width or 0,
        tonumber(contrast) or 0,
        tonumber(doc_weight) or 0,
        tostring(doc_font_index))
end

local PageRenderer = {}

--- @param opts table { items, doc_font_name, doc_font_size, doc_margins,
---                    height_ratio, content_width? }
--- content_width (optional) is the full inner column width before margins
--- (defaults to the screen width, which is what the bottom popup uses; the
--- centered popup passes its narrower frame width).
function PageRenderer:new(opts)
    opts = opts or {}
    local self_obj = setmetatable({}, { __index = PageRenderer })
    self_obj.items = opts.items or {}
    self_obj.doc_font_name = opts.doc_font_name
    self_obj.doc_font_index = opts.doc_font_index
    self_obj.doc_font_size = opts.doc_font_size or Screen:scaleBySize(18)
    self_obj.doc_margins = opts.doc_margins or {
        left = Screen:scaleBySize(20),
        right = Screen:scaleBySize(20),
        top = Screen:scaleBySize(10),
        bottom = Screen:scaleBySize(10),
    }
    self_obj.height_ratio = opts.height_ratio or 0.35
    self_obj.content_width = opts.content_width
    self_obj.contrast = tonumber(opts.contrast) or 0
    self_obj.doc_weight = tonumber(opts.doc_weight) or 0
    self_obj.skip_quote = opts.skip_quote == true
    self_obj.pic_dir = opts.pic_dir
    self_obj.estimate_viewport_h = opts.estimate_viewport_h
    self_obj._layout_cache = newLayoutCache()
    self_obj._page_bbs = newPageCache()
    self_obj._piece_cache = newPieceCache()
    self_obj._img_bbs = newImgCache()
    self_obj._img_missing = {}
    self_obj._drawn_images = 0
    self_obj._items_key = itemsKey(self_obj.items)
    self_obj._geom_key = geomKey(self_obj.doc_font_name, self_obj.doc_font_size,
        self_obj.doc_margins, self_obj.height_ratio, self_obj.content_width,
        self_obj.contrast, self_obj.doc_weight, self_obj.doc_font_index)
    self_obj._bb_key = self_obj._items_key .. "|" .. self_obj._geom_key
    self_obj._page_pieces = {}
    self_obj._page_pieces_key = nil
    -- Public layout results, refreshed by ensureLayout():
    self_obj.layout = nil
    self_obj.content_h = 0
    self_obj.text_w = 0
    self_obj.boundaries = nil
    return self_obj
end

--- Reload content/geometry; re-layout only when the cache key changed.
--- content_width (optional) is the full inner column width before margins;
--- the centered popup passes its frame width so a width change re-paginates.
--- contrast (optional) shifts every block's gray level; a change re-lays out
--- because the colors are baked into the pieces.
--- doc_weight (optional) body font weight 0-3; a change re-lays out because
--- the embolden strength is baked into the faces.
function PageRenderer:setContent(items, doc_font_name, doc_font_size, doc_margins, height_ratio, content_width, contrast, doc_weight, doc_font_index)
    self.items = items or {}
    if doc_font_name ~= nil then self.doc_font_name = doc_font_name end
    if doc_font_index ~= nil then self.doc_font_index = doc_font_index end
    if doc_font_size ~= nil then self.doc_font_size = doc_font_size end
    if doc_margins ~= nil then self.doc_margins = doc_margins end
    if height_ratio ~= nil then self.height_ratio = height_ratio end
    if content_width ~= nil then self.content_width = content_width end
    if contrast ~= nil then self.contrast = tonumber(contrast) or 0 end
    if doc_weight ~= nil then self.doc_weight = tonumber(doc_weight) or 0 end
    local new_items_key = itemsKey(self.items)
    local new_geom_key = geomKey(self.doc_font_name, self.doc_font_size,
        self.doc_margins, self.height_ratio, self.content_width, self.contrast,
        self.doc_weight, self.doc_font_index)
    local new_bb_key = new_items_key .. "|" .. new_geom_key
    if new_bb_key ~= self._bb_key then
        self._items_key = new_items_key
        self._geom_key = new_geom_key
        self._bb_key = new_bb_key
        self:ensureLayout()
    end
end

function PageRenderer:paginate()
    local t0 = os.clock()
    local blocks = ContentBuilder.build(self.items, { contrast = self.contrast, skip_quote = self.skip_quote })
    -- 分页前先量图：有 expand 黑边的按裁后比例排版，避免排进矮框后被压回。
    for _, block in ipairs(blocks) do
        if block.kind == "image" then self:measurePics(block.pics) end
    end
    local t1 = os.clock()

    local item_width = math.min(math.ceil(self.doc_margins.right * 2 / 5), Screen:scaleBySize(10))
    local inner_w = self.content_width or Screen:getWidth()
    local text_w = inner_w - self.doc_margins.left - self.doc_margins.right - item_width
    if text_w < 10 then text_w = 10 end
    local base_size = math.max(8, math.floor(self.doc_font_size or 0))

    local pieces = {}
    local boundaries = {}
    local y = 0

    local function addTextPiece(variant, text, fg, width, x, keep_next)
        local face = FaceFactory:getFace(self.doc_font_name, base_size, variant,
            self.doc_weight, self.doc_font_index)
        if not face then return false end
        local line_h, extra, baseline = Paginator.textPieceMetrics(face)
        local paginated = Paginator.paginateText(text, face, width)
        local n_lines = paginated.n_lines
        local piece_h = n_lines * line_h + extra
        local piece_y = y
        pieces[#pieces + 1] = {
            kind = "text", variant = variant, text = text, fg = fg,
            face = face, width = width, x = x, y = piece_y,
            n_lines = n_lines, line_h = line_h, piece_h = piece_h,
            baseline = baseline, xtext = paginated.xtext, lines = paginated.lines,
        }
        if keep_next and n_lines >= 1 then
            boundaries[#boundaries + 1] = {
                top = piece_y,
                bottom = piece_y + piece_h,
                keep_next = true,
            }
        else
            for k = 1, n_lines do
                boundaries[#boundaries + 1] = {
                    top = piece_y + (k - 1) * line_h,
                    bottom = piece_y + k * line_h,
                }
            end
        end
        y = y + piece_h
        return true
    end

    for _, block in ipairs(blocks) do
        if block.kind == "separator" then
            -- 分隔线只占位不产生 boundary：分页仍由文字行驱动，页缝落在
            -- 线的留白里视觉无感。piece_h = 线宽，供 renderPage 画矩形。
            y = y + math.floor(base_size * (block.spacing_before or 0) + 0.5)
            local thickness = math.max(1, Screen:scaleBySize(1))
            pieces[#pieces + 1] = {
                kind = "separator",
                fg = block.fg,
                x = 0,
                y = y,
                width = text_w,
                piece_h = thickness,
            }
            y = y + thickness + math.floor(base_size * (block.spacing_after or 0) + 0.5)
        elseif block.kind == "paragraph" then
            y = y + math.floor(base_size * (block.spacing_before or 0) + 0.5)
            -- 回复块缩进：层级 * 约 1.15 个字宽，正文宽度同步收窄。
            -- 逐项对齐 fanqie 原版 pages.lua：1.15×level、封顶 text_w/2、块宽下限 10。
            local level = tonumber(block.indent_level) or 0
            local indent = 0
            if level > 0 then
                indent = math.floor(base_size * 1.15 * level)
                if indent > text_w / 2 then indent = math.floor(text_w / 2) end
            end
            local block_w = text_w - indent
            if block_w < 10 then block_w = 10 end
            local before = #pieces
            addTextPiece(block.variant, block.text, block.fg, block_w, indent,
                block.variant == "meta" or block.variant == "reply_meta")
            -- 展开/收起/继续加载行的点击命中靠这两个字段；原版同款赋值。
            if #pieces > before then
                local piece = pieces[#pieces]
                piece.action = block.action
                piece.item_index = block.item_index
            end
            y = y + math.floor(base_size * (block.spacing_after or 0) + 0.5)
        elseif block.kind == "image" and type(block.pics) == "table" and #block.pics > 0 then
            y = y + math.floor(base_size * (block.spacing_before or 0) + 0.5)
            -- 二级回复里的图跟着回复一起缩进：1.15×level + 封顶 + 块宽下限，
            -- 与文字块同一套几何（对齐 fanqie 原版 pages.lua）。
            local img_level = tonumber(block.indent_level) or 0
            local indent = 0
            if img_level > 0 then
                indent = math.floor(base_size * 1.15 * img_level)
                if indent > text_w / 2 then indent = math.floor(text_w / 2) end
            end
            local img_w = text_w - indent
            if img_w < 10 then img_w = 10 end
            local lay = imageLayout(block.pics, img_w, self.estimate_viewport_h)
            local piece_y = y
            pieces[#pieces + 1] = {
                kind = "image",
                pics = block.pics,
                layout = lay,
                item_index = block.item_index,
                x = indent,
                y = piece_y,
                piece_h = lay.box_h,
            }
            -- 图片块必须进 boundary：不进的话末页高度漏算图那一截，图下沿
            -- 永远露不出来（翻页停在图顶）。行与行之间不留缝。
            -- 首行空隙合并（fanqie 原版同款）：图前 spacing_before 留下的空档
            -- 并进上一条 boundary，避免切出只有几像素高的空白占位页。
            for ri, b in ipairs(imageBoundaries(lay)) do
                local top_abs = piece_y + b.top
                if ri == 1 and #boundaries > 0
                    and boundaries[#boundaries].bottom < top_abs then
                    boundaries[#boundaries].bottom = top_abs
                end
                boundaries[#boundaries + 1] = { top = top_abs, bottom = piece_y + b.bottom }
            end
            y = y + lay.box_h + math.floor(base_size * (block.spacing_after or 0) + 0.5)
        end
    end

    local content_h = math.max(1, y)
    local t2 = os.clock()
    logger.info(string.format(
        "thought popup paginated in %.1fms (blocks %.1fms) items=%d content_h=%d",
        (t2 - t0) * 1000, (t1 - t0) * 1000, #self.items, content_h))
    return {
        pieces = pieces,
        boundaries = boundaries,
        content_h = content_h,
        item_count = #self.items,
        text_w = text_w,
    }
end

--- (Re)build the layout: free stale page bitmaps, load the cached layout or
--- paginate. Idempotent; call once after construction / setContent.
function PageRenderer:ensureLayout()
    self:_freePageBBs()
    self:_freePieceCache()
    self._layout_cache = self._layout_cache or newLayoutCache()
    local cached = self._layout_cache:get(self._bb_key)
    if cached then
        self.layout = cached
        self.content_h = cached.content_h
        self.boundaries = cached.boundaries
        self.text_w = cached.text_w
        return
    end
    local layout = LayoutItem:new(self:paginate())
    self._layout_cache:insert(self._bb_key, layout)
    self.layout = layout
    self.content_h = layout.content_h
    self.boundaries = layout.boundaries
    self.text_w = layout.text_w
end

--- Page start list for a viewport height (pure logic, see paginator.lua).
--- Always contains at least { 0 }.
function PageRenderer:computePages(viewport_h)
    return Paginator.computePages(self.boundaries, viewport_h, self.content_h)
end

function PageRenderer:_getPieceTextBB(piece)
    self._piece_cache = self._piece_cache or newPieceCache()
    local cached = self._piece_cache:get(piece)
    if cached then return cached.bb end
    local bb = Paginator.renderTextPiece(piece)
    if not bb then return nil end
    self._piece_cache:insert(piece, PieceItem:new{ bb = bb })
    return bb
end

--- 某张配图的本地缓存路径。没有 pic_dir 说明本次弹窗不带图。
function PageRenderer:_imagePath(pic)
    if not self.pic_dir or not ReviewPics then return nil end
    local name = ReviewPics.filename(pic and pic.url)
    if not name then return nil end
    return self.pic_dir .. "/" .. name
end

--- 颜色是否接近纯黑（兼容 8bpp 灰度与 RGB32 两种位图）。
local function is_black_color(c)
    if not c then return false end
    if c.r ~= nil then
        return c.r < 16 and c.g < 16 and c.b < 16
    end
    return (c.a or 0) < 16
end

--- 检测左右两侧整列纯黑的边条（expand 转码模板补的画布）。
-- 安全阀：对称、各 ≥4px、差 ≤2px、内容 ≥20% 宽，且内容区有非黑像素。
-- ⚠️ 上限必须 >0.35w：800×166 左右各补 280px，0.35w 正好卡在边界上。
local function detect_side_bars_impl(w, h, get_pixel)
    if w < 16 or h < 8 then return 0, 0 end
    local max_cols = math.floor(w * 0.45)
    local step_y = math.max(1, math.floor(h / 32))
    local function run(from_left)
        local n = 0
        for k = 0, max_cols - 1 do
            local x = from_left and k or (w - 1 - k)
            local black = true
            for y = 0, h - 1, step_y do
                if not is_black_color(get_pixel(x, y)) then
                    black = false
                    break
                end
            end
            if not black then break end
            n = n + 1
        end
        return n
    end
    local l = run(true)
    local r = run(false)
    if l < 4 or r < 4 or math.abs(l - r) > 2 then return 0, 0 end
    -- 内容至少保留 20% 宽
    local cw = w - l - r
    if cw < w * 0.2 then return 0, 0 end
    -- 内容区采样列必须有非黑像素：避免把「整张图本身就是黑底」裁空
    local has_content = false
    for k = 0, 7 do
        local x = l + math.floor((cw - 1) * k / 7)
        for y = 0, h - 1, step_y do
            if not is_black_color(get_pixel(x, y)) then
                has_content = true
                break
            end
        end
        if has_content then break end
    end
    if not has_content then return 0, 0 end
    return l, r
end

local function detect_bars_from_bb(bb, w, h)
    return detect_side_bars_impl(w, h, function(x, y)
        return bb:getPixel(x, y)
    end)
end

--- 解码一张本地图，返回裁后有效宽高；解码失败返回 nil。
function PageRenderer:_measureOne(path)
    local ok_src, src = pcall(RenderImage.renderImageFile, RenderImage, path, false)
    if not ok_src or not src then return nil end
    local sw, sh = src:getWidth(), src:getHeight()
    local l, r = detect_bars_from_bb(src, sw, sh)
    if src.free then pcall(src.free, src) end
    if l == 0 and r == 0 then return sw, sh end
    return sw - l - r, sh
end

--- 分页前量图：扣掉 expand 黑边写回 _cw/_ch；没下载的等落盘后再测。
--- @return boolean 有效比例是否变化（调用方需要重排）
function PageRenderer:measurePics(pics)
    if type(pics) ~= "table" or not (ok_RenderImage and RenderImage) then
        return false
    end
    local changed = false
    for _, pic in ipairs(pics) do
        if type(pic) == "table" and pic._cw == nil then
            local path = self:_imagePath(pic)
            if path and ReviewPics and ReviewPics.file_exists(path) then
                local cw, ch = self:_measureOne(path)
                if cw and cw > 0 and ch and ch > 0 then
                    pic._cw, pic._ch = cw, ch
                    local pw = tonumber(pic.w) or 0
                    local ph = tonumber(pic.h) or 0
                    if pw <= 0 or ph <= 0 then
                        changed = true
                    else
                        local old_r, new_r = pw / ph, cw / ch
                        if math.abs(new_r - old_r) > old_r * 0.02 then
                            changed = true
                        end
                    end
                end
            end
        end
    end
    return changed
end

--- 清掉布局缓存并按当前 _cw/_ch 重新分页（图片有效尺寸变化后调用）。
function PageRenderer:invalidateLayout()
    if self._layout_cache and self._layout_cache.clear then
        self._layout_cache:clear()
    else
        self._layout_cache = newLayoutCache()
    end
    self:ensureLayout()
end

--- 解码一张图、等比缩进 box_w × box_h（contain，白底居中），返回整块位图。
--- 返回 nil 表示「还没下 / 解不出来」→ 调用方画占位框。
function PageRenderer:_renderImageBB(pic, box_w, box_h)
    if box_w < 1 or box_h < 1 then return nil end
    local path = self:_imagePath(pic)
    if not path or self._img_missing[path] then return nil end
    if not (ReviewPics and ReviewPics.file_exists(path)) then
        self._img_missing[path] = true
        return nil
    end
    local bbtype = Screen:isColorEnabled() and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8

    -- expand 会在左右补纯黑画布：有黑边就直接裁，不必再算 contain 几何。
    if ok_RenderImage and RenderImage then
        local ok_trim, trimmed = pcall(self._renderTrimmed, self, path, box_w, box_h, bbtype)
        if ok_trim and trimmed then
            self._drawn_images = (self._drawn_images or 0) + 1
            return trimmed
        end
    end

    local dw, dh = ImgSize.probe(path)
    if not (dw and dw > 0 and dh and dh > 0) then
        dw, dh = tonumber(pic.w) or 0, tonumber(pic.h) or 0
    end
    if not (dw > 0 and dh > 0) then dw, dh = box_w, box_h end
    local scale = math.min(box_w / dw, box_h / dh)
    local rw = math.max(1, math.floor(dw * scale + 0.5))
    local rh = math.max(1, math.floor(dh * scale + 0.5))
    local ox = math.max(0, math.floor((box_w - rw) / 2))
    local oy = math.max(0, math.floor((box_h - rh) / 2))

    local bb = Blitbuffer.new(box_w, box_h, bbtype)
    bb:fill(Blitbuffer.COLOR_WHITE)

    local drawn = false
    if ImageWidget then
        drawn = pcall(function()
            local iw = ImageWidget:new{
                file = path, width = rw, height = rh, alpha = true,
                file_do_cache = false,
            }
            iw:paintTo(bb, ox, oy)
            if iw.free then iw:free() end
        end)
    end
    if not drawn and RenderImage then
        local ok_img, img = pcall(RenderImage.renderImageFile, RenderImage, path, false, rw, rh)
        if ok_img and img then
            pcall(function()
                bb:blitFrom(img, ox, oy, 0, 0,
                    math.min(rw, img:getWidth()), math.min(rh, img:getHeight()))
            end)
            if img.free then pcall(img.free, img) end
            drawn = true
        end
    end
    if not drawn then
        bb:free()
        -- 解不出来且文件头也不是图片：这是历史坏缓存（错误页/半截图），
        -- 删掉并清掉 missing 标记，下次布局会重新入队下载。
        if ReviewPics and ReviewPics.file_exists(path)
            and not ReviewPics.looks_like_image(path) then
            pcall(os.remove, path)
            ImgSize.forget(path)
            self._img_missing[path] = nil
        end
        return nil
    end
    self._drawn_images = (self._drawn_images or 0) + 1
    return bb
end

--- 裁掉 expand 左右黑边后再 contain；无黑边返回 nil。
function PageRenderer:_renderTrimmed(path, box_w, box_h, bbtype)
    local src = RenderImage:renderImageFile(path, false)
    if not src then return nil end
    local sw, sh = src:getWidth(), src:getHeight()
    local l, r = detect_bars_from_bb(src, sw, sh)
    if l == 0 and r == 0 then
        src:free()
        return nil
    end

    local cw = sw - l - r
    local scale = math.min(box_w / cw, box_h / sh)
    local tw = math.max(1, math.floor(cw * scale + 0.5))
    local th = math.max(1, math.floor(sh * scale + 0.5))

    -- blitFrom 带源偏移：只把 [l, 0, cw, sh] 这段拷进新缓冲，再整体缩放。
    local crop = Blitbuffer.new(cw, sh, src:getType())
    crop:blitFrom(src, 0, 0, l, 0, cw, sh)
    src:free()
    local scaled = RenderImage:scaleBlitBuffer(crop, tw, th)   -- 默认会 free crop
    if not scaled then return nil end

    local bb = Blitbuffer.new(box_w, box_h, bbtype)
    bb:fill(Blitbuffer.COLOR_WHITE)
    local ox = math.max(0, math.floor((box_w - tw) / 2))
    local oy = math.max(0, math.floor((box_h - th) / 2))
    bb:blitFrom(scaled, ox, oy, 0, 0,
        math.min(tw, scaled:getWidth()), math.min(th, scaled:getHeight()))
    if scaled.free then scaled:free() end
    return bb
end

function PageRenderer:_getImageBB(pic, box_w, box_h)
    if not self.pic_dir then return nil end
    local path = self:_imagePath(pic)
    if not path then return nil end
    local key = path .. "|" .. box_w .. "x" .. box_h
    local hit = self._img_bbs:get(key)
    if hit then return hit.bb end
    local bb = self:_renderImageBB(pic, box_w, box_h)
    if not bb then return nil end
    self._img_bbs:insert(key, ImgItem:new{ bb = bb })
    return bb
end

--- 图片落盘后调用：让下一帧重新判断文件在不在。
function PageRenderer:invalidateImage(url)
    if not ReviewPics then return end
    local name = ReviewPics.filename(url)
    if not name or not self.pic_dir then return end
    self._img_missing[self.pic_dir .. "/" .. name] = nil
    ImgSize.forget(self.pic_dir .. "/" .. name)
end

function PageRenderer:_freePieceCache()
    if self._piece_cache and self._piece_cache.clear then
        self._piece_cache:clear()
    else
        self._piece_cache = newPieceCache()
    end
end

--- Render (and cache) the bitmap of page page_idx within page_starts.
--- page_starts is the page list returned by computePages; the page -> piece
--- index is rebuilt whenever a different page_starts table is passed.
function PageRenderer:renderPage(page_idx, page_starts)
    if self._page_pieces_key ~= page_starts then
        self._page_pieces = Paginator.buildPagePieceIndex(
            self.layout and self.layout.pieces, page_starts, self.content_h)
        self._page_pieces_key = page_starts
    end
    self._page_bbs = self._page_bbs or newPageCache()
    local cached = self._page_bbs:get(page_idx)
    if cached then return cached.bb end
    if not page_starts or page_idx < 1 or page_idx > #page_starts then return nil end
    local p0 = page_starts[page_idx]
    local p1 = page_starts[page_idx + 1] or self.content_h
    local h = math.max(1, p1 - p0)
    local bbtype = Screen:isColorEnabled() and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8
    local bb = Blitbuffer.new(self.text_w, h, bbtype)
    bb:fill(Blitbuffer.COLOR_WHITE)

    for _, piece in ipairs(self._page_pieces[page_idx] or {}) do
        if piece.kind == "separator" then
            -- 分隔线：直接画矩形。它没有 n_lines/line_h，绝不能走
            -- pieceVisibleRange（对这两个字段做算术会崩）。
            local top = math.max(piece.y, p0)
            local bottom = math.min(piece.y + piece.piece_h, p1)
            if bottom > top then
                bb:paintRect(piece.x, top - p0, piece.width, bottom - top, piece.fg)
            end
        elseif piece.kind == "image" then
            -- 图块跨页：相邻页各绘自己那一段（src_y 对得上），滚动拼起来连续。
            local lay = piece.layout
            local ox = piece.x or 0
            if lay and lay.cells then
                for i = 1, #lay.cells do
                    local cell = lay.cells[i]
                    local pic = piece.pics[i]
                    if pic then
                        local cell_top = piece.y + cell.y
                        local top = math.max(cell_top, p0)
                        local bottom = math.min(cell_top + cell.h, p1)
                        if bottom > top then
                            local img_bb = self:_getImageBB(pic, cell.w, cell.h)
                            if img_bb then
                                bb:blitFrom(img_bb, ox + cell.x, top - p0, 0, top - cell_top,
                                    math.min(cell.w, img_bb:getWidth()), bottom - top)
                            else
                                -- 占位框：浅灰底 + 上下细线，让「这里有张图」可感知。
                                bb:paintRect(ox + cell.x, top - p0, cell.w, bottom - top,
                                    Blitbuffer.COLOR_GRAY_E)
                                bb:paintRect(ox + cell.x, top - p0, cell.w, 1, Blitbuffer.COLOR_GRAY_9)
                                if cell.h >= 2 then
                                    bb:paintRect(ox + cell.x, top - p0 + (bottom - top) - 1,
                                        cell.w, 1, Blitbuffer.COLOR_GRAY_9)
                                end
                            end
                        end
                    end
                end
            end
        else
            local r = Paginator.pieceVisibleRange(piece, p0, p1)
            if r and piece.kind == "text" then
                local text_bb = self:_getPieceTextBB(piece)
                if text_bb then
                    bb:blitFrom(text_bb, piece.x, r.dest_y, 0, r.src_y, piece.width, r.src_h)
                else
                    logger.warn("thought popup text render failed:",
                        "y=", piece.y, "n_lines=", piece.n_lines,
                        "text=", tostring(piece.text):sub(1, 40))
                end
            end
        end
    end

    self._page_bbs:insert(page_idx, PageItem:new{ bb = bb })
    return bb
end

function PageRenderer:_freePageBBs()
    if self._page_bbs and self._page_bbs.clear then
        self._page_bbs:clear()
    else
        self._page_bbs = newPageCache()
    end
    self._page_pieces = {}
    self._page_pieces_key = nil
end

--- Drop every cached bitmap and layout (called on document close / position
--- switch); the next use re-paginates from scratch.
function PageRenderer:freeContentCaches()
    self:_freePageBBs()
    self:_freePieceCache()
    if self._img_bbs and self._img_bbs.clear then self._img_bbs:clear() end
    self._img_missing = {}
    if self._layout_cache and self._layout_cache.clear then
        self._layout_cache:clear()
    else
        self._layout_cache = newLayoutCache()
    end
    self.layout = nil
    self.boundaries = nil
end

-- 单测钩子：图片几何是纯函数，暴露给 _smoke_review_pics.js 验证。
PageRenderer._test = {
    singleImageBox = singleImageBox,
    imageLayout = imageLayout,
    imageBoundaries = imageBoundaries,
    itemsKey = itemsKey,
    detect_side_bars = detect_side_bars_impl,
}

return PageRenderer
