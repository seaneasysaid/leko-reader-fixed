[CmdletBinding()]
param(
    [string]$OutputDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$OutputDirectory = if ($OutputDirectory) { $OutputDirectory } else { Join-Path $repoRoot 'dist' }
$pluginRoot = Join-Path $repoRoot 'leko.koplugin'
$versionFile = Join-Path $pluginRoot 'Leko\Version.lua'
if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
    throw "Missing version file: $versionFile"
}

$versionText = Get-Content -Raw -Encoding UTF8 -LiteralPath $versionFile
$match = [regex]::Match($versionText, 'version\s*=\s*"([^"]+)"')
if (-not ($match.Success)) { throw 'Unable to read plugin version.' }
$version = $match.Groups[1].Value
$mainFile = Join-Path $pluginRoot 'main.lua'
$mainText = Get-Content -Raw -Encoding UTF8 -LiteralPath $mainFile
$mainMatch = [regex]::Match($mainText, 'EXPECTED_VERSION\s*=\s*"([^"]+)"')
if ($mainMatch.Success) {
    if ($mainMatch.Groups[1].Value -ne $version) {
        throw 'Version.lua and main.lua do not declare the same release version.'
    }
} elseif ($mainText -notmatch 'require\(\s*["'']Leko/Version["'']\s*\)\.version') {
    throw 'main.lua does not use the canonical Leko/Version release version.'
}
$installFile = Join-Path $pluginRoot 'INSTALL.txt'
$installText = Get-Content -Raw -Encoding UTF8 -LiteralPath $installFile
$installMatch = [regex]::Match($installText, '(?m)^Leko Reader\s+([^\s]+)\s+')
$installVersion = if ($installMatch.Success) { [string]$installMatch.Groups[1].Value } else { '' }
if ($installMatch.Success -eq $false -or $installVersion -ne [string]$version) {
    throw 'Version.lua and INSTALL.txt do not declare the same release version.'
}
$nativeBridge = Join-Path $pluginRoot 'Leko\native\liblekoqjs.so'
if (-not (Test-Path -LiteralPath $nativeBridge -PathType Leaf)) {
    throw "Missing Kindle ARM native bridge: $nativeBridge"
}
$nativeBytes = [IO.File]::ReadAllBytes($nativeBridge)
if ($nativeBytes.Length -lt 52 -or $nativeBytes[0] -ne 0x7f -or $nativeBytes[1] -ne 0x45 -or
        $nativeBytes[2] -ne 0x4c -or $nativeBytes[3] -ne 0x46 -or $nativeBytes[4] -ne 1 -or $nativeBytes[5] -ne 1) {
    throw 'Kindle native bridge is not a 32-bit little-endian ELF file.'
}
$machine = [BitConverter]::ToUInt16($nativeBytes, 18)
$flags = [BitConverter]::ToUInt32($nativeBytes, 36)
if ($machine -ne 40 -or $flags -ne 0x05000200) {
    throw ('Kindle native bridge ABI mismatch: machine={0}, flags=0x{1:x8}' -f $machine, $flags)
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$zipPath = Join-Path $OutputDirectory ("Leko-Reader-KOReader-{0}.zip" -f $version)
if (Test-Path -LiteralPath $zipPath) {
    throw "Refusing to overwrite an existing archive: $zipPath"
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('leko-public-package-' + [Guid]::NewGuid().ToString('N'))
$stagePlugin = Join-Path $tempRoot 'leko.koplugin'
New-Item -ItemType Directory -Path $stagePlugin -Force | Out-Null

try {
    foreach ($name in @('main.lua', '_meta.lua', 'INSTALL.txt')) {
        Copy-Item -LiteralPath (Join-Path $pluginRoot $name) -Destination $stagePlugin
    }
    foreach ($name in @('Leko', 'book_sources', 'resources')) {
        Copy-Item -LiteralPath (Join-Path $pluginRoot $name) -Destination (Join-Path $stagePlugin $name) -Recurse
    }
    Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination (Join-Path $stagePlugin 'README.md')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination (Join-Path $stagePlugin 'LICENSE')

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $stagePlugin -Recurse -File | Sort-Object FullName) {
            $entry = $file.FullName.Substring($tempRoot.Length + 1).Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive, $file.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    } finally {
        $archive.Dispose()
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolvedStage = [IO.Path]::GetFullPath($tempRoot)
        $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolvedStage.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolvedStage) -notmatch '^leko-public-package-[0-9a-f]{32}$') {
            throw 'Refusing to remove an unexpected package staging path.'
        }
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

# Validate the archive that will be handed to the user.  A valid ZIP can still
# be installed into a partially overwritten plugin directory, so fail here if
# the archive itself is missing any loader-critical file or contains malformed
# paths.  This keeps packaging failures separate from device-side copy failures.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $entries = @($archive.Entries)
    $duplicateNames = @($entries | Group-Object FullName | Where-Object { $_.Count -gt 1 })
    if ($duplicateNames.Count -gt 0) {
        throw 'Package contains duplicate ZIP entry names.'
    }
    $invalidNames = @($entries | Where-Object {
        $_.FullName -notmatch '^leko\.koplugin/' -or $_.FullName -match '(^|/)\.\.?(/|$)'
    })
    if ($invalidNames.Count -gt 0) {
        throw 'Package contains an invalid ZIP entry path.'
    }
    foreach ($required in @(
        'leko.koplugin/main.lua',
        'leko.koplugin/_meta.lua',
        'leko.koplugin/Leko/App.lua',
        'leko.koplugin/Leko/MemoryGuard.lua',
        'leko.koplugin/Leko/ProcessBudget.lua',
        'leko.koplugin/Leko/Version.lua',
        'leko.koplugin/Leko/native/liblekoqjs.so'
    )) {
        $entry = $archive.GetEntry($required)
        if ($null -eq $entry -or $entry.Length -le 0) {
            throw "Package is missing or has an empty required file: $required"
        }
    }
} finally {
    $archive.Dispose()
}

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[pscustomobject]@{
    package = $zipPath
    size_bytes = (Get-Item -LiteralPath $zipPath).Length
    verified = $true
    sha256 = $hash
} | ConvertTo-Json
