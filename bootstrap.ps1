param(
    [string]$Project = (Get-Location).Path,
    [string]$Version = "v3.2.2",
    [switch]$Force,
    [switch]$AlwaysOn,
    [switch]$DisableAlwaysOn,
    [string]$PackageRoot
)

$ErrorActionPreference = "Stop"

function Invoke-PackageInstaller {
    param([Parameter(Mandatory = $true)][string]$Root)

    $installer = Join-Path $Root "install.ps1"
    $templates = Join-Path $Root "templates"
    if (-not (Test-Path -LiteralPath $installer) -or -not (Test-Path -LiteralPath $templates)) {
        throw "Invalid codex-claude-handoff package root: $Root"
    }

    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $installer, "-Project", $Project)
    if ($Force) { $arguments += "-Force" }
    if ($AlwaysOn) { $arguments += "-AlwaysOn" }
    if ($DisableAlwaysOn) { $arguments += "-DisableAlwaysOn" }

    & powershell.exe @arguments
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

if ($PackageRoot) {
    Invoke-PackageInstaller -Root ([System.IO.Path]::GetFullPath($PackageRoot))
    exit 0
}

if ($Version -notmatch '^v\d+\.\d+\.\d+$') {
    throw "Version must look like v3.2.2. Received: $Version"
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-claude-handoff-" + [guid]::NewGuid().ToString("N"))
$archive = Join-Path $tempRoot "package.zip"
$extractRoot = Join-Path $tempRoot "package"
$archiveUri = "https://github.com/siglernir-ai/codex-claude-handoff/archive/refs/tags/$Version.zip"

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Write-Host "Downloading codex-claude-handoff $Version..."
    Invoke-WebRequest -UseBasicParsing -Uri $archiveUri -OutFile $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $extractRoot -Force

    $package = Get-ChildItem -LiteralPath $extractRoot -Directory | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName "install.ps1")) -and
        (Test-Path -LiteralPath (Join-Path $_.FullName "templates"))
    } | Select-Object -First 1

    if (-not $package) {
        throw "Downloaded archive does not contain a valid installer."
    }

    Invoke-PackageInstaller -Root $package.FullName
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
