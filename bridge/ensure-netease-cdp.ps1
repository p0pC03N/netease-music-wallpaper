param(
  [string]$NeteaseExe = "D:\CloudMusic\cloudmusic.exe",
  [int]$Port = 9222,
  [string]$RemoteAllowOrigins = "",
  [switch]$RestartIfNeeded
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RuntimeDir = Join-Path $env:LOCALAPPDATA "NeteaseMusicWallpaper\runtime"
$LogPath = Join-Path $RuntimeDir "netease-cdp-launch.log"
New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null

if (-not $RemoteAllowOrigins) {
  $RemoteAllowOrigins = "http://127.0.0.1:$Port"
}

function Write-LaunchLog {
  param([string]$Message)
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
  [System.IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Test-CdpPort {
  try {
    $response = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/json/version" -UseBasicParsing -TimeoutSec 2
    return $response.StatusCode -eq 200
  } catch {
    return $false
  }
}

function Resolve-NeteaseExecutable {
  param([string]$PreferredPath)

  $candidates = @(
    $PreferredPath,
    "D:\CloudMusic\cloudmusic.exe",
    (Join-Path $env:LOCALAPPDATA "Programs\NetEase\CloudMusic\cloudmusic.exe"),
    (Join-Path $env:LOCALAPPDATA "NetEase\CloudMusic\cloudmusic.exe"),
    (Join-Path $env:ProgramFiles "NetEase\CloudMusic\cloudmusic.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "NetEase\CloudMusic\cloudmusic.exe")
  ) | Where-Object { $_ } | Select-Object -Unique

  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
      return $candidate
    }
  }

  return $PreferredPath
}

function Get-MainCloudMusicProcesses {
  return @(Get-CimInstance Win32_Process -Filter "Name = 'cloudmusic.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -notmatch '--type='
  })
}

if (Test-CdpPort) {
  Write-LaunchLog "CDP already available on port $Port."
  exit 0
}

$NeteaseExe = Resolve-NeteaseExecutable -PreferredPath $NeteaseExe
if (-not (Test-Path -LiteralPath $NeteaseExe)) {
  Write-LaunchLog "NetEase executable not found: $NeteaseExe"
  exit 1
}

$runningCloudMusic = @(Get-Process -Name cloudmusic,cloudmusic_reporter -ErrorAction SilentlyContinue)
$mainProcesses = Get-MainCloudMusicProcesses
$hasDebugArg = @($mainProcesses | Where-Object { $_.CommandLine -match "--remote-debugging-port=$Port" }).Count -gt 0
if ($hasDebugArg) {
  Write-LaunchLog "NetEase was launched with CDP argument but port $Port is not ready yet."
  exit 0
}

if ($runningCloudMusic.Count -gt 0 -and -not $RestartIfNeeded) {
  Write-LaunchLog "NetEase is running without CDP; use -RestartIfNeeded to relaunch it."
  exit 2
}

if ($runningCloudMusic.Count -gt 0) {
  Write-LaunchLog "Restarting NetEase with CDP port $Port."
  $runningCloudMusic | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
} else {
  Write-LaunchLog "Starting NetEase with CDP port $Port."
}

$launchArgs = @("--remote-debugging-port=$Port")
if ($RemoteAllowOrigins) {
  $launchArgs += "--remote-allow-origins=$RemoteAllowOrigins"
}
Start-Process -FilePath $NeteaseExe -ArgumentList $launchArgs -WindowStyle Hidden
Start-Sleep -Seconds 4

if (Test-CdpPort) {
  Write-LaunchLog "CDP is available on port $Port."
  exit 0
}

Write-LaunchLog "Started NetEase, but CDP port $Port is still unavailable."
exit 3
