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
local ButtonDialog = require("ui/widget/buttondialog")
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

local TOP_BORDER_SIZE = Size.line.thick
local PADDING_TOP = Size.padding.large
local PADDING_BOTTOM = Size.padding.large

local ThoughtPopupWidget = InputContainer:extend{
    items = nil,
    doc_font_name = nil,
    doc_font_size = Screen:scaleBySize(18),
    doc_margins = {
        left = Screen:scaleBySize(20),
        right = Screen:scaleBySize(20),
        top = Screen:scaleBySize(10),
        bottom = Screen:scaleBySize(10),
    },
    height_ratio = 0.70,
    contrast = 9,
    -- When true, tapping the left/right half of the bar pages up/down through
    -- the review list (handled in onTapClose, like the weread centered popup).
    tap_to_page = true,
    close_callback = nil,
    dialog = nil,
    -- Optional Leko navigation: when set, a horizontal swipe calls
    -- para_nav("next") / para_nav("prev") instead of closing. Swiping to
    -- close stays available through tap-outside and the Back key.
    para_nav = nil,
    -- 「继续加载」：段评一条通道最多取 50 条（服务端上限），还有剩余时底部
    -- 挂一个按钮。more_text 是按钮文字（含剩余条数），on_more 是回调。
    more_text = nil,
    on_more = nil,

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
            HoldThought = {
                GestureRange:new{
                    ges = "hold",
                    range = range,
                }
            },
        }
    end

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end

    self._pages = PageRenderer:new{
        items = self.items,
        doc_font_name = self.doc_font_name,
        doc_font_size = self.doc_font_size,
        doc_margins = self.doc_margins,
        height_ratio = self.height_ratio,
        contrast = self.contrast,
    }
    self._pages:ensureLayout()
    self:_buildLayout()
end

function ThoughtPopupWidget:onShow()
    UIManager:setDirty(self, function()
        return "partial", self.container.dimen
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
    if opts.doc_font_size then self.doc_font_size = opts.doc_font_size end
    if opts.doc_margins then self.doc_margins = opts.doc_margins end
    if opts.height_ratio then self.height_ratio = opts.height_ratio end
    if opts.contrast ~= nil then self.contrast = opts.contrast end
    if opts.tap_to_page ~= nil then self.tap_to_page = opts.tap_to_page end
    if opts.dialog then self.dialog = opts.dialog end
    self.close_callback = opts.close_callback
    self.para_nav = opts.para_nav
    -- 与首次构造保持一致：每次都按新段数据覆盖（含 nil）。否则切到「没有更多」
    -- 的段时，旧段残留的 more_text/on_more 会让底部「继续加载」按钮继续显示，
    -- 而且按钮回调仍指向旧段的下一页 cursor（点了拉错段）。
    self.more_text = opts.more_text
    self.on_more = opts.on_more
    self.height_ratio = math.max(0.1, math.min(0.9, self.height_ratio or 0.70))
    self.height = math.floor(Screen:getHeight() * self.height_ratio)

    self._pages:setContent(self.items, self.doc_font_name, self.doc_font_size,
        self.doc_margins, self.height_ratio, nil, self.contrast)
    self:_buildLayout()
    if prev_offset > 0 and self._scroll_container then
        self._scroll_container:_setOffset(prev_offset)
    end
    self._para_key = opts.paragraph_key
end

--- 底部「继续加载（还剩 N 条）」按钮。加载中禁用回调，避免连点打出多次请求。
function ThoughtPopupWidget:_buildMoreButton()
    local widget = self
    return Button:new{
        text = self.more_text or "",
        width = self.width,
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
        -- Tap paging is handled by ThoughtPopupWidget.onTapClose (it owns the
        -- tap gesture, so the ScrollContainer's own TapScrollText would never
        -- fire). Keep it disabled here to avoid a dead gesture registration.
        tap_to_page = false,
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
        vgroup_children[#vgroup_children + 1] = more_button
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
end

function ThoughtPopupWidget:onCloseWidget()
    UIManager:setDirty(self, function()
        return "partial", self.container.dimen
    end)
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
    if ges.pos:notIntersectWith(self.container.dimen) then
        UIManager:close(self)
        return true
    end
    -- Optional tap-to-page: tapping the left/right half of the bar pages
    -- up/down through the review list (same feel as the weread centered popup).
    -- When everything fits on one page, scrollToPage is a no-op.
    if self.tap_to_page then
        local BD = require("ui/bidi")
        local dimen = self.container.dimen
        if BD.flipIfMirroredUILayout(ges.pos.x < dimen.x + dimen.w / 2) then
            self._scroll_container:scrollToPage(-1)
        else
            self._scroll_container:scrollToPage(1)
        end
    end
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

function ThoughtPopupWidget:onHoldThought(_, ges)
    local scroll = self._scroll_container
    if scroll and scroll.dimen and ges.pos:intersectWith(scroll.dimen) then
        local content_y = (ges.pos.y - scroll.dimen.y) + (scroll.scroll_offset or 0)
        local item = self:_findItemAtContentY(content_y)
        if item then
            self:_showThoughtActionMenu(item)
        end
    end
    return true
end

function ThoughtPopupWidget:_findItemAtContentY(y)
    local pieces = self._pages and self._pages.layout and self._pages.layout.pieces
    if not pieces then return nil end
    local item_idx = 0
    for _, piece in ipairs(pieces) do
        if piece.variant == "meta" then
            item_idx = item_idx + 1
        end
        if piece.y and piece.piece_h and piece.y <= y and y < piece.y + piece.piece_h then
            if piece.variant == "quote" then
                return self.items and self.items[1]
            end
            if item_idx >= 1 and self.items and item_idx <= #self.items then
                return self.items[item_idx]
            end
            return nil
        end
    end
    return nil
end

function ThoughtPopupWidget:_showThoughtActionMenu(item)
    local popup = self
    local action_dialog
    action_dialog = ButtonDialog:new{
        buttons = {
            {
                {
                    text = _("Copy"),
                    callback = function()
                        UIManager:close(action_dialog)
                        popup:_copyThoughtContent(item)
                    end,
                },
                {
                    text = _("Generate QR code"),
                    callback = function()
                        UIManager:close(action_dialog)
                        popup:_generateQRCode(item)
                    end,
                },
            },
        },
    }
    UIManager:show(action_dialog)
end

function ThoughtPopupWidget:_copyThoughtContent(item)
    local text = tostring(item and item.content or "")
    if text == "" then return end
    if Device.hasClipboard and Device:hasClipboard() then
        Device.input.setClipboardText(text)
    end
end

function ThoughtPopupWidget:_generateQRCode(item)
    local text = tostring(item and item.content or "")
    if text == "" then return end
    if Device.hasClipboard and Device:hasClipboard() then
        Device.input.setClipboardText(text)
    end
    local QRMessage = require("ui/widget/qrmessage")
    UIManager:show(QRMessage:new{
        text = text,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    })
end

function ThoughtPopupWidget:free(full)
    WidgetContainer.free(self, full)
end

function ThoughtPopupWidget:_freeContentCaches()
    self._pages:freeContentCaches()
end

return ThoughtPopupWidget
