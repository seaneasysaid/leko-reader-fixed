local rapidjson = require("rapidjson")

local Version = require("Leko/Version")
local WelcomeGuide = require("Leko/WelcomeGuide")

local BuiltinSources = {
    version = Version.builtin_sources_version or 1,
}

-- 书山聚合 is served natively: `Leko/Shushan.lua` performs the HTTP work and
-- these rules are ordinary JSONPath/HTML selectors over the JSON it returns.
-- No part of the upstream JavaScript runs on the device.
--
-- loginUi rows double as the credential form: SourceLoginView renders them and
-- stores the values in source.login_info, which is where Shushan.lua reads
-- 邮箱 / 密码 / 设备ID from.  The two buttons are dispatched natively (see
-- SourceLoginView:_run), so they never reach the QuickJS runtime.
local shushan_login_ui = rapidjson.encode({
    { name = "邮箱", type = "text" },
    { name = "密码", type = "password" },
    { name = "设备ID", type = "text" },
    { name = "登录书山", type = "button", action = "shushan_login()" },
    { name = "检测节点", type = "button", action = "shushan_check()" },
})

local SHUSHAN_COMMENT = table.concat({
    "纯 Lua 原生驱动，不执行书源里的任何 JavaScript。",
    "",
    "使用前请在「配置书源」里填写：",
    "1) 书山账号的邮箱与密码",
    "2) 本机在书山已登记的设备ID（16 位十六进制，可在手机阅读 App 的书山用户中心查看；不知道在哪查，就百度搜「安卓设备ID 怎么查」，或直接问 AI「设备ID在哪里查看」）",
    "填好后点「登录书山」拿密钥，再点「检测节点」选一台可用的镜像。",
}, "\n")

BuiltinSources.sources = {
    {
        bookSourceName = "Leko 内置说明",
        bookSourceGroup = "Leko 内置",
        bookSourceUrl = "leko://fixture",
        enabled = false,
        enabledCookieJar = false,
        searchUrl = "leko://fixture/search.json?key={{key}}&page={{page}}",
        ruleSearch = {
            bookList = "$.results[*]",
            name = "$.title",
            author = "$.author",
            bookUrl = "$.book_url",
            intro = "$.intro",
        },
        ruleBookInfo = {
            init = "$",
            name = "$.title",
            author = "$.author",
            intro = "$.intro",
            tocUrl = "$.toc_url",
        },
        ruleToc = {
            chapterList = "$.chapters[*]",
            chapterName = "$.title",
            chapterUrl = "$.url",
        },
        ruleContent = {
            content = "#content@html",
        },
    },
    {
        bookSourceName = "📚书山聚合（原生）",
        bookSourceGroup = "Leko 原生",
        bookSourceUrl = "leko://shushan",
        bookSourceComment = SHUSHAN_COMMENT,
        enabled = true,
        enabledExplore = false,
        enabledCookieJar = false,
        searchUrl = "leko://shushan/search?key={{key}}&page={{page}}",
        loginUi = shushan_login_ui,
        ruleSearch = {
            bookList = "$.results[*]",
            name = "$.name",
            author = "$.author",
            intro = "$.intro",
            coverUrl = "$.cover",
            kind = "$.kind",
            lastChapter = "$.lastChapter",
            wordCount = "$.wordCount",
            origin = "$.origin",
            bookUrl = "$.bookUrl",
        },
        ruleBookInfo = {
            init = "$",
            name = "$.name",
            author = "$.author",
            intro = "$.intro",
            coverUrl = "$.cover",
            kind = "$.kind",
            tocUrl = "$.tocUrl",
        },
        ruleToc = {
            chapterList = "$.chapters[*]",
            chapterName = "$.title",
            chapterUrl = "$.url",
        },
        ruleContent = {
            content = "#content@html",
        },
    },
}

local fixture_bodies = {
    ["leko://fixture/search.json"] = function()
        return rapidjson.encode({
            results = {
                {
                    title = WelcomeGuide.title,
                    author = WelcomeGuide.author,
                    intro = WelcomeGuide.intro,
                    book_url = "leko://fixture/book.json",
                },
            },
        }), "application/json; charset=utf-8"
    end,
    ["leko://fixture/book.json"] = function()
        return rapidjson.encode({
            title = WelcomeGuide.title,
            author = WelcomeGuide.author,
            intro = WelcomeGuide.intro,
            toc_url = "leko://fixture/toc.json",
        }), "application/json; charset=utf-8"
    end,
    ["leko://fixture/toc.json"] = function()
        return rapidjson.encode({
            chapters = (function()
                local chapters = {}
                for index, chapter in ipairs(WelcomeGuide.chapters) do
                    chapters[index] = { title = chapter.title, url = "leko://fixture/chapter-" .. index .. ".html" }
                end
                return chapters
            end)(),
        }), "application/json; charset=utf-8"
    end,
}

local function escapeHtml(text)
    return tostring(text or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
end

for index, chapter in ipairs(WelcomeGuide.chapters) do
    local chapter_text = chapter.text
    fixture_bodies["leko://fixture/chapter-" .. index .. ".html"] = function()
        local paragraphs = {}
        for paragraph in tostring(chapter_text or ""):gmatch("[^\n]+") do
            if paragraph:match("%S") then paragraphs[#paragraphs + 1] = "<p>" .. escapeHtml(paragraph) .. "</p>" end
        end
        return '<!doctype html><html><body><article id="content">'
            .. table.concat(paragraphs) .. '</article></body></html>', "text/html; charset=utf-8"
    end
end

-- Local scheme handled by this module.  Everything below `leko://` is served
-- in-process, which is what lets a source be implemented in Lua instead of
-- book-source JavaScript: the rule engine still runs its normal selectors, but
-- the responses come from here.
function BuiltinSources:isFixtureUrl(url)
    return tostring(url or ""):match("^leko://") ~= nil
end

function BuiltinSources:isShushanUrl(url)
    return tostring(url or ""):match("^leko://shushan") ~= nil
end

-- A `leko://` source may be backed by a Lua module that owns the real network
-- work.  Registering the prefixes here keeps every diagnostic surface
-- (SourceStatus / SourceHealth / SourceLoginView) reading one table instead of
-- each one string-matching "leko://shushan" on its own and drifting apart.
BuiltinSources.drivers = {
    { prefix = "leko://shushan", module = "Leko/Shushan", label = "书山聚合" },
}

-- Accepts a URL string or a source table.  The URL lives in a different field
-- depending on which layer built the table: the built-in definition uses
-- `bookSourceUrl`, the normalized record uses `source_key`, and an imported one
-- keeps the original JSON in `raw`.
function BuiltinSources:sourceUrl(value)
    if type(value) == "string" then return value end
    if type(value) ~= "table" then return "" end
    local raw = type(value.raw) == "table" and value.raw or {}
    return tostring(value.bookSourceUrl or value.book_source_url or value.source_key
        or raw.bookSourceUrl or raw.baseUrl or raw.base_url
        or value.base_url or value.url or "")
end

-- Returns the driver module for a native source, plus its registry entry.  The
-- module is required lazily because Shushan pulls in Storage, which loads this
-- file; a top-level require would be circular.
function BuiltinSources:driver(value)
    local url = self:sourceUrl(value)
    if url == "" then return nil end
    for index = 1, #self.drivers do
        local entry = self.drivers[index]
        if url:sub(1, #entry.prefix) == entry.prefix then
            local ok, module = pcall(require, entry.module)
            if ok then return module, entry end
            return nil, entry
        end
    end
    return nil
end

-- Human-facing capability label for a locally served source, or nil when the
-- source is an ordinary HTTP rule set.  Without this, a native source inherits
-- the generic "需要 JavaScript" label even though none of its book-source
-- JavaScript is ever loaded.
function BuiltinSources:nativeLabel(value)
    local _, entry = self:driver(value)
    if entry then return entry.label .. "内置原生驱动（不执行 JavaScript）", true end
    if self:isFixtureUrl(self:sourceUrl(value)) then return "本机内置资源（不联网）", true end
    return nil, false
end

function BuiltinSources:request(url, source)
    if self:isShushanUrl(url) then
        -- Required lazily: Storage (which this module is loaded from) pulls in
        -- BuiltinSources, so a top-level require here would be circular.
        local ok, Shushan = pcall(require, "Leko/Shushan")
        if not ok then return nil, "书山原生驱动加载失败：" .. tostring(Shushan) end
        local fine, response = pcall(function() return Shushan:handle(url, source) end)
        if not fine then return nil, "书山原生驱动异常：" .. tostring(response) end
        return response
    end
    local normalized = tostring(url or ""):gsub("[?#].*$", "")
    local producer = fixture_bodies[normalized]
    if not producer then return nil, "内置说明资源不存在：" .. normalized end
    local body, content_type = producer()
    return {
        url = normalized,
        code = 200,
        headers = { ["content-type"] = content_type },
        content_type = content_type,
        body = body,
        status = "200 OK",
    }
end

return BuiltinSources
