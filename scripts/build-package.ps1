param(
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repoRoot "dist"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

$versionPath = Join-Path $repoRoot ".ai\skills\codex-claude-handoff\VERSION"
$version = (Get-Content -Raw -LiteralPath $versionPath).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Invalid VERSION value: $version"
}

$packageName = "codex-claude-handoff-v$version"
$zipPath = Join-Path $OutputDirectory "$packageName.zip"
$checksumPath = "$zipPath.sha256"
$tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-claude-handoff-package-" + [guid]::NewGuid().ToString("N"))
$packageRoot = Join-Path $tempBase $packageName

$rootFiles = @(
    "bootstrap.ps1",
    "install.ps1",
    "README.md",
    "QUICKSTART.md",
    "HOW_IT_WORKS.md",
    "PUBLISHING.md",
    "SECURITY.md",
    "MODEL_GUIDANCE.md",
    "CHANGELOG.md",
    "ROADMAP.md"
)

try {
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

    foreach ($relative in $rootFiles) {
        $source = Join-Path $repoRoot $relative
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Required package file is missing: $relative"
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $packageRoot $relative) -Force
    }

    $templateSource = Join-Path $repoRoot "templates"
    $templateDestination = Join-Path $packageRoot "templates"
    Get-ChildItem -LiteralPath $templateSource -Recurse -File -Force | ForEach-Object {
        $relative = $_.FullName.Substring($templateSource.Length).TrimStart('\', '/') -replace '/', '\'
        if ($relative -in @("scripts\protocol-tests.ps1", "scripts\protocol-tests.sh")) {
            return
        }

        $destination = Join-Path $templateDestination $relative
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    if (Test-Path -LiteralPath $checksumPath) {
        Remove-Item -LiteralPath $checksumPath -Force
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempBase, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $checksumPath -Value "$hash  $([System.IO.Path]::GetFileName($zipPath))" -Encoding ascii

    Write-Host "Package:  $zipPath"
    Write-Host "SHA-256: $hash"
    Write-Host "Checksum: $checksumPath"
}
finally {
    if (Test-Path -LiteralPath $tempBase) {
        Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}
