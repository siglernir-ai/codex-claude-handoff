param(
    [string]$Project = (Get-Location).Path,
    [string]$Version = "v3.5.1",
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
    throw "Version must look like v3.4.0. Received: $Version"
}

# v3.4.1 (G2): install from the published RELEASE ASSET and verify its checksum.
#
# Until v3.4.1 this downloaded the tag source archive and extracted it with no
# integrity check at all. The project builds a .sha256 next to every release ZIP,
# but nothing on the install path ever read it - the checksum existed and nobody
# verified it. For a tool whose whole value is safety gates, that is decorative.
#
# The release asset is the right source because it is the artifact the packaging
# step actually produced and hashed. A hash embedded in this script would be worth
# little: the script and the hash would travel together from the same origin.
#
# Verification is fail-closed. A missing asset, a missing or malformed checksum
# file, a name mismatch, or a hash mismatch aborts before anything is extracted,
# so a failed download can never leave a half-installed protocol behind.
$packageName = "codex-claude-handoff-$Version.zip"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-claude-handoff-" + [guid]::NewGuid().ToString("N"))
$archive = Join-Path $tempRoot $packageName
$checksumFile = "$archive.sha256"
$extractRoot = Join-Path $tempRoot "package"
$releaseBase = "https://github.com/siglernir-ai/codex-claude-handoff/releases/download/$Version"
$archiveUri = "$releaseBase/$packageName"
$checksumUri = "$archiveUri.sha256"

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    Write-Host "Downloading codex-claude-handoff $Version..."
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $archiveUri -OutFile $archive
    } catch {
        throw "Could not download the release asset $packageName for $Version. A published GitHub Release with attached ZIP and .sha256 assets is required. Underlying error: $($_.Exception.Message)"
    }

    Write-Host "Downloading checksum..."
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $checksumUri -OutFile $checksumFile
    } catch {
        throw "Could not download the checksum $packageName.sha256 for $Version. Installation is refused without an integrity check. Underlying error: $($_.Exception.Message)"
    }

    # Strict format: 64 hex characters, whitespace, then the exact asset name.
    $checksumText = (Get-Content -LiteralPath $checksumFile -Raw).Trim()
    if ($checksumText -notmatch '^([0-9a-fA-F]{64})\s+(\S.*)$') {
        throw "Malformed checksum file for $Version. Expected '<64-hex>  $packageName'."
    }
    $expectedHash = $Matches[1].ToLowerInvariant()
    $checksumName = $Matches[2].Trim()
    if ($checksumName -ne $packageName) {
        throw "Checksum file names '$checksumName' but the downloaded asset is '$packageName'. Refusing to install a mismatched pair."
    }

    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "SHA-256 mismatch for $packageName. Expected $expectedHash but the downloaded file is $actualHash. Nothing was installed."
    }
    Write-Host "SHA-256 verified: $actualHash"

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
