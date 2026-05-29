param(
  [string]$TaskName = "Netease Music Wallpaper Bridge Watchdog",
  [int]$StartupDelaySeconds = 20
)

$ErrorActionPreference = "Stop"

$WatchdogScript = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "netease-watchdog.ps1"
if (-not (Test-Path -LiteralPath $WatchdogScript)) {
  throw "Watchdog script not found: $WatchdogScript"
}

$quotedScript = '"' + $WatchdogScript + '"'
$action = New-ScheduledTaskAction `
  -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $quotedScript"

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
if ($StartupDelaySeconds -gt 0) {
  $trigger.Delay = "PT${StartupDelaySeconds}S"
}

$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::Zero) `
  -MultipleInstances IgnoreNew `
  -RestartCount 999 `
  -RestartInterval (New-TimeSpan -Minutes 1)

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger $trigger `
  -Settings $settings `
  -Principal $principal `
  -Description "Keeps the NetEase Music reactive wallpaper bridge running after login and restarts it if it fails." `
  -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
Write-Output "Installed and started scheduled task: $TaskName"
