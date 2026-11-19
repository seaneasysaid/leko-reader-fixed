-- SPA login for 书山 v6 comments (段评).
--
-- The 段评 API (/api/comment) is authenticated with a JWT that the web SPA
-- obtains from /api/auth/login.  That endpoint requires an `altcha` proof-of-work
-- token.  Unlike a human captcha, altcha is a *computable* challenge: it is just
-- SHA-256 proof-of-work, which this module solves in pure Lua.
--
-- Algorithm (mirrors /spa/vendor/altcha-insecure.js, verified 2026-11-19):
--   GET /api/captcha/challenge -> { parameters: {algorithm, cost, expiresAt,
--       keyLength, keyPrefix, nonce, salt}, signature }
--   For counter = 0,1,2,...:
--       pwd  = unhex(nonce) .. u32be(counter)
--       key  = sha256(unhex(salt) .. pwd), then sha256() (cost-1) more times
--       take first keyLength bytes; accept when hex starts with keyPrefix
--   payload = base64(json{ challenge = {parameters, signature},
--                          solution = {counter, derivedKey, time=0} })
--   POST /api/auth/login {email, password, altcha=payload} -> data.jwt
--
-- The JWT lasts ~7 days.  It is cached in source.login_info alongside the
-- existing 书山 credentials, so it survives re-imports and app restarts, and is
-- automatically refreshed when expired (using the stored email/password).
--
-- This module NEVER logs or prints credentials / JWTs.

local rapidjson = require("rapidjson")
local logger = require("logger")

local Util = require("Leko/Util")
local Http = require("Leko/Http")
local Digest = require("Leko/Digest")
local CryptoCompat = require("Leko/CryptoCompat")
local Shushan = require("Leko/Shushan")
local Storage = require("Leko/Storage")
local LuaSettings = require("luasettings")

local ShushanAuth = {}

ShushanAuth.KEY_JWT = "_jwt"
ShushanAuth.KEY_JWT_EXP = "_jwt_exp"
ShushanAuth.TIMEOUT = 20
-- Safety cap on the PoW loop.  Observed cost=1 solves in <100k iterations;
-- a few million is generous and still fast in LuaJIT.
ShushanAuth.MAX_COUNTER = 4000000
-- Refresh this many seconds before actual expiry to avoid a race at the boundary.
ShushanAuth.EXPIRY_SKEW = 60

local function text(value)
    return tostring(value == nil and "" or value)
end

local function trim(value)
    return Util.trim(text(value))
end

local function hex(value)
    return Digest:hex(value)
end

local function unhex(value)
    return CryptoCompat.unhex(value)
end

local function sha256(value)
    return Digest:sha256Binary(value)
end

local function base64_encode(value)
    return CryptoCompat.base64Encode(text(value))
end

local function u32be(number)
    local n = math.floor(number) % 4294967296
    return string.char(
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256)
end

local function decode_json(body)
    local ok, value = pcall(rapidjson.decode, text(body))
    if ok and type(value) == "table" then return value end
    return nil
end

local function fetch(options)
    local response, err = Http:request({
        url = options.url,
        method = options.method or "GET",
        headers = options.headers or {},
        body = options.body or "",
        timeout = options.timeout or ShushanAuth.TIMEOUT,
        maxtime = options.maxtime or (ShushanAuth.TIMEOUT * 3),
        retries = 0,
        max_bytes = 1024 * 1024,
        accept = "application/json",
    })
    if not response then return nil, text(err or "网络请求失败") end
    return response
end

--[[--
Solve one altcha challenge.  Returns the base64 payload string, or nil, err.
]]--
function ShushanAuth:solveChallenge(host)
    local response, err = fetch({
        url = host .. "/api/captcha/challenge",
        headers = { ["User-Agent"] = Shushan.USER_AGENT, ["Accept"] = "application/json" },
    })
    if not response or tonumber(response.code) ~= 200 then
        return nil, "获取人机验证挑战失败：" .. text(err or (response and response.code))
    end
    local challenge = decode_json(response.body)
    local params = challenge and type(challenge.parameters) == "table" and challenge.parameters or nil
    if not params or not params.salt or not params.nonce or not params.keyPrefix then
        return nil, "人机验证挑战格式无效"
    end

    local salt = unhex(params.salt)
    local nonce = unhex(params.nonce)
    if not salt or not nonce then return nil, "人机验证挑战参数无效" end
    local prefix = text(params.keyPrefix)
    local cost = math.max(1, tonumber(params.cost) or 1)
    local key_length = math.max(1, tonumber(params.keyLength) or 32)
    -- 前缀的十六进制串转成二进制，热循环里直接比字节：sha256 已经是 ~1µs/次
    -- （libcrypto 直调），每轮再做一次 hex 反而变成最贵的一步。
    local prefix_bytes = unhex(prefix)
    local counter = 0
    local derived = nil
    while counter <= ShushanAuth.MAX_COUNTER do
        local key = sha256(salt .. nonce .. u32be(counter))
        for _ = 2, cost do key = sha256(key) end
        if #key > key_length then key = key:sub(1, key_length) end
        if prefix_bytes then
            if key:sub(1, #prefix_bytes) == prefix_bytes then
                derived = hex(key)
                break
            end
        elseif hex(key):sub(1, #prefix) == prefix then
            -- 前缀长度是奇数转不成二进制时，退回十六进制比较（几乎不会发生）。
            derived = hex(key)
            break
        end
        counter = counter + 1
    end
    if not derived then return nil, "人机验证求解超时" end

    local solution = {
        counter = counter,
        derivedKey = derived,
        time = 0,
    }
    local payload_value = {
        challenge = {
            parameters = params,
            signature = challenge.signature,
        },
        solution = solution,
    }
    local ok, encoded = pcall(function() return rapidjson.encode(payload_value) end)
    if not ok then return nil, "人机验证载荷编码失败" end
    return base64_encode(encoded)
end

--[[--
Exchange stored email/password for a fresh SPA JWT.  Returns jwt, err.
]]--
function ShushanAuth:login(source)
    local credentials = Shushan:credentials(source)
    if credentials.email == "" or credentials.password == "" then
        return nil, "请先填写邮箱和密码：\n书源 → 书山聚合（原生）→ 配置书源"
    end
    local hosts = Shushan:hostOrder(source)
    local errors = {}
    for index = 1, math.min(#hosts, 3) do
        local host = hosts[index]
        local altcha, solve_err = self:solveChallenge(host)
        if not altcha then
            errors[#errors + 1] = Shushan:hostLabel(host) .. "：" .. text(solve_err)
        else
            local body = rapidjson.encode({
                email = credentials.email,
                password = credentials.password,
                altcha = altcha,
            })
            local response, err = fetch({
                url = host .. "/api/auth/login",
                method = "POST",
                headers = {
                    ["User-Agent"] = Shushan.USER_AGENT,
                    ["Content-Type"] = "application/json",
                    ["Accept"] = "application/json",
                    ["Origin"] = host,
                },
                body = body,
                timeout = 25,
            })
            if not response then
                errors[#errors + 1] = Shushan:hostLabel(host) .. "：" .. text(err)
            else
                local payload = decode_json(response.body)
                local data = payload and type(payload.data) == "table" and payload.data or nil
                local jwt = data and trim(data.jwt) or ""
                if payload and tonumber(payload.code) == 0 and jwt ~= "" then
                    -- JWT is opaque; store it plus a conservative expiry.  The
                    -- SPA reports jwt_expires_at as an ISO string we cannot
                    -- parse cheaply here, so use expires_in when present, else
                    -- the observed 7-day lifetime.
                    local ttl = tonumber(data.expires_in)
                    if not ttl or ttl <= 0 then ttl = 7 * 24 * 60 * 60 end
                    local expires = os.time() + math.floor(ttl)
                    Shushan:setLoginInfo(source, {
                        [self.KEY_JWT] = jwt,
                        [self.KEY_JWT_EXP] = expires,
                    })
                    logger.info("[LekoShushanAuth] JWT obtained via", Shushan:hostLabel(host),
                        "valid for", ttl, "s")
                    return jwt
                end
                local message = payload and (payload.message or payload.error or payload.msg)
                errors[#errors + 1] = Shushan:hostLabel(host) .. "："
                    .. (trim(message) ~= "" and trim(message) or ("HTTP " .. text(response.code)))
                -- Credential / captcha problems are the same on every mirror.
                if text(message):find("密码", 1, true) or text(message):find("邮箱", 1, true)
                    or text(message):find("账号", 1, true) then break end
            end
        end
    end
    return nil, "段评登录失败\n" .. table.concat(errors, "\n")
end

--- 从 runtime 文件里读登录态（只读，不改 source 的其它字段）。
-- 子进程登录后会把 login_info 写进 `<source runtime>/<id>.lua`，父进程下次
-- fork 之前靠这里把它捡回来。
function ShushanAuth:storedLoginInfo(source)
    if type(source) ~= "table" or source.id == nil then return nil end
    if type(Storage.getSourceRuntimePath) ~= "function" then return nil end
    local ok, path = pcall(Storage.getSourceRuntimePath, Storage, source.id)
    if not ok or type(path) ~= "string" or path == "" then return nil end
    local opened, settings = pcall(LuaSettings.open, path)
    if not opened or type(settings) ~= "table" then return nil end
    local info = type(settings.data) == "table" and settings.data.login_info or nil
    return type(info) == "table" and info or nil
end

--[[--
Return a valid JWT, refreshing it when missing or near expiry.
]]--
function ShushanAuth:jwt(source, options)
    options = options or {}
    local info = Shushan:loginInfo(source)
    local jwt = trim(info[self.KEY_JWT])
    local expires = tonumber(info[self.KEY_JWT_EXP]) or 0
    if jwt == "" and not options.force and type(source) == "table" then
        -- 段评请求跑在子进程里：JWT 是那个子进程登录后写进 runtime 文件的，
        -- 父进程内存里的 source.login_info 还是旧的。不补读一次磁盘，下一批
        -- 子进程 fork 出来又要重新登录（PoW + 一次往返）—— 每点一段都登一次。
        -- 只取 JWT 这两个键：整份 hydrate 会把父进程里更新的 Cookie / 变量
        -- 用磁盘上的旧值盖掉。
        local saved = self:storedLoginInfo(source)
        if saved then
            source.login_info = source.login_info or {}
            source.login_info[self.KEY_JWT] = saved[self.KEY_JWT]
            source.login_info[self.KEY_JWT_EXP] = saved[self.KEY_JWT_EXP]
            info = source.login_info
            jwt = trim(info[self.KEY_JWT])
            expires = tonumber(info[self.KEY_JWT_EXP]) or 0
        end
    end
    if jwt ~= "" and not options.force and expires > os.time() + self.EXPIRY_SKEW then
        return jwt
    end
    return self:login(source)
end

--- 手上是否已经有可用 JWT（内存或 runtime 文件）。绝不触发登录。
-- 预热判断用：有效就直接不打扰子进程，没有才值得起一个后台登录。
function ShushanAuth:hasValidJwt(source)
    if type(source) ~= "table" then return false end
    local info = Shushan:loginInfo(source)
    local jwt = trim(info[self.KEY_JWT])
    local expires = tonumber(info[self.KEY_JWT_EXP]) or 0
    if jwt == "" then
        -- 与 jwt() 同款补读：子进程登录后写在 runtime 文件里，父进程内存没有。
        local saved = self:storedLoginInfo(source)
        if saved then
            jwt = trim(saved[self.KEY_JWT])
            expires = tonumber(saved[self.KEY_JWT_EXP]) or 0
        end
    end
    return jwt ~= "" and expires > os.time() + self.EXPIRY_SKEW
end

return ShushanAuth
