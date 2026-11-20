param(
    [Parameter(Mandatory = $true)]
    [string]$TargetPath,
    [switch]$Force,
    [switch]$AlwaysOn,
    [switch]$DisableAlwaysOn,
    [switch]$RolesWindow,
    [switch]$NoRolesWindow,
    [string]$Players,
    [string]$Master,
    [switch]$NoSetupWindow
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$installer = Join-Path $repoRoot "install.ps1"
$arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $installer, "-Project", $TargetPath)
if ($Force) { $arguments += "-Force" }
if ($AlwaysOn) { $arguments += "-AlwaysOn" }
if ($DisableAlwaysOn) { $arguments += "-DisableAlwaysOn" }
if ($RolesWindow) { $arguments += "-RolesWindow" }
if ($NoRolesWindow) { $arguments += "-NoRolesWindow" }
# v3.18.0: the first-setup choice travels with the install.
if ($PSBoundParameters.ContainsKey('Players')) { $arguments += @("-Players", $Players) }
if ($PSBoundParameters.ContainsKey('Master')) { $arguments += @("-Master", $Master) }
if ($NoSetupWindow) { $arguments += "-NoSetupWindow" }

Write-Host "scripts/install.ps1 delegates to the current project installer."
& powershell.exe @arguments
exit $LASTEXITCODE
