local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local Screen = Device.screen

local BookService = require("Leko/BookService")
local Storage = require("Leko/Storage")
local UI = require("Leko/UI")

-- 弱化色（第二行进度文字用）。Blitbuffer.gray 是 KOReader 核心 API，但个别构建可能缺失，
-- 这里做安全兜底，避免首屏崩溃。
local function dim_color()
    local ok, v = pcall(function() return Blitbuffer.gray(0.5) end)
    if ok and v then return v end
    return Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK
end

-- ---- 封面卡片几何（对齐 weread 新版书架：比例 0.68 / gutter 6 / 阴影 3 / 圆角 5）----

local function shelfSizeScale()
    return Screen:scaleBySize(1000) / 1000
end

local function cellCardMetrics(cell_w, cell_h)
    local size_scale = shelfSizeScale()
    local gutter = math.max(1, math.floor(6 * size_scale))
    local shadow = math.max(1, math.floor(3 * size_scale))
    local title_gap = math.max(1, math.floor(4 * size_scale))
    local title_h = math.max(1, math.floor(22 * size_scale))
    local sub_gap = math.max(1, math.floor(2 * size_scale))
    local sub_h = math.max(1, math.floor(16 * size_scale))
    local border = Size.border.thin
    local max_cw = math.max(1, cell_w - 2 * gutter)
    local max_ch = math.max(1, cell_h - 2 * gutter - title_gap - title_h - sub_gap - sub_h)
    -- weread 封面约为 2:3 竖版，卡片锁定同一比例避免四周留白
    local aspect = 0.68
    local card_w, card_h
    if max_cw / max_ch > aspect then
        card_h = max_ch
        card_w = math.max(1, math.floor(card_h * aspect))
    else
        card_w = max_cw
        card_h = math.max(1, math.floor(card_w / aspect))
    end
    local radius = math.min(math.max(2, math.floor(5 * size_scale)),
        math.floor(math.min(card_w, card_h) / 2))
    return {
        gutter = gutter,
        shadow = shadow,
        title_gap = title_gap,
        title_h = title_h,
        sub_gap = sub_gap,
        sub_h = sub_h,
        border = border,
        card_w = card_w,
        card_h = card_h,
        cover_w = card_w + shadow,
        cover_h = card_h + shadow,
        radius = radius,
    }
end

-- ---- weread 同款圆角封面卡与阴影 ----

local function inside_rounded_rect(px, py, width, height, radius)
    if px < 0 or py < 0 or px >= width or py >= height then return false end
    if radius <= 0 then return true end
    local center_x, center_y
    if px < radius and py < radius then
        center_x, center_y = radius, radius
    elseif px >= width - radius and py < radius then
        center_x, center_y = width - radius - 1, radius
    elseif px < radius and py >= height - radius then
        center_x, center_y = radius, height - radius - 1
    elseif px >= width - radius and py >= height - radius then
        center_x, center_y = width - radius - 1, height - radius - 1
    else
        return true
    end
    local delta_x, delta_y = px - center_x, py - center_y
    return delta_x * delta_x + delta_y * delta_y <= radius * radius
end

local CoverShadow = Widget:extend{
    width = 1,
    height = 1,
    radius = 1,
}

function CoverShadow:init()
    self.width = math.max(1, math.floor(tonumber(self.width) or 1))
    self.height = math.max(1, math.floor(tonumber(self.height) or 1))
    self.radius = math.max(1, math.floor(tonumber(self.radius) or 1))
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function CoverShadow:paintTo(bb, x, y)
    bb:paintRoundedRect(x, y, self.width, self.height, dim_color(), self.radius)
end

-- FrameContainer 不会把子控件裁剪进圆角，这里手动把四角遮回背景色
local RoundedCoverCard = Widget:extend{
    inner = nil,
    width = 1,
    height = 1,
    radius = 0,
    border_size = 0,
    shadow_offset = 0,
    shadow_color = nil,
}

function RoundedCoverCard:init()
    self.width = math.max(1, math.floor(tonumber(self.width) or 1))
    self.height = math.max(1, math.floor(tonumber(self.height) or 1))
    self.radius = math.max(0, math.floor(tonumber(self.radius) or 0))
    self.border_size = math.max(0, math.floor(tonumber(self.border_size) or 0))
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function RoundedCoverCard:free(...)
    if self.inner and self.inner.free then self.inner:free(...) end
end

RoundedCoverCard.onCloseWidget = RoundedCoverCard.free

function RoundedCoverCard:_masked_corner_color(px, py)
    if self.shadow_color
        and inside_rounded_rect(px - self.shadow_offset, py - self.shadow_offset,
            self.width, self.height, self.radius) then
        return self.shadow_color
    end
    return Blitbuffer.COLOR_WHITE
end

function RoundedCoverCard:paintTo(bb, x, y)
    if self.inner then self.inner:paintTo(bb, x + self.border_size, y + self.border_size) end
    local radius = self.radius
    if radius > 0 then
        for dy = 0, radius - 1 do
            for dx = 0, radius - 1 do
                local corners = {
                    { dx, dy },
                    { self.width - 1 - dx, dy },
                    { dx, self.height - 1 - dy },
                    { self.width - 1 - dx, self.height - 1 - dy },
                }
                for _, point in ipairs(corners) do
                    if not inside_rounded_rect(point[1], point[2], self.width, self.height, radius) then
                        bb:paintRect(x + point[1], y + point[2], 1, 1,
                            self:_masked_corner_color(point[1], point[2]))
                    end
                end
            end
        end
    end
    if self.border_size > 0 then
        bb:paintBorder(x, y, self.width, self.height, self.border_size,
            Blitbuffer.COLOR_BLACK, radius, true)
    end
end

-- 固定测量宽度的左对齐文字行（对齐 weread 的 LeftAlignedTitle）
local LeftAlignedText = Widget:extend{
    width = 1,
    height = 1,
    content = nil,
}

function LeftAlignedText:init()
    self.width = math.max(1, math.floor(tonumber(self.width) or 1))
    self.height = math.max(1, math.floor(tonumber(self.height) or 1))
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function LeftAlignedText:paintTo(bb, x, y)
    local content_size = self.content:getSize()
    self.content:paintTo(bb, x, y + math.floor((self.height - content_size.h) / 2))
end

function LeftAlignedText:free(...)
    if self.content and self.content.free then self.content:free(...) end
end

LeftAlignedText.onCloseWidget = LeftAlignedText.free

-- 网格空位格。HorizontalGroup 要求子项实现 getSize()；不能用"空 FrameContainer"占位
-- （其 getSize 会索引 nil 子项直接崩，crash.log: framecontainer.lua:55）。
local BlankCell = Widget:extend{
    width = 1,
    height = 1,
}

function BlankCell:init()
    self.width = math.max(1, math.floor(tonumber(self.width) or 1))
    self.height = math.max(1, math.floor(tonumber(self.height) or 1))
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function BlankCell:getSize()
    return self.dimen
end

function BlankCell:paintTo(bb, x, y)
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
end

-- ---- 书架条目 ----

local BookCell = InputContainer:extend{}

function BookCell:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self[1] = self.content
    self.ges_events = {
        TapBook = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldBook = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function BookCell:onTapBook()
    if self.on_details then self.on_details(self.summary) end
    return true
end

function BookCell:onHoldBook()
    if self.on_details then self.on_details(self.summary) end
    return true
end

local BookshelfView = InputContainer:extend{
    covers_fullscreen = true,
    -- Full-screen application pages must remain non-modal.
    -- KOReader keeps modal windows above ordinary dialogs, which would hide InputDialog/ButtonDialog.
    modal = false,
    page_size = 9,
}

function BookshelfView:init()
    self.page = self.page or 1
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events.Close = { { "Back" }, { "Esc" } }
        self.key_events.OpenMenu = { { "Menu" } }
    end
    self:refresh()
end

function BookshelfView:setUpdateState(state, text, current, total)
    self.update_state = state
    self.update_text = text
    self.update_current = tonumber(current or 0) or 0
    self.update_total = tonumber(total or 0) or 0
    self:rebuild()
end

function BookshelfView:_updateButton()
    local running = self.update_state == "started" or self.update_state == "running"
        or self.update_state == "paused"
    if running then
        local current = math.max(0, self.update_current or 0)
        local total = math.max(current, self.update_total or 0)
        return "检查中 " .. tostring(current) .. "/" .. tostring(total), function()
            return self:onCancelUpdates()
        end
    end
    return "检查更新", function() return self:onCheckUpdates() end
end

-- 网格几何（对齐 weread CoverLayout.calculate：子线性缩放，最多 4 列 3 行）
function BookshelfView:getMetrics()
    local header_h = math.max(54, math.floor(self.dimen.h * 0.075))
    local footer_h = math.max(54, math.floor(self.dimen.h * 0.072))
    local body_h = self.dimen.h - header_h - footer_h
    local width = self.dimen.w
    local card_scale = math.sqrt(shelfSizeScale())
    local min_cell_w = math.max(1, math.ceil(170 * card_scale))
    local min_cell_h = math.max(1, math.ceil(210 * card_scale))
    local columns = math.min(4, math.max(1, math.floor(width / min_cell_w)))
    local rows = math.min(3, math.max(1, math.floor(body_h / min_cell_h)))
    local cell_w = math.max(1, math.floor(width / columns))
    local cell_h = math.max(1, math.floor(body_h / rows))
    return {
        header_h = header_h,
        footer_h = footer_h,
        body_h = body_h,
        columns = columns,
        rows = rows,
        cell_w = cell_w,
        cell_h = cell_h,
    }
end

function BookshelfView:buildCover(summary, width, height, radius, border, shadow)
    local cover_path = BookService:getValidCoverPath(summary)
    local inner_w = math.max(1, width - 2 * border)
    local inner_h = math.max(1, height - 2 * border)
    local inner
    if cover_path then
        inner = ImageWidget:new{
            file = cover_path,
            width = inner_w,
            height = inner_h,
            -- 不设 scale_factor：直接拉伸到目标尺寸（cover 填满，无留白；轻微变形可接受）
            file_do_cache = false,
        }
    else
        inner = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            TextBoxWidget:new{
                text = "无封面",
                width = math.max(1, inner_w - 12),
                alignment = "center",
                face = Font:getFace("smallinfofont", 16),
            },
        }
    end
    return RoundedCoverCard:new{
        inner = inner,
        width = width,
        height = height,
        radius = radius or 0,
        border_size = border or 0,
        shadow_offset = shadow or 0,
        shadow_color = (shadow and shadow > 0) and dim_color() or nil,
    }
end

function BookshelfView:buildBookCell(summary, cell_w, cell_h)
    local m = cellCardMetrics(cell_w, cell_h)
    local cover = OverlapGroup:new{
        dimen = Geom:new{ w = m.cover_w, h = m.cover_h },
    }
    if m.shadow > 0 then
        local shadow = CoverShadow:new{
            width = m.card_w,
            height = m.card_h,
            radius = m.radius,
        }
        shadow.overlap_offset = { m.shadow, m.shadow }
        table.insert(cover, shadow)
    end
    table.insert(cover, self:buildCover(summary, m.card_w, m.card_h, m.radius, m.border, m.shadow))

    -- 第一行：书名，单行展示（超宽截断），左对齐
    local title_widget = TextWidget:new{
        text = summary.title or "未命名",
        face = Font:getFace("cfont", 15),
        max_width = m.cover_w,
    }
    -- 第二行：「已读 x / y」弱化色，保持视觉层级
    local position = summary.position or { chapter = 1 }
    local read = tonumber(position.chapter or 1) or 1
    local total = tonumber(summary.chapter_count or 0) or 0
    local update_count = tonumber(summary.toc_update_count or 0) or 0
    local sub_text = string.format("第 %d/%d 章", read, total)
    if update_count > 0 then
        sub_text = sub_text .. " · 更新 " .. tostring(update_count) .. " 章"
    end
    local sub_widget = TextWidget:new{
        text = sub_text,
        face = Font:getFace("smallinfofont", 13),
        fgcolor = dim_color(),
        max_width = m.cover_w,
    }

    local column = VerticalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = m.cover_w, h = m.cover_h },
            cover,
        },
        VerticalSpan:new{ width = m.title_gap },
        LeftAlignedText:new{ width = m.cover_w, height = m.title_h, content = title_widget },
        VerticalSpan:new{ width = m.sub_gap },
        LeftAlignedText:new{ width = m.cover_w, height = m.sub_h, content = sub_widget },
    }
    local content = FrameContainer:new{
        width = cell_w,
        height = cell_h,
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = cell_h },
            column,
        },
    }
    return BookCell:new{
        width = cell_w,
        height = cell_h,
        summary = summary,
        content = content,
        on_details = function(item)
            if self.onShowBookInfo then self.onShowBookInfo(item.id, self) end
        end,
    }
end

function BookshelfView:rebuild(no_repaint)
    local metrics = self:getMetrics()
    local header_h, footer_h, body_h = metrics.header_h, metrics.footer_h, metrics.body_h
    local width = self.dimen.w
    self.page_size = metrics.columns * metrics.rows
    local total_pages = math.max(1, math.ceil(#self.books / self.page_size))
    if self.page > total_pages then self.page = total_pages end

    local header = UI.header(width, header_h, {
        left_text = "‹ 退出",
        title = "Leko 书架",
        right_text = "≡ 菜单",
        on_left = function() self:onClose() end,
        on_right = function()
            if self.onOpenMainMenu then self.onOpenMainMenu(self) end
        end,
    })

    local body = VerticalGroup:new{}
    if #self.books == 0 then
        table.insert(body, CenterContainer:new{
            dimen = Geom:new{ w = width, h = body_h },
            TextBoxWidget:new{
                text = "书架为空\n\n点击右上角“菜单”，搜索或导入书籍。",
                width = math.floor(width * 0.75),
                face = Font:getFace("cfont", 24),
                alignment = "center",
            },
        })
    else
        local start_index = (self.page - 1) * self.page_size + 1
        for row = 1, metrics.rows do
            local line = HorizontalGroup:new{}
            for col = 1, metrics.columns do
                local summary = self.books[start_index + (row - 1) * metrics.columns + col - 1]
                local cell_content
                if summary then
                    cell_content = self:buildBookCell(summary, metrics.cell_w, metrics.cell_h)
                else
                    cell_content = BlankCell:new{
                        width = metrics.cell_w,
                        height = metrics.cell_h,
                    }
                end
                table.insert(line, cell_content)
            end
            table.insert(body, line)
        end
    end

    local update_text, update_callback = self:_updateButton()
    local footer = UI.footer(width, footer_h, {
        {
            text = "‹ 上一页",
            enabled = self.page > 1,
            callback = function()
                self.page = math.max(1, self.page - 1)
                self:rebuild()
            end,
        },
        { text = update_text, callback = update_callback, bold = self.update_state == "running" },
        { text = string.format("%d / %d", self.page, total_pages), bold = true },
        {
            text = "下一页 ›",
            enabled = self.page < total_pages,
            callback = function()
                self.page = math.min(total_pages, self.page + 1)
                self:rebuild()
            end,
        },
    })

    self[1] = UI.screen(width, self.dimen.h, header, body, footer, header_h, footer_h)
    if not no_repaint then UIManager:setDirty(self, "ui", self.dimen) end
end

function BookshelfView:onCheckUpdates()
    if self.onCheckUpdatesRequested then return self.onCheckUpdatesRequested(self) end
    return true
end

function BookshelfView:onCancelUpdates()
    if self.onCancelUpdatesRequested then return self.onCancelUpdatesRequested(self) end
    return true
end

function BookshelfView:refresh(no_repaint)
    self.books = Storage:listBooks()
    self:rebuild(no_repaint)
end


function BookshelfView:updateBook(book, no_repaint, change)
    if not book or not book.id then return self:refresh(no_repaint) end
    if change and change.cover_changed then BookService:invalidateCoverPath(book.cover_path) end
    local summary = Storage:makeBookSummary(book)
    local found = false
    for index, item in ipairs(self.books or {}) do
        if tostring(item.id) == tostring(book.id) then
            self.books[index] = summary
            found = true
            break
        end
    end
    if not found and Storage:isInLibrary(book.id) then
        table.insert(self.books, summary)
    end
    table.sort(self.books, function(a, b)
        local a_time = tonumber(a.last_read_at or a.updated_at or 0) or 0
        local b_time = tonumber(b.last_read_at or b.updated_at or 0) or 0
        if a_time == b_time then return tostring(a.title) < tostring(b.title) end
        return a_time > b_time
    end)
    self:rebuild(no_repaint)
end

function BookshelfView:onOpenMenu()
    if self.onOpenMainMenu then self.onOpenMainMenu(self) end
    return true
end

function BookshelfView:onClose()
    UIManager:close(self, "full")
    return true
end

return BookshelfView
