param(
  [int]$IntervalSeconds = 3,
  [int]$ReliableHoldSeconds = 90,
  [switch]$Once
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RuntimeDir = Join-Path $env:LOCALAPPDATA "NeteaseMusicWallpaper\runtime"
$RuntimeServerUrl = "http://127.0.0.1:39487"
$NowPlayingJson = Join-Path $RuntimeDir "now-playing.json"
$CoverPath = Join-Path $RuntimeDir "cover.jpg"
$Node = Get-Command node -ErrorAction SilentlyContinue
$CdpHelper = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "netease-cdp-now-playing.js"
$script:LastCoverSongId = ""
$script:LastCoverRef = ""
$script:LastLoggedSongId = ""
$script:LastAcceptedPayload = $null
$script:LastReliableAt = [DateTimeOffset]::MinValue
$script:PayloadSequence = 0
$script:MirrorRuntimeDirs = @()
$script:BridgeMutex = $null
$script:HasBridgeMutex = $false

New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null

function Initialize-MirrorRuntimeDirs {
  $dirs = New-Object System.Collections.Generic.List[string]
  $dirs.Add($RuntimeDir)
  $script:MirrorRuntimeDirs = @($dirs | Select-Object -Unique)
}

function Remove-StaleRuntimeFiles {
  $patterns = @("webdb-*.dat", "cover-*.jpg", ".*.tmp", ".*.bak")
  foreach ($pattern in $patterns) {
    Get-ChildItem -LiteralPath $RuntimeDir -Filter $pattern -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-2) } |
      Remove-Item -Force -ErrorAction SilentlyContinue
  }
}

function Write-StateLog {
  param([string]$Message)

  $line = "[{0}] pid={1} {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $PID, $Message
  foreach ($dir in $script:MirrorRuntimeDirs) {
    try {
      [System.IO.File]::AppendAllText((Join-Path $dir "bridge-state.log"), $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    } catch {}
  }
}

function Write-Heartbeat {
  param(
    [string]$Status,
    [string]$Title = "",
    [string]$Source = "",
    [string]$Message = ""
  )

  $payload = [ordered]@{
    pid = $PID
    status = $Status
    title = $Title
    source = $Source
    message = $Message
    intervalSeconds = $IntervalSeconds
    updatedAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    updatedAtText = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  }
  $json = Convert-ToSafeJson $payload
  foreach ($dir in $script:MirrorRuntimeDirs) {
    try {
      Write-Utf8FileAtomic -Path (Join-Path $dir "bridge-heartbeat.json") -Text $json
      Write-Utf8FileAtomic -Path (Join-Path $dir "bridge.pid") -Text ([string]$PID)
    } catch {}
  }
}

function Initialize-SingleInstance {
  if ($Once) {
    return
  }

  $script:BridgeMutex = New-Object System.Threading.Mutex($false, "Local\NeteaseMusicReactiveWallpaperBridge")
  $script:HasBridgeMutex = $script:BridgeMutex.WaitOne(0)
  if (-not $script:HasBridgeMutex) {
    Write-StateLog "another bridge instance is already running; exiting"
    Write-Heartbeat -Status "duplicate-exit" -Message "Another bridge instance is already running."
    exit 0
  }
}

function Write-EmptyPayload {
  param([string]$Reason)

  $script:PayloadSequence += 1
  $payload = [ordered]@{
    id = ""
    title = ""
    artist = ""
    album = ""
    cover = ""
    durationSeconds = 0
    playback = "waiting"
    source = "netease-bridge"
    confidence = "none"
    degraded = $true
    reason = $Reason
    sequence = $script:PayloadSequence
    updatedAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
  }
  Write-Payload -Payload $payload
  Write-Heartbeat -Status "waiting" -Message $Reason
}

function Convert-ToSafeJson {
  param($Value)
  return ($Value | ConvertTo-Json -Depth 12 -Compress)
}

function Write-Utf8FileAtomic {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Text
  )

  $dir = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $temp = Join-Path $dir (".{0}.{1}.tmp" -f ([IO.Path]::GetFileName($Path)), ([guid]::NewGuid().ToString("N")))
  $backup = Join-Path $dir (".{0}.{1}.bak" -f ([IO.Path]::GetFileName($Path)), ([guid]::NewGuid().ToString("N")))
  try {
    [System.IO.File]::WriteAllText($temp, $Text, [System.Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path) {
      [System.IO.File]::Replace($temp, $Path, $backup)
    } else {
      [System.IO.File]::Move($temp, $Path)
    }
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
  }
}

Initialize-MirrorRuntimeDirs
Remove-StaleRuntimeFiles
Initialize-SingleInstance
Write-StateLog "started from $ProjectRoot"
Write-Heartbeat -Status "starting" -Message "Bridge process started."

function Write-Payload {
  param($Payload)

  $json = Convert-ToSafeJson $Payload
  $js = @"
window.__NETEASE_NOW_PLAYING__ = $json;
window.dispatchEvent(new CustomEvent("netease-now-playing", { detail: window.__NETEASE_NOW_PLAYING__ }));
"@
  foreach ($dir in $script:MirrorRuntimeDirs) {
    try {
      Write-Utf8FileAtomic -Path (Join-Path $dir "now-playing.json") -Text $json
      Write-Utf8FileAtomic -Path (Join-Path $dir "now-playing.js") -Text $js
    } catch {}
  }
}

function Set-PayloadProperty {
  param(
    $Payload,
    [string]$Name,
    $Value
  )

  if ($Payload.PSObject.Properties[$Name]) {
    $Payload.$Name = $Value
  } else {
    $Payload | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function Initialize-LastReliablePayload {
  if (-not (Test-Path -LiteralPath $NowPlayingJson)) {
    return
  }

  try {
    $payload = Get-Content -LiteralPath $NowPlayingJson -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($payload.sequence) {
      $script:PayloadSequence = [int64]$payload.sequence
    }
    if ($payload.id -and $payload.source -eq "netease-cdp") {
      $reliableAtMs = if ($payload.reliableAt) { [int64]$payload.reliableAt } else { [int64]$payload.updatedAt }
      $reliableAt = [DateTimeOffset]::FromUnixTimeMilliseconds($reliableAtMs)
      if (([DateTimeOffset]::Now - $reliableAt).TotalSeconds -le $ReliableHoldSeconds) {
        $script:LastAcceptedPayload = $payload
        $script:LastReliableAt = $reliableAt
        Write-StateLog ("restored reliable payload id={0} ageSeconds={1:n0}" -f $payload.id, ([DateTimeOffset]::Now - $reliableAt).TotalSeconds)
      }
    }
  } catch {
    Write-StateLog ("failed to restore reliable payload: {0}" -f $_.Exception.Message)
  }
}

function Sync-CoverToMirrors {
  foreach ($dir in $script:MirrorRuntimeDirs) {
    if ($dir -eq $RuntimeDir) {
      continue
    }
    try {
      Copy-Item -LiteralPath $CoverPath -Destination (Join-Path $dir "cover.jpg") -Force -ErrorAction Stop
    } catch {}
  }
}

function Get-SongFromCdp {
  if (-not $Node -or -not (Test-Path -LiteralPath $CdpHelper)) {
    return $null
  }

  try {
    $output = & $Node.Source $CdpHelper 9222 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
      return $null
    }

    $json = ($output -join "`n").Trim()
    if (-not $json) {
      return $null
    }

    $song = $json | ConvertFrom-Json
    if (-not $song -or -not $song.id) {
      return $null
    }

    return [ordered]@{
      id = [string]$song.id
      title = [string]$song.title
      artist = [string]$song.artist
      album = [string]$song.album
      coverUrl = [string]$song.coverUrl
      durationSeconds = [double]$song.durationSeconds
      playback = [string]$song.playback
      sourceFile = [string]$song.sourceFile
      sourceFileTime = [string]$song.sourceFileTime
      sourceState = $song.sourceState
      currentOrder = $song.currentOrder
      playlist = @($song.playlist)
      sourceTimeMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    }
  } catch {
    return $null
  }
}

function Save-Cover {
  param(
    [string]$CoverUrl,
    [string]$SongId
  )

  if (-not $CoverUrl) {
    return ""
  }

  if ($script:LastCoverSongId -eq $SongId -and (Test-Path -LiteralPath $CoverPath)) {
    $existing = Get-Item -LiteralPath $CoverPath -ErrorAction SilentlyContinue
    if ($existing -and $existing.Length -gt 1024 -and $script:LastCoverRef) {
      Sync-CoverToMirrors
      return $script:LastCoverRef
    }
  }

  $coverWithSize = $CoverUrl
  if ($coverWithSize -notmatch "\?") {
    $coverWithSize = "${coverWithSize}?param=800y800"
  }

  $tempCover = Join-Path $RuntimeDir ("cover-{0}.jpg" -f ([guid]::NewGuid().ToString("N")))
  try {
    Write-Heartbeat -Status "working" -Title $SongId -Source "netease-cdp" -Message "Downloading cover."
    Invoke-WebRequest -Uri $coverWithSize -OutFile $tempCover -Headers @{
      "User-Agent" = "Mozilla/5.0"
      "Referer" = "https://music.163.com/"
    } -UseBasicParsing -TimeoutSec 20

    $downloaded = Get-Item -LiteralPath $tempCover -ErrorAction Stop
    if ($downloaded.Length -le 1024) {
      Remove-Item -LiteralPath $tempCover -Force -ErrorAction SilentlyContinue
      return $CoverUrl
    }

    Move-Item -LiteralPath $tempCover -Destination $CoverPath -Force
    Sync-CoverToMirrors
    $script:LastCoverSongId = $SongId
    $script:LastCoverRef = "$RuntimeServerUrl/cover.jpg?v=$SongId"
    return $script:LastCoverRef
  } catch {
    Remove-Item -LiteralPath $tempCover -Force -ErrorAction SilentlyContinue
    return $CoverUrl
  }
}

function Write-DegradedOrWaiting {
  param([string]$Reason)

  if ($script:LastAcceptedPayload -and $script:LastAcceptedPayload.id -and $script:LastReliableAt -ne [DateTimeOffset]::MinValue) {
    $ageSeconds = ([DateTimeOffset]::Now - $script:LastReliableAt).TotalSeconds
    if ($ageSeconds -le $ReliableHoldSeconds) {
      $script:PayloadSequence += 1
      $payload = $script:LastAcceptedPayload | ConvertTo-Json -Depth 12 | ConvertFrom-Json
      Set-PayloadProperty -Payload $payload -Name "updatedAt" -Value ([DateTimeOffset]::Now.ToUnixTimeMilliseconds())
      Set-PayloadProperty -Payload $payload -Name "sequence" -Value $script:PayloadSequence
      Set-PayloadProperty -Payload $payload -Name "confidence" -Value "high"
      Set-PayloadProperty -Payload $payload -Name "degraded" -Value $true
      Set-PayloadProperty -Payload $payload -Name "reason" -Value $Reason
      $script:LastAcceptedPayload = $payload
      Write-Payload -Payload $payload
      Write-Heartbeat -Status "degraded" -Title $payload.title -Source $payload.source -Message $Reason
      return
    }
  }

  Write-EmptyPayload -Reason $Reason
}

function Update-NowPlaying {
  Write-Heartbeat -Status "checking" -Message "Reading current NetEase track from CDP."
  $song = Get-SongFromCdp
  if (-not $song) {
    Write-DegradedOrWaiting -Reason "NetEase CDP is unavailable; refusing unreliable cache and history fallbacks."
    return
  }

  $source = "netease-cdp"
  $nowMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
  $script:LastReliableAt = [DateTimeOffset]::FromUnixTimeMilliseconds($nowMs)
  $cover = Save-Cover -CoverUrl $song.coverUrl -SongId $song.id
  $script:PayloadSequence += 1
  $payload = [ordered]@{
    id = $song.id
    title = $song.title
    artist = $song.artist
    album = $song.album
    cover = $cover
    coverUrl = $song.coverUrl
    durationSeconds = $song.durationSeconds
    playback = if ($song.playback) { $song.playback } else { "playing" }
    source = $source
    confidence = "high"
    degraded = $false
    reliableAt = $nowMs
    sequence = $script:PayloadSequence
    sourceFile = $song.sourceFile
    sourceFileTime = $song.sourceFileTime
    sourceSize = $song.sourceSize
    sourceState = $song.sourceState
    currentOrder = $song.currentOrder
    playlist = @($song.playlist)
    updatedAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
  }
  $script:LastAcceptedPayload = $payload
  Write-Payload -Payload $payload
  Write-Heartbeat -Status "running" -Title $payload.title -Source $payload.source
  if ($script:LastLoggedSongId -ne [string]$payload.id) {
    Write-StateLog ("song id={0} source={1} title={2} artist={3}" -f $payload.id, $payload.source, $payload.title, $payload.artist)
    Write-Host ("[{0}] {1} - {2}" -f (Get-Date -Format "HH:mm:ss"), $payload.title, $payload.artist)
    $script:LastLoggedSongId = [string]$payload.id
  }
}

Initialize-LastReliablePayload

try {
  do {
    try {
      Update-NowPlaying
    } catch {
      $message = $_.Exception.Message
      Write-DegradedOrWaiting -Reason $message
      Write-StateLog ("error: {0}" -f $message)
      Write-Warning $message
    }

    if ($Once) {
      break
    }
    Start-Sleep -Seconds $IntervalSeconds
  } while ($true)
} finally {
  Write-StateLog "stopped"
  Write-Heartbeat -Status "stopped" -Message "Bridge process stopped."
  if ($script:HasBridgeMutex -and $script:BridgeMutex) {
    try {
      $script:BridgeMutex.ReleaseMutex() | Out-Null
      $script:BridgeMutex.Dispose()
    } catch {}
  }
}
