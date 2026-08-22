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
if (-not $match.Success) { throw 'Unable to read plugin version.' }
$version = $match.Groups[1].Value

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
        'leko.koplugin/Leko/Version.lua'
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
