param(
    [Parameter(Mandatory = $true)]
    [string]$TargetPath,
    [switch]$Force,
    [switch]$AlwaysOn,
    [switch]$DisableAlwaysOn
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$installer = Join-Path $repoRoot "install.ps1"
$arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $installer, "-Project", $TargetPath)
if ($Force) { $arguments += "-Force" }
if ($AlwaysOn) { $arguments += "-AlwaysOn" }
if ($DisableAlwaysOn) { $arguments += "-DisableAlwaysOn" }

Write-Host "scripts/install.ps1 delegates to the current project installer."
& powershell.exe @arguments
exit $LASTEXITCODE
