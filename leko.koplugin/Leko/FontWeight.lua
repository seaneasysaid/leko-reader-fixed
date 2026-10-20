--[[--
正文字重（style.body_weight，0-3）。

leko 不是 crengine，没有 setFontBaseWeight。这里用 FreeType 仿粗强度按
crengine 的 400 / 500 / 600 / 700 等比复刻，最高档 3/8 即 KOReader 的标准粗体。

⚠️ TextWidget / TextBoxWidget 的 updateSize() 会再调 Font:getAdjustedFace，
按 "<hash>synthbold" 查缓存，查不到就克隆一个丢掉强度的 face。所以下面必须
把这两个缓存键指回加权后的 face，否则四档会变成同一档。
--]]

local Font = require("ui/font")
local logger = require("logger")

local FontWeight = {}

FontWeight.LEVELS = {
    { label = "正常", factor = 0 },
    { label = "微粗", factor = 1 / 8 },
    { label = "中粗", factor = 1 / 4 },
    { label = "加粗", factor = 3 / 8 },
}
FontWeight.MAX = #FontWeight.LEVELS - 1
-- 强制仿粗，避免被换成真实 Bold 文件（否则四档压成两档）。
FontWeight.BOLD = Font.FORCE_SYNTHETIZED_BOLD or true

local fallback_wrappers = {}
local weighted_faces = {}

local function basename(path)
    return tostring(path or ""):match("([^/\\]+)$") or tostring(path or "")
end

function FontWeight.clamp(value)
    local number = math.floor((tonumber(value) or 0) + 0.5)
    if number < 0 then return 0 end
    if number > FontWeight.MAX then return FontWeight.MAX end
    return number
end

function FontWeight.label(value)
    return FontWeight.LEVELS[FontWeight.clamp(value) + 1].label
end

-- 点一下切下一档，末档回到「正常」。
function FontWeight.next(value)
    return (FontWeight.clamp(value) + 1) % (FontWeight.MAX + 1)
end

local function emboldenStrength(ftsize, factor)
    if not ftsize or not factor or factor <= 0 then return nil end
    local ok, strength = pcall(ftsize.getEmboldenHalfStrength, ftsize, factor)
    return ok and strength or nil
end

-- 共享原 ftsize，只换 hash 与仿粗强度。
local function copyFace(base, hash, strength, wants_bold)
    return {
        orig_font = base.orig_font,
        realname = base.realname,
        size = base.size,
        orig_size = base.orig_size,
        ftsize = base.ftsize,
        hb_features = base.hb_features,
        hash = hash,
        is_real_bold = false,
        wants_bold = wants_bold,
        embolden_half_strength = strength,
    }
end

local function wrapFallback(base, level, strength)
    local key = tostring(base.hash) .. "|lekow" .. level
    if fallback_wrappers[key] then return fallback_wrappers[key] end

    local wrapper = copyFace(base, key, strength)
    wrapper.fallbacks = {}
    wrapper.getFallbackFont = function(num)
        if not num or num == 0 then return wrapper end
        if type(base.getFallbackFont) ~= "function" then return false end
        local ok, inner = pcall(base.getFallbackFont, num)
        return ok and inner or false
    end
    fallback_wrappers[key] = wrapper
    return wrapper
end

local function buildWeightedFace(base, level)
    local strength = emboldenStrength(base.ftsize, FontWeight.LEVELS[level + 1].factor)
    if not strength then return nil end

    local face = copyFace(base, tostring(base.hash) .. "|lekow" .. level, strength, FontWeight.BOLD)

    -- 回退链照抄 Font.fallbacks（顺序即优先级），跳过主字体本身。
    local fallbacks, count, base_name = {}, 0, basename(base.realname)
    for _, name in ipairs(Font.fallbacks or {}) do
        if basename(name) ~= base_name then
            local ok, fallback = pcall(Font.getFace, Font, name, base.orig_size or base.size)
            if ok and fallback then
                count = count + 1
                fallbacks[count] = wrapFallback(fallback, level, strength)
            end
        end
    end
    fallbacks[count + 1] = false -- 链尾

    face.fallbacks = fallbacks
    face.getFallbackFont = function(num)
        if not num or num == 0 then return face end
        return fallbacks[num] or false
    end
    return face
end

-- 返回 (face, bold)，bold 需原样传给 TextWidget / TextBoxWidget。
function FontWeight.apply(base_face, weight)
    local level = FontWeight.clamp(weight)
    if level == 0 or not base_face or base_face.is_real_bold then
        return base_face, false
    end

    local cache_key = tostring(base_face.hash) .. "|lekow" .. level
    local face = weighted_faces[cache_key]
    if not face then
        face = buildWeightedFace(base_face, level)
        if not face then
            logger.warn("Leko FontWeight: 当前字体不支持仿粗，回退到正常字重")
            return base_face, false
        end
        weighted_faces[cache_key] = face
    end

    -- 拦住 Font:getAdjustedFace 的重新克隆，见文件头。
    Font.faces = Font.faces or {}
    Font.faces[face.hash .. "synthbold"] = face
    Font.faces[face.hash .. "realbold"] = face
    return face, FontWeight.BOLD
end

return FontWeight
