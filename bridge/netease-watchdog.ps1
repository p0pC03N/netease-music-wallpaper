param(
  [int]$BridgeIntervalSeconds = 3,
  [int]$CheckIntervalSeconds = 6,
  [int]$StaleSeconds = 60,
  [int]$CdpCheckIntervalSeconds = 30,
  [int]$CdpFailureThreshold = 3,
  [int]$CdpRecoveryCooldownMinutes = 10
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$BridgeScript = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "netease-bridge.ps1"
$RuntimeServerScript = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "netease-runtime-server.js"
$EnsureCdpScript = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "ensure-netease-cdp.ps1"
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$WallpaperEngineDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ProjectRoot))
$WallpaperEngineConfig = Join-Path $WallpaperEngineDir "config.json"
$WallpaperProjectJson = Join-Path $ProjectRoot "project.json"
$RuntimeDir = Join-Path $env:LOCALAPPDATA "NeteaseMusicWallpaper\runtime"
$WatchdogLog = Join-Path $RuntimeDir "bridge-watchdog.log"
$Heartbeat = Join-Path $RuntimeDir "bridge-heartbeat.json"
$PidPath = Join-Path $RuntimeDir "bridge.pid"
$LastWallpaperEngineRestart = [DateTime]::MinValue
$LastCdpCheck = [DateTime]::MinValue
$LastCdpRecovery = [DateTime]::MinValue
$CdpFailureCount = 0

New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null

$mutex = New-Object System.Threading.Mutex($false, "Local\NeteaseMusicReactiveWallpaperWatchdog")
if (-not $mutex.WaitOne(0)) {
  exit 0
}

function Write-WatchdogLog {
  param([string]$Message)
  $line = "[{0}] pid={1} {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $PID, $Message
  try {
    [System.IO.File]::AppendAllText($WatchdogLog, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
  } catch {}
}

function Get-BridgeProcesses {
  $currentPid = $PID
  try {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop | Where-Object {
      $_.ProcessId -ne $currentPid -and
      $_.CommandLine -like '*-File*netease-bridge.ps1*' -and
      $_.CommandLine -notlike '*-Command*'
    })
  } catch {
    Write-WatchdogLog ("process scan failed: {0}" -f $_.Exception.Message)
    if (Test-Path -LiteralPath $PidPath) {
      try {
        $bridgePid = [int](Get-Content -LiteralPath $PidPath -Raw -Encoding UTF8)
        $process = Get-Process -Id $bridgePid -ErrorAction SilentlyContinue
        if ($process -and $process.Id -ne $currentPid) {
          return @($process)
        }
      } catch {}
    }
    return @()
  }
}

function Get-ProcessId {
  param($Process)

  if ($null -ne $Process.ProcessId) {
    return [int]$Process.ProcessId
  }
  if ($null -ne $Process.Id) {
    return [int]$Process.Id
  }
  return 0
}

function Get-RuntimeServerProcesses {
  try {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction Stop | Where-Object {
      $_.CommandLine -like "*netease-runtime-server.js*"
    })
  } catch {
    Write-WatchdogLog ("runtime server scan failed: {0}" -f $_.Exception.Message)
    return @()
  }
}

function Test-CdpPort {
  try {
    $response = Invoke-WebRequest -Uri "http://127.0.0.1:9222/json/version" -UseBasicParsing -TimeoutSec 2
    return $response.StatusCode -eq 200
  } catch {
    return $false
  }
}

function Test-NeteaseRunning {
  return @(Get-Process -Name cloudmusic -ErrorAction SilentlyContinue).Count -gt 0
}

function Repair-CdpIfNeeded {
  $now = Get-Date
  if (($now - $script:LastCdpCheck).TotalSeconds -lt $CdpCheckIntervalSeconds) {
    return
  }
  $script:LastCdpCheck = $now

  if (Test-CdpPort) {
    if ($script:CdpFailureCount -gt 0) {
      Write-WatchdogLog "CDP recovered"
    }
    $script:CdpFailureCount = 0
    return
  }

  if (-not (Test-NeteaseRunning)) {
    $script:CdpFailureCount = 0
    return
  }

  $script:CdpFailureCount += 1
  Write-WatchdogLog "CDP unavailable while NetEase is running; failure=$($script:CdpFailureCount)/$CdpFailureThreshold"
  if ($script:CdpFailureCount -lt $CdpFailureThreshold) {
    return
  }
  if (($now - $script:LastCdpRecovery).TotalMinutes -lt $CdpRecoveryCooldownMinutes) {
    Write-WatchdogLog "CDP recovery skipped; cooldown active"
    return
  }
  if (-not (Test-Path -LiteralPath $EnsureCdpScript)) {
    Write-WatchdogLog "CDP recovery script missing"
    return
  }

  $args = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $EnsureCdpScript + '" -RestartIfNeeded'
  Write-WatchdogLog "starting CDP recovery"
  $recovery = Start-Process -FilePath "powershell.exe" -ArgumentList $args -WindowStyle Hidden -Wait -PassThru
  $script:LastCdpRecovery = $now
  $script:CdpFailureCount = 0
  Write-WatchdogLog "CDP recovery finished exitCode=$($recovery.ExitCode)"
}

function Get-HeartbeatAgeSeconds {
  if (-not (Test-Path -LiteralPath $Heartbeat)) {
    return [int]::MaxValue
  }
  try {
    $json = Get-Content -LiteralPath $Heartbeat -Raw -Encoding UTF8 | ConvertFrom-Json
    $updatedAt = [int64]$json.updatedAt
    if ($updatedAt -le 0) {
      return [int]::MaxValue
    }
    return [int](([DateTimeOffset]::Now.ToUnixTimeMilliseconds() - $updatedAt) / 1000)
  } catch {
    return [int]::MaxValue
  }
}

function Start-Bridge {
  New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
  $log = Join-Path $RuntimeDir "bridge.log"
  $err = Join-Path $RuntimeDir "bridge.err.log"
  $args = '-NoProfile -ExecutionPolicy Bypass -File "' + $BridgeScript + '" -IntervalSeconds ' + $BridgeIntervalSeconds
  Start-Process -FilePath "powershell.exe" -ArgumentList $args -WorkingDirectory $ProjectRoot -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError $err | Out-Null
  Write-WatchdogLog "started bridge interval=$BridgeIntervalSeconds"
}

function Start-RuntimeServer {
  if (-not (Test-Path -LiteralPath $RuntimeServerScript)) {
    Write-WatchdogLog "runtime server script missing"
    return
  }

  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) {
    Write-WatchdogLog "node missing; runtime server not started"
    return
  }

  $log = Join-Path $RuntimeDir "runtime-server.log"
  $err = Join-Path $RuntimeDir "runtime-server.err.log"
  $args = '"' + $RuntimeServerScript + '" 39487'
  Start-Process -FilePath $node.Source -ArgumentList $args -WorkingDirectory $ProjectRoot -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError $err | Out-Null
  Write-WatchdogLog "started runtime server"
}

function Repair-WallpaperEngineConfig {
  if (-not (Test-Path -LiteralPath $WallpaperEngineConfig)) {
    return $false
  }

  $paths = @($WallpaperEngineConfig)
  $dailyBackup = Join-Path $WallpaperEngineDir ("config_backups\config_{0}.json" -f (Get-Date -Format "yyyy-MM-dd"))
  if (Test-Path -LiteralPath $dailyBackup) {
    $paths += $dailyBackup
  }

  $changedAny = $false
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

  foreach ($path in $paths) {
    try {
      $text = [System.IO.File]::ReadAllText($path)
      $fixed = $text
      $fixed = [regex]::Replace($fixed, '"overridelockscreen"\s*:\s*true', '"overridelockscreen" : false')
      $fixed = [regex]::Replace($fixed, '"overridewallpaper"\s*:\s*true', '"overridewallpaper" : false')
      $fixed = [regex]::Replace($fixed, '"adjustdwmcolormode"\s*:\s*"[^"]*"', '"adjustdwmcolormode" : "disabled"')
      $fixed = [regex]::Replace($fixed, '"showmonitorselectiononstart"\s*:\s*true', '"showmonitorselectiononstart" : false')
      $fixed = [regex]::Replace($fixed, '"showonstartup"\s*:\s*true', '"showonstartup" : false')

      if ($fixed -ne $text) {
        [System.IO.File]::WriteAllText($path, $fixed, $utf8NoBom)
        Write-WatchdogLog ("repaired Wallpaper Engine config: {0}" -f $path)
        $changedAny = $true
      }
    } catch {
      Write-WatchdogLog ("Wallpaper Engine config repair failed for {0}: {1}" -f $path, $_.Exception.Message)
    }
  }

  return $changedAny
}

function Repair-ProjectAudioConfig {
  if (-not (Test-Path -LiteralPath $WallpaperProjectJson)) {
    return $false
  }

  try {
    $text = [System.IO.File]::ReadAllText($WallpaperProjectJson)
    $project = $text | ConvertFrom-Json
    $changed = $false

    if (-not $project.PSObject.Properties["supportsaudioprocessing"]) {
      $project | Add-Member -NotePropertyName "supportsaudioprocessing" -NotePropertyValue $true
      $changed = $true
    } elseif ($project.supportsaudioprocessing -ne $true) {
      $project.supportsaudioprocessing = $true
      $changed = $true
    }

    if (-not $project.PSObject.Properties["general"] -or -not $project.general) {
      $project | Add-Member -NotePropertyName "general" -NotePropertyValue ([pscustomobject]@{})
      $changed = $true
    }

    if (-not $project.general.PSObject.Properties["supportsaudioprocessing"]) {
      $project.general | Add-Member -NotePropertyName "supportsaudioprocessing" -NotePropertyValue $true
      $changed = $true
    } elseif ($project.general.supportsaudioprocessing -ne $true) {
      $project.general.supportsaudioprocessing = $true
      $changed = $true
    }

    if ($changed) {
      $json = $project | ConvertTo-Json -Depth 100
      [System.IO.File]::WriteAllText($WallpaperProjectJson, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
      Write-WatchdogLog ("repaired project audio config: {0}" -f $WallpaperProjectJson)
    }

    return $changed
  } catch {
    Write-WatchdogLog ("project audio config repair failed: {0}" -f $_.Exception.Message)
    return $false
  }
}

function Restart-WallpaperEngineIfNeeded {
  param([bool]$ConfigChanged)

  if (-not $ConfigChanged) {
    return
  }

  $now = Get-Date
  if (($now - $script:LastWallpaperEngineRestart).TotalMinutes -lt 5) {
    Write-WatchdogLog "Wallpaper Engine restart skipped; recent restart cooldown active"
    return
  }

  $wallpaperExe = Join-Path $WallpaperEngineDir "wallpaper64.exe"
  if (-not (Test-Path -LiteralPath $wallpaperExe)) {
    Write-WatchdogLog "Wallpaper Engine executable missing; restart skipped"
    return
  }

  $running = @(Get-Process wallpaper64,wallpaper32,webwallpaper32,ui32 -ErrorAction SilentlyContinue)
  if ($running.Count -eq 0) {
    return
  }

  Write-WatchdogLog "restarting Wallpaper Engine to apply disabled system image overrides"
  foreach ($process in $running) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Seconds 2
  Start-Process -FilePath $wallpaperExe -ArgumentList "-silent" -WindowStyle Hidden | Out-Null
  Start-Sleep -Seconds 5

  if (Test-Path -LiteralPath $WallpaperProjectJson) {
    & $wallpaperExe -control openWallpaper -file $WallpaperProjectJson -monitor 0 | Out-Null
  }

  $script:LastWallpaperEngineRestart = $now
}

try {
  Write-WatchdogLog "started watchdog"
  while ($true) {
    try {
      $wallpaperConfigChanged = Repair-WallpaperEngineConfig
      $projectAudioConfigChanged = Repair-ProjectAudioConfig
      Restart-WallpaperEngineIfNeeded -ConfigChanged ($wallpaperConfigChanged -or $projectAudioConfigChanged)
      Repair-CdpIfNeeded

      $servers = Get-RuntimeServerProcesses
      $bridges = Get-BridgeProcesses
      $age = Get-HeartbeatAgeSeconds

      if ($servers.Count -eq 0) {
        Write-WatchdogLog "runtime server missing"
        Start-RuntimeServer
      }

      if ($bridges.Count -eq 0) {
        Write-WatchdogLog "bridge missing; heartbeatAge=$age"
        Start-Bridge
      } elseif ($age -gt $StaleSeconds) {
        Write-WatchdogLog "bridge stale; heartbeatAge=$age; stopping $($bridges.Count) process(es)"
        foreach ($bridge in $bridges) {
          $bridgePid = Get-ProcessId -Process $bridge
          if ($bridgePid -gt 0) {
            Stop-Process -Id $bridgePid -Force -ErrorAction SilentlyContinue
          }
        }
        Start-Sleep -Seconds 1
        Start-Bridge
      }
    } catch {
      Write-WatchdogLog ("watchdog loop error: {0}" -f $_.Exception.Message)
    }

    Start-Sleep -Seconds $CheckIntervalSeconds
  }
} finally {
  Write-WatchdogLog "stopped watchdog"
  try {
    $mutex.ReleaseMutex() | Out-Null
    $mutex.Dispose()
  } catch {}
}
