param(
  [int]$BridgeStartupDelaySeconds = 20,
  [int]$NeteaseStartupDelaySeconds = 25
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WatchdogInstaller = Join-Path $ScriptDir "install-watchdog-task.ps1"
$CdpInstaller = Join-Path $ScriptDir "install-cdp-launch-task.ps1"

if (-not (Test-Path -LiteralPath $WatchdogInstaller)) {
  throw "Watchdog installer not found: $WatchdogInstaller"
}
if (-not (Test-Path -LiteralPath $CdpInstaller)) {
  throw "CDP launcher installer not found: $CdpInstaller"
}

& $WatchdogInstaller -StartupDelaySeconds $BridgeStartupDelaySeconds
& $CdpInstaller -StartupDelaySeconds $NeteaseStartupDelaySeconds

Write-Output "Installed background tasks for NetEase Music Reactive Wallpaper."
