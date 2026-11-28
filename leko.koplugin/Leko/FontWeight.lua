--[[--
正文字重（style.body_weight）。

字重范围：-3 ~ 5.5，步长 0.25。leko 不是 crengine，没有
setFontBaseWeight，所以这里把字重刻度映射成 FreeType 仿粗强度：

  * <= 0      → 不变粗（负数没有更细的字体可退）
  * 0 ~ 3     → 沿用原四档 0 / 1/8 / 1/4 / 3/8，负整数之间线性插值
  * 3 ~ 5.5   → 3/8 线性升到 1/2

旧存档里的 0/1/2/3 完全保持原来的视觉效果；新档位只是把中间插值补细。

⚠️ TextWidget / TextBoxWidget 的 updateSize() 会再调 Font:getAdjustedFace，
按 "<hash>synthbold" 查缓存，查不到就克隆一个丢掉强度的 face。所以下面必须
把这两个缓存键指回加权后的 face，否则不同档位会变成同一档。
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
FontWeight.MIN = -3
FontWeight.MAX = 5.5
FontWeight.STEP = 0.25
-- 强制仿粗，避免被换成真实 Bold 文件（否则档位会压成两档）。
FontWeight.BOLD = Font.FORCE_SYNTHETIZED_BOLD or true

local fallback_wrappers = {}
local weighted_faces = {}

local function basename(path)
    return tostring(path or ""):match("([^/\\]+)$") or tostring(path or "")
end

-- 吸附到 0.25 刻度，并夹在 -3 ~ 5.5 内。
function FontWeight.clamp(value)
    local number = tonumber(value) or 0
    if number < FontWeight.MIN then number = FontWeight.MIN end
    if number > FontWeight.MAX then number = FontWeight.MAX end
    local steps = math.floor((number - FontWeight.MIN) / FontWeight.STEP + 0.5)
    number = FontWeight.MIN + steps * FontWeight.STEP
    if number < FontWeight.MIN then return FontWeight.MIN end
    if number > FontWeight.MAX then return FontWeight.MAX end
    return number
end

function FontWeight.key(value)
    return string.format("%.2f", FontWeight.clamp(value))
end

function FontWeight.factor(value)
    local weight = FontWeight.clamp(value)
    if weight <= 0 then return 0 end
    if weight <= 3 then
        local index = math.floor(weight)
        local fraction = weight - index
        local from = FontWeight.LEVELS[index + 1].factor
        local to = FontWeight.LEVELS[math.min(index + 2, #FontWeight.LEVELS)].factor
        return from + (to - from) * fraction
    end
    -- 5.5 是最粗档；leko 的上限定在 1/2，避免墨水屏糊成一团。
    return FontWeight.LEVELS[#FontWeight.LEVELS].factor
        + (weight - 3) / 2.5 * (1 / 8)
end

function FontWeight.label(value)
    local factor = FontWeight.factor(value)
    if factor <= 0.01 then return "正常" end
    if factor < 0.19 then return "微粗" end
    if factor < 0.31 then return "中粗" end
    if factor < 0.44 then return "加粗" end
    return "特粗"
end

-- 旧版全屏排版菜单仍按整数档循环；新版滑块走 clamp，不依赖这里。
function FontWeight.next(value)
    local weight = FontWeight.clamp(value)
    if weight < 0 or weight >= 3 then return 0 end
    return math.floor(weight + 0.5) + 1
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

local function wrapFallback(base, weight, strength)
    local key = tostring(base.hash) .. "|lekow" .. FontWeight.key(weight)
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

local function buildWeightedFace(base, weight)
    local strength = emboldenStrength(base.ftsize, FontWeight.factor(weight))
    if not strength then return nil end

    local face = copyFace(base,
        tostring(base.hash) .. "|lekow" .. FontWeight.key(weight),
        strength, FontWeight.BOLD)

    -- 回退链照抄 Font.fallbacks（顺序即优先级），跳过主字体本身。
    local fallbacks, count, base_name = {}, 0, basename(base.realname)
    for _, name in ipairs(Font.fallbacks or {}) do
        if basename(name) ~= base_name then
            local ok, fallback = pcall(Font.getFace, Font, name, base.orig_size or base.size)
            if ok and fallback then
                count = count + 1
                fallbacks[count] = wrapFallback(fallback, weight, strength)
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
    local strength = FontWeight.factor(weight)
    if strength <= 0 or not base_face or base_face.is_real_bold then
        return base_face, false
    end

    local key = FontWeight.key(weight)
    local cache_key = tostring(base_face.hash) .. "|lekow" .. key
    local face = weighted_faces[cache_key]
    if not face then
        face = buildWeightedFace(base_face, weight)
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
