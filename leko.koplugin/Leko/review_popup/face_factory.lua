--[[--
段评弹窗字体工厂（Leko 版）。

移植自 weread / 番茄插件的 thought_popup.face_factory。与原版的关键差别：

  * **不依赖 crengine**。原版用 `cre.getFontFaceFilenameAndFaceIndex(字体名)`
    找字体文件，而 leko 根本不是 crengine 文档（自研 Blitbuffer 渲染器），
    没有 cre 引擎可问。leko 的 `style.body_font` 本身就是 KOReader 的字体
    标识（`"cfont"` 这样的别名，或用户选的字体文件路径），所以这里走
    KOReader 自己的解析链：alias -> Font.fontmap -> 文件名 -> FontList 定位
    真实文件。与 `frontend/ui/font.lua` 的 `Font:getFace` 同一套规则。

  * **字号是像素值**。调用方传 `body_face.size`（KOReader 已经按屏幕 DPI
    缩放过的像素字号），因此这里手工搭 FontFaceObj、不再走 `Font:getFace`
    —— 后者会把 size 再缩放一次（原版注释里记的同一个坑）。

  * 回退链、灰阶变体、缓存策略与原版一致。
--]]

local FontList = require("fontlist")
local Freetype = require("ffi/freetype")
local Font = require("ui/font")
local logger = require("logger")

local FaceFactory = {
    initialized = false,
    emoji_path = nil,
    font_paths_cache = {},
    face_cache = {},
    fallback_cache = {}, -- path|size -> FontFaceObj (fallback faces shared across variants)
}

-- Size variants (relative to the base size). quote/meta render one step
-- smaller; meta is the author line.
FaceFactory.VARIANTS = {
    content = 0.9,  -- thought body
    quote   = 0.9,  -- quoted abstract
    meta    = 0.9,  -- author line; keep it as readable as the thought body
}

function FaceFactory:init()
    if self.initialized then return end
    self:findEmojiFont()
    self.initialized = true
end

--- Locate the NotoEmoji font shipped with the plugin (it lives outside
--- KOReader's font scan directories).
function FaceFactory:findEmojiFont()
    if self.emoji_path then return self.emoji_path end

    local ffiutil = require("ffi/util")
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")

    local function resolve(path)
        if not path then return nil end
        if ok_lfs and lfs.attributes(path, "mode") ~= "file" then return nil end
        if ffiutil.realpath then
            return ffiutil.realpath(path) or path
        end
        return path
    end

    local candidates = {
        "plugins/leko.koplugin/fonts/NotoEmoji-Regular.ttf",
    }
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds then
        candidates[#candidates + 1] = DataStorage:getDataDir()
            .. "/plugins/leko.koplugin/fonts/NotoEmoji-Regular.ttf"
    end
    for _, path in ipairs(candidates) do
        local abs = resolve(path)
        if abs then
            self.emoji_path = abs
            logger.info("Leko para popup emoji font:", abs)
            return self.emoji_path
        end
    end

    for _, dir in ipairs({ "/mnt/us/fonts/", "/usr/share/fonts/truetype/" }) do
        local fp = dir .. "NotoEmoji-Regular.ttf"
        if ok_lfs and lfs.attributes(fp, "mode") == "file" then
            self.emoji_path = fp
            return self.emoji_path
        end
    end
    return nil
end

--- 把 KOReader 的字体标识解析成真实字体文件。
---
--- 与 `frontend/ui/font.lua` 的 `Font:getFace` 同一套顺序：别名先过
--- `Font.fontmap`，绝对/相对路径直接用，其余当作文件名在字体目录里找。
--- @param font_name string|nil 例如 "cfont" / "NotoSansCJKsc-Regular.otf" / "/path/x.ttf"
--- @return string|nil 真实文件路径
function FaceFactory:getFontPaths(font_name)
    if not font_name then return {} end
    if self.font_paths_cache[font_name] then
        return self.font_paths_cache[font_name]
    end

    -- 别名先映射成文件名；映射不到就当作文件名/路径试。
    local realname = font_name
    if Font.fontmap and Font.fontmap[font_name] then
        realname = Font.fontmap[font_name]
    end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local path
    if realname:match("^%./") or realname:match("^/") then
        path = realname
        if ok_lfs and lfs.attributes(path, "mode") ~= "file" then path = nil end
    end
    if not path then
        -- FontList.fontdir 优先（KOReader 自带字体目录），再全量扫一遍。
        local candidate = FontList.fontdir and (FontList.fontdir .. "/" .. realname)
        if candidate and ok_lfs and lfs.attributes(candidate, "mode") == "file" then
            path = candidate
        end
    end
    if not path then
        local fonts = FontList:getFontList()
        if fonts then
            for _, fp in ipairs(fonts) do
                if fp:find(realname, 1, true) then
                    path = fp
                    break
                end
            end
        end
    end

    local paths = {}
    if path then
        -- 只有主字体：leko 的字体选择没有独立的 bold/italic 变体，
        -- 引文的斜体在渲染层降级为普通字形（灰阶区分仍然保留）。
        paths[1] = { path = path, bold = false, italic = false }
    end
    self.font_paths_cache[font_name] = paths
    return paths
end

--- Hand-built FontFaceObj (modeled on Font:getAdjustedFace's clone).
--- xtext enumerates fallback fonts through face.getFallbackFont(num); a
--- prefilled fallbacks table short-circuits font.lua's name lookup.
--- Fonts are resolved through fontdir first, then a full FontList scan.
--- Faces are built by hand (not Font:getFace) because Font:getFace rescales
--- the size by DPI again; passing an already-scaled size would render glyphs
--- twice as large.
local function resolveBundledFont(fontname)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local path = FontList.fontdir and (FontList.fontdir .. "/" .. fontname)
    if path and ok_lfs and lfs.attributes(path, "mode") == "file" then
        return path
    end
    local fonts = FontList:getFontList()
    if fonts then
        for _, fp in ipairs(fonts) do
            if fp:find(fontname, 1, true) then
                return fp
            end
        end
    end
    return nil
end

function FaceFactory:_buildFace(path, size)
    if not path or not size or size <= 0 then return nil end
    local ok, ftsize = pcall(Freetype.newFaceSize, path, size)
    if not ok or not ftsize then
        logger.warn("Leko para popup failed to open font:", path, ftsize)
        return nil
    end
    local face_obj = {
        orig_font = path,
        realname = path,
        size = size,
        orig_size = size,
        ftsize = ftsize,
        hash = path .. "|" .. size,
        is_real_bold = false,
        hb_features = { "+kern", "+liga" },
    }
    face_obj.fallbacks = {}
    face_obj.getFallbackFont = function(num)
        if not num or num == 0 then return face_obj end
        if face_obj.fallbacks[num] ~= nil then
            return face_obj.fallbacks[num]
        end
        return false -- chain end
    end
    return face_obj
end

--- Fallback faces are shared process-wide: one FT face per (path, size).
function FaceFactory:_getFallbackFace(path, size)
    if not path or not size or size <= 0 then return nil end
    local key = path .. "|" .. size
    local cached = self.fallback_cache[key]
    if cached then return cached end
    local face = self:_buildFace(path, size)
    if face then
        self.fallback_cache[key] = face
    end
    return face
end

--- Fallback chain, first hit wins (silently skipped when the font is not
--- installed). Mirrors KOReader's own UI fallback chain
--- (frontend/ui/font.lua Font.fallbacks): freefont/FreeSans.ttf + FreeSerif.ttf
--- cover symbols (▸ U+25B8, ♥, arrows) and rare math alphanumerics.
---
--- NotoEmoji MUST stay at the absolute chain end: xtext's fallback is
--- cluster-granular, so a mid-chain emoji font degrades emoji sharing a
--- cluster with combining marks. At the chain end the emoji is always drawn.
---
--- xtext supports at most 15 fallback fonts (MAX_FONT_NUM = 16); this chain
--- has 9 plus the primary face.
local FALLBACK_FONT_NAMES = {
    "FreeSans.ttf",
    "NotoSansCJKsc-Regular.otf",
    "freefont/FreeSerif.ttf",
    "nerdfonts/symbols.ttf",
    "NotoSansTibetan-Regular.ttf",
    "NotoSansEgyptianHieroglyphs-Regular.ttf",
    "NotoSansBrahmi-Regular.ttf",
    "NotoSansSymbols2-Regular.ttf",
    "NotoEmoji-Regular.ttf", -- special: resolved via self.emoji_path; must stay last
}

function FaceFactory:_addFallbacks(face, size)
    local fallbacks = {}
    local n = 0
    for _, fontname in ipairs(FALLBACK_FONT_NAMES) do
        local path
        if fontname == "NotoEmoji-Regular.ttf" then
            path = self.emoji_path
        else
            -- Hand-built (not Font:getFace): size is already DPI-scaled.
            path = resolveBundledFont(fontname)
        end
        if path then
            local fb = self:_getFallbackFace(path, size)
            if fb then
                n = n + 1
                fallbacks[n] = fb
            end
        end
    end
    fallbacks[n + 1] = false -- explicit chain end
    face.fallbacks = fallbacks
end

--- Get a variant face (process-wide cache).
--- @param font_name string|nil KOReader 字体标识（"cfont" 或字体文件路径）
--- @param size number 已按屏幕 DPI 缩放的像素字号（取 body_face.size）
--- @param variant string key of VARIANTS
function FaceFactory:getFace(font_name, size, variant)
    variant = variant or "content"
    local key = string.format("%s|%d|%s", font_name or "", size or 0, variant)
    local cached = self.face_cache[key]
    if cached then return cached end

    local ratio = self.VARIANTS[variant] or 1.0
    local v_size = math.max(8, math.floor(size * ratio + 0.5))
    local face

    local paths = self:getFontPaths(font_name)
    local path = paths[1] and paths[1].path
    if path then
        face = self:_buildFace(path, v_size)
        if face then
            self:_addFallbacks(face, v_size)
        end
    end

    -- Fallback when the document font cannot be resolved: use a bundled font
    -- (also hand-built to avoid the double DPI scaling).
    if not face then
        local fallback_path = resolveBundledFont("NotoSans-Regular.ttf")
            or resolveBundledFont("NotoSansCJKsc-Regular.otf")
        if fallback_path then
            face = self:_buildFace(fallback_path, v_size)
            if face then
                self:_addFallbacks(face, v_size)
            end
        end
    end

    if face then
        self.face_cache[key] = face
    end
    return face
end

function FaceFactory:clearCache()
    self.face_cache = {}
    self.fallback_cache = {}
    self.font_paths_cache = {}
end

return FaceFactory
