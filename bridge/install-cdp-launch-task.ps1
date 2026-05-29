param(
  [string]$TaskName = "Netease Music CDP Launcher",
  [int]$StartupDelaySeconds = 25
)

$ErrorActionPreference = "Stop"

$LauncherScript = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "ensure-netease-cdp.ps1"
if (-not (Test-Path -LiteralPath $LauncherScript)) {
  throw "Launcher script not found: $LauncherScript"
}

$quotedScript = '"' + $LauncherScript + '"'
$action = New-ScheduledTaskAction `
  -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $quotedScript -RestartIfNeeded"

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
if ($StartupDelaySeconds -gt 0) {
  $trigger.Delay = "PT${StartupDelaySeconds}S"
}

$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
  -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger $trigger `
  -Settings $settings `
  -Principal $principal `
  -Description "Launches or relaunches NetEase Cloud Music with the local CDP port used by the reactive wallpaper bridge." `
  -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
Write-Output "Installed and started scheduled task: $TaskName"
