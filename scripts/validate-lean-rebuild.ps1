[CmdletBinding()]
param(
    [string]$PackagePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Read-RepoFile([string]$RelativePath) {
    $path = Join-Path $repoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing file: $RelativePath" }
    return Get-Content -Raw -Encoding UTF8 -LiteralPath $path
}

function Require-Text([string]$RelativePath, [string[]]$Needles) {
    $text = Read-RepoFile $RelativePath
    foreach ($needle in $Needles) {
        if ($text.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) {
            throw "Expected '$needle' in $RelativePath"
        }
    }
}

function Reject-Text([string]$RelativePath, [string[]]$Needles) {
    $text = Read-RepoFile $RelativePath
    foreach ($needle in $Needles) {
        if ($text.IndexOf($needle, [StringComparison]::Ordinal) -ge 0) {
            throw "Rejected '$needle' in $RelativePath"
        }
    }
}

Require-Text 'leko.koplugin\Leko\SourceView.lua' @('配置书源', 'SourceLoginView.open')
$configEntries = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'leko.koplugin\Leko') -Filter '*.lua' -File |
    Select-String -SimpleMatch 'SourceLoginView.open{')
if ($configEntries.Count -ne 1) { throw "Expected exactly one source configuration entry; found $($configEntries.Count)" }
Require-Text 'leko.koplugin\Leko\LegadoSource.lua' @(
    'executeLogin', 'executeLoginUiAction', 'safeJsonDiscoveryRule',
    'options.lazy_search', 'responseRuleInputUrl', 'DataUri:ruleInput',
    '正在解析目录（', '正在执行解析规则', '正在整理内容',
    'prepareDeferredUrl', 'extractUrlsBatch', '_deferred_url', '正在生成章节请求地址',
    '__nested_request_error', '嵌套请求返回空正文',
    'contentActivityProgress', '正文分页请求完成，正在完成整理'
)
Require-Text 'leko.koplugin\Leko\AggregateActionCapability.lua' @(
    'buildFunctionIndex', 'runtime_capability_version', 'isPrepared',
    '调用了未定义的脚本函数', '需要浏览器或页面脚本'
)
Require-Text 'leko.koplugin\Leko\SourceLoginView.lua' @(
    'AggregateActionCapability.isPrepared', 'dim = not supported', '正在分析按钮能力'
)
Require-Text 'leko.koplugin\Leko\Storage.lua' @(
    'login_info', 'getSourceCatalogRevision', 'action_capability_cache'
)
Require-Text 'leko.koplugin\Leko\DataUri.lua' @('ruleInput', 'hexEncode', 'descriptorEncoding')
Require-Text 'leko.koplugin\Leko\CookieJar.lua' @('max-age', 'expires')
Require-Text 'leko.koplugin\Leko\AsyncSourceSearch.lua' @(
    'MAX_PARALLEL_WORKERS = 2', 'SearchSettings:getLimit()',
    'retryable_no_response', 'process_abnormal', 'force_refresh',
    'SearchResultCache:key', 'entry.attempts = attempts + 1',
    'local prepared, prepare_err = xpcall', '书源索引读取失败'
)
Reject-Text 'leko.koplugin\Leko\AsyncSourceSearch.lua' @('FAST_SOURCE_DEADLINE', 'MAX_PARALLEL_WORKERS = 3')
Require-Text 'leko.koplugin\Leko\SearchResultCache.lua' @(
    'ttl_seconds = 15 * 60', 'normalizeQuery', 'catalog_revision',
    'safeVariables', 'safeSourceRecord', 'candidate_order', 'onMemoryPressure', 'onExit'
)
Require-Text 'leko.koplugin\Leko\RuleEngine.lua' @(
    'omit_raw_response', 'source.getKey', 'timeFormat', 'splitScriptReplacement',
    'splitRuleAnd', 'prefer_context', 'scriptReferencesRawResponse',
    'prepareDeferredUrl', 'resolveDeferredUrl', 'extractUrlsBatch',
    'NESTED_REQUEST_FAILED'
)
Require-Text 'leko.koplugin\Leko\QuickJS.lua' @(
    'response_headers', 'response_request', 'requested_charset',
    'dom_list', 'toArray', 'isEmpty', 'selector_list', 'savedResult',
    'java_string_list', 'java_list', 'globalThis.org', 'globalThis.Mac',
    'sanitizeUtf8', '__quickjs_timeout_ms', '__quickjs_max_result_bytes',
    'local previous_env = self.env', 'tonumber(session.busy)', 'java_map',
    'function QuickJS:evalBatch', 'js_byte_array_b64', '__src_is_result',
    'encodeBase64Bytes',
    'self:_register(handle, "java_byte_array")'
)
Require-Text 'leko.koplugin\Leko\AsyncSourceCatalog.lua' @(
    'function AsyncSourceCatalog:_reap', 'worker.reaping', 'ProcessBudget:release(worker.budget_ticket)'
)
Require-Text 'leko.koplugin\Leko\SearchView.lua' @(
    'previous_controller', 'controller:start()', 'previous_controller:cancel()',
    'pcall(self.onHeavyTaskDone, "opening")'
)
Require-Text 'leko.koplugin\Leko\BookInfoView.lua' @(
    'local previous_search = search', 'replacement:start()', 'previous_search:cancel()'
)
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'scripts\test-search-return-lifecycle.lua') -PathType Leaf)) {
    throw 'Missing focused search return lifecycle regression'
}
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'scripts\test-real-source-content-progress.lua') -PathType Leaf)) {
    throw 'Missing real multi-page content progress regression'
}
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'scripts\test-reader-ui-contract.lua') -PathType Leaf)) {
    throw 'Missing focused reader UI contract regression'
}
Require-Text 'leko.koplugin\Leko\StreamingResultList.lua' @(
    '_preserve_for_return', 'Preserve both', 'if self._preserve_for_return then return end',
    'requestManualRefresh', 'manual_result_refresh', '_disposed'
)
Reject-Text 'leko.koplugin\Leko\Paginator.lua' @('render_text', 'render_end')
Require-Text 'leko.koplugin\Leko\JavaHostCompat.lua' @(
    'java.util.UUID', 'java.security.KeyFactory', 'javax.crypto.Cipher',
    'org.jsoup.Jsoup', 'okhttp3.OkHttpClient', 'java.math',
    'initVerify', 'rsaPublicEncryptComponents', 'rsaPrivateDecrypt'
)
Require-Text 'leko.koplugin\Leko\CryptoCompat.lua' @(
    'Leko/PureCrypto', 'ZEROPADDING', 'rsaPublicEncrypt',
    'rsaPrivateDecrypt', 'rsaVerify', 'd2i_RSA_PUBKEY',
    'pcall(require, "mime")', 'mime.b64', 'mime.unb64'
)
Require-Text 'leko.koplugin\Leko\PureCrypto.lua' @(
    'AES', 'DES', 'DESEDE', 'ZEROPADDING', 'DES_SBOX'
)
Require-Text 'leko.koplugin\Leko\AsyncBookOperation.lua' @(
    'last_activity_at', 'timeout_mode == "inactivity"',
    'terminateSubProcess', 'isSubProcessDone', 'flushStateQueue', 'state_queue'
)
Require-Text 'leko.koplugin\Leko\BookOperationSpec.lua' @(
    'timeout_mode = "inactivity"', 'max_timeout_seconds = 10 * 60'
)
Require-Text 'leko.koplugin\Leko\KOReaderStatisticsBridge.lua' @(
    'statistics.sqlite3', 'page_stat_data', 'page_stat'
)
Require-Text 'leko.koplugin\Leko\ReaderView.lua' @(
    'statistics_id', 'chapter_progress', 'book_progress',
    'onReadingPaused', 'onReadingResumed', '阅读设置', 'ShowFlDialog',
    'hasFrontlightControl',
    'text = element.text', 'os.date("%H:%M")'
)
Reject-Text 'leko.koplugin\Leko\ReaderView.lua' @('justified = true', '{ text = "排版"')
Require-Text 'leko.koplugin\main.lua' @('require("Leko/Version").version', 'getCurrentReadingContext')

foreach ($forbidden in @(
    'leko.koplugin\Leko\CapabilityRegistry.lua',
    'leko.koplugin\Leko\SourcePipeline.lua',
    'leko.koplugin\Leko\ContentClassifier.lua',
    'leko.koplugin\Leko\ProgressCoordinator.lua'
)) {
    if (Test-Path -LiteralPath (Join-Path $repoRoot $forbidden)) { throw "Forbidden module present: $forbidden" }
}
if (Test-Path -LiteralPath (Join-Path $repoRoot 'leko.koplugin\Leko\PureAES.lua')) {
    throw 'PureAES.lua must be consolidated into PureCrypto.lua'
}

if ($PackagePath) {
    $resolvedPackage = (Resolve-Path -LiteralPath $PackagePath).Path
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($resolvedPackage)
    try {
        foreach ($required in @(
            'leko.koplugin/Leko/SearchResultCache.lua',
            'leko.koplugin/Leko/SourceLoginView.lua',
            'leko.koplugin/Leko/AggregateActionCapability.lua',
            'leko.koplugin/Leko/KOReaderStatisticsBridge.lua',
            'leko.koplugin/Leko/PureCrypto.lua',
            'leko.koplugin/Leko/native/liblekoqjs.so'
        )) {
            if ($null -eq $archive.GetEntry($required)) { throw "Package missing $required" }
        }
        if ($null -ne $archive.GetEntry('leko.koplugin/Leko/PureAES.lua')) {
            throw 'Package still contains retired PureAES.lua'
        }
    } finally {
        $archive.Dispose()
    }
}

[pscustomobject]@{
    verified = $true
    package_checked = [bool]$PackagePath
    scope = 'lean-port-source-contracts'
} | ConvertTo-Json
