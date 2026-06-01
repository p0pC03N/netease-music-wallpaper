param(
  [int]$IntervalSeconds = 3,
  [switch]$Once
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RuntimeDir = Join-Path $env:LOCALAPPDATA "NeteaseMusicWallpaper\runtime"
$RuntimeServerUrl = "http://127.0.0.1:39487"
$NowPlayingJs = Join-Path $RuntimeDir "now-playing.js"
$NowPlayingJson = Join-Path $RuntimeDir "now-playing.json"
$CoverPath = Join-Path $RuntimeDir "cover.jpg"
$HeartbeatPath = Join-Path $RuntimeDir "bridge-heartbeat.json"
$StateLogPath = Join-Path $RuntimeDir "bridge-state.log"
$PidPath = Join-Path $RuntimeDir "bridge.pid"
$NeteaseRoot = Join-Path $env:LOCALAPPDATA "NetEase\CloudMusic"
$PlayingListPath = Join-Path $NeteaseRoot "webdata\file\playingList"
$CacheDir = Join-Path $NeteaseRoot "Cache\Cache"
$WebDbPath = Join-Path $NeteaseRoot "Library\webdb.dat"
$Sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
$Node = Get-Command node -ErrorAction SilentlyContinue
$CdpHelper = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "netease-cdp-now-playing.js"
$script:LastCoverSongId = ""
$script:LastCoverRef = ""
$script:LastLoggedSongId = ""
$script:LastAcceptedPayload = $null
$script:PendingWeakSongId = ""
$script:PendingWeakSource = ""
$script:PendingWeakCount = 0
$script:MirrorRuntimeDirs = @()
$script:BridgeMutex = $null
$script:HasBridgeMutex = $false

New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null

function Initialize-MirrorRuntimeDirs {
  $dirs = New-Object System.Collections.Generic.List[string]
  $dirs.Add($RuntimeDir)
  $script:MirrorRuntimeDirs = @($dirs | Select-Object -Unique)
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

  $payload = [ordered]@{
    id = ""
    title = ""
    artist = ""
    album = ""
    cover = ""
    durationSeconds = 0
    playback = "waiting"
    source = "netease-bridge"
    reason = $Reason
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
  try {
    [System.IO.File]::WriteAllText($temp, $Text, [System.Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path) {
      [System.IO.File]::Replace($temp, $Path, $null)
    } else {
      [System.IO.File]::Move($temp, $Path)
    }
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

Initialize-MirrorRuntimeDirs
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

function Convert-TrackToSong {
  param($Track)

  $artists = @()
  if ($Track.artists) {
    $artists = $Track.artists
  } elseif ($Track.ar) {
    $artists = $Track.ar
  }

  $album = $Track.album
  if (-not $album -and $Track.al) {
    $album = $Track.al
  }

  $title = [string]$Track.name
  if (-not $title) {
    $title = [string]$Track.mainTitle
  }

  $albumName = ""
  $coverUrl = ""
  if ($album) {
    $albumName = [string]$album.name
    if (-not $albumName) {
      $albumName = [string]$album.albumName
    }
    $coverUrl = [string]$album.picUrl
    if (-not $coverUrl) {
      $coverUrl = [string]$album.cover
    }
    if (-not $coverUrl) {
      $coverUrl = [string]$album.blurPicUrl
    }
  }

  $duration = 0
  if ($Track.duration) {
    $duration = [double]$Track.duration
  } elseif ($Track.dt) {
    $duration = [double]$Track.dt
  }

  return [ordered]@{
    id = [string]$Track.id
    title = $title
    artist = [string](($artists | ForEach-Object { $_.name }) -join ", ")
    album = $albumName
    coverUrl = $coverUrl
    durationSeconds = [math]::Round($duration / 1000, 3)
  }
}

function Copy-LockedFile {
  param(
    [Parameter(Mandatory=$true)][string]$Source,
    [Parameter(Mandatory=$true)][string]$Destination
  )

  $inputStream = [System.IO.File]::Open($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $outputStream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
      $inputStream.CopyTo($outputStream)
    } finally {
      $outputStream.Dispose()
    }
  } finally {
    $inputStream.Dispose()
  }
}

function Invoke-WebDbQuery {
  param([string]$Query)

  if (-not $Sqlite -or -not (Test-Path -LiteralPath $WebDbPath)) {
    return $null
  }

  $tempDb = Join-Path $RuntimeDir ("webdb-{0}.dat" -f ([guid]::NewGuid().ToString("N")))
  try {
    Copy-LockedFile -Source $WebDbPath -Destination $tempDb
    $output = & $Sqlite.Source -json $tempDb $Query 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
      return $null
    }
    $json = ($output -join "`n").Trim()
    if (-not $json) {
      return $null
    }
    return $json | ConvertFrom-Json
  } catch {
    return $null
  } finally {
    Remove-Item -LiteralPath $tempDb -Force -ErrorAction SilentlyContinue
  }
}

function Convert-WebDbRowToSong {
  param($Row)

  if (-not $Row -or -not $Row.jsonStr) {
    return $null
  }

  try {
    $track = $Row.jsonStr | ConvertFrom-Json
    $song = Convert-TrackToSong -Track $track
    $song.playtime = $Row.playtime
    return $song
  } catch {
    return $null
  }
}

function Invoke-Utf8Json {
  param([string]$Url)

  $request = [System.Net.HttpWebRequest]::Create($Url)
  $request.Method = "GET"
  $request.Timeout = 15000
  $request.ReadWriteTimeout = 15000
  $request.UserAgent = "Mozilla/5.0"
  $request.Referer = "https://music.163.com/"

  $webResponse = $request.GetResponse()
  try {
    $stream = $webResponse.GetResponseStream()
    try {
      $memory = New-Object System.IO.MemoryStream
      try {
        $stream.CopyTo($memory)
        $text = [System.Text.Encoding]::UTF8.GetString($memory.ToArray())
      } finally {
        $memory.Dispose()
      }
    } finally {
      $stream.Dispose()
    }
  } finally {
    $webResponse.Dispose()
  }

  return $text | ConvertFrom-Json
}

function Get-SongFromWebDbHistory {
  $rows = Invoke-WebDbQuery -Query "select playtime,id,jsonStr from historyTracks order by playtime desc limit 5;"
  if (-not $rows -or $rows.Count -eq 0) {
    return $null
  }

  foreach ($row in @($rows)) {
    $song = Convert-WebDbRowToSong -Row $row
    if ($song -and $song.id) {
      $song.sourceFile = "Library\webdb.dat:historyTracks"
      $song.sourceTimeMs = [int64]$row.playtime
      $song.sourceFileTime = ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$row.playtime).LocalDateTime.ToString("s"))
      return $song
    }
  }

  return $null
}

function Get-SongFromWebDbPlayingCount {
  $rows = Invoke-WebDbQuery -Query "select updateTime,resourceId from playingCount order by updateTime desc limit 5;"
  if (-not $rows -or $rows.Count -eq 0) {
    return $null
  }

  foreach ($row in @($rows)) {
    $songId = [string]$row.resourceId
    if (-not $songId) {
      continue
    }

    $trackRows = Invoke-WebDbQuery -Query ("select 0 as playtime,id,jsonStr from dbTrack where id='{0}' limit 1;" -f ($songId -replace "'", "''"))
    if ($trackRows -and $trackRows.Count -gt 0) {
      $song = Convert-WebDbRowToSong -Row @($trackRows)[0]
      if ($song -and $song.id) {
        $song.sourceFile = "Library\webdb.dat:playingCount"
        $song.sourceTimeMs = [int64]$row.updateTime
        $song.sourceFileTime = ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$row.updateTime).LocalDateTime.ToString("s"))
        return $song
      }
    }
  }

  return $null
}

function Get-SongFromPlayingListById {
  param([string]$SongId)

  if (-not (Test-Path -LiteralPath $PlayingListPath)) {
    return $null
  }

  try {
    $playing = Get-Content -LiteralPath $PlayingListPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $item = $playing.list | Where-Object { $_.track -and [string]$_.track.id -eq $SongId } | Select-Object -First 1
    if ($item) {
      return Convert-TrackToSong -Track $item.track
    }
  } catch {
    return $null
  }

  return $null
}

function Get-SongFromPlayingListMarker {
  if (-not (Test-Path -LiteralPath $PlayingListPath)) {
    return $null
  }

  try {
    $playing = Get-Content -LiteralPath $PlayingListPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $played = @($playing.list | Where-Object { $_.track -and $_.isPlayedOnce -eq $true })
    if ($played.Count -eq 1) {
      $item = $played[0]
    } elseif ($played.Count -gt 1) {
      $item = $played | Sort-Object displayOrder | Select-Object -Last 1
    } else {
      return $null
    }
    if (-not $item) {
      return $null
    }
    return Convert-TrackToSong -Track $item.track
  } catch {
    return $null
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

function Get-SongFromAudioCache {
  if (-not (Test-Path -LiteralPath $CacheDir)) {
    return $null
  }

  $recent = Get-ChildItem -LiteralPath $CacheDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(\d+)-\d+-[a-f0-9]+\.uc$' -and $_.LastWriteTime -gt (Get-Date).AddMinutes(-30) } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 5

  foreach ($file in $recent) {
    if ($file.Name -match '^(\d+)-') {
      $songId = $Matches[1]
      $song = Get-SongFromPlayingListById -SongId $songId
      if (-not $song) {
        $song = Get-SongFromApi -SongId $songId
      }
      if ($song) {
        $song.sourceFile = $file.Name
        $song.sourceTimeMs = [DateTimeOffset]::new($file.LastWriteTime).ToUnixTimeMilliseconds()
        $song.sourceFileTime = $file.LastWriteTime.ToString("s")
        $song.sourceSize = $file.Length
        return $song
      }
    }
  }

  return $null
}

function Get-SongFromRecentIndexCache {
  if (-not (Test-Path -LiteralPath $CacheDir)) {
    return $null
  }

  $recent = Get-ChildItem -LiteralPath $CacheDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(\d+)-\d+-[a-f0-9]+\.(idx|info)$' -and $_.LastWriteTime -gt (Get-Date).AddMinutes(-10) } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 8

  foreach ($file in $recent) {
    if ($file.Name -match '^(\d+)-') {
      $songId = $Matches[1]
      $song = Get-SongFromPlayingListById -SongId $songId
      if (-not $song) {
        $song = Get-SongFromApi -SongId $songId
      }
      if ($song) {
        $song.sourceFile = $file.Name
        $song.sourceTimeMs = [DateTimeOffset]::new($file.LastWriteTime).ToUnixTimeMilliseconds()
        $song.sourceFileTime = $file.LastWriteTime.ToString("s")
        $song.sourceSize = $file.Length
        return $song
      }
    }
  }

  return $null
}

function Test-WeakSource {
  param([string]$Source)
  return $Source -and $Source -ne "netease-cdp"
}

function Resolve-StableSong {
  param(
    $Song,
    [string]$Source
  )

  if (-not $Song -or -not $Song.id) {
    return $null
  }

  if (-not (Test-WeakSource -Source $Source)) {
    $script:PendingWeakSongId = ""
    $script:PendingWeakSource = ""
    $script:PendingWeakCount = 0
    return $Song
  }

  if (-not $script:LastAcceptedPayload -or -not $script:LastAcceptedPayload.id) {
    $script:PendingWeakSongId = ""
    $script:PendingWeakSource = ""
    $script:PendingWeakCount = 0
    return $Song
  }

  if ([string]$script:LastAcceptedPayload.id -eq [string]$Song.id) {
    $script:PendingWeakSongId = ""
    $script:PendingWeakSource = ""
    $script:PendingWeakCount = 0
    return $Song
  }

  if ($script:PendingWeakSongId -eq [string]$Song.id -and $script:PendingWeakSource -eq $Source) {
    $script:PendingWeakCount += 1
  } else {
    $script:PendingWeakSongId = [string]$Song.id
    $script:PendingWeakSource = $Source
    $script:PendingWeakCount = 1
  }

  if ($script:PendingWeakCount -lt 3) {
    Write-StateLog ("hold weak source change candidate id={0} source={1} count={2}; keeping id={3} source={4}" -f $Song.id, $Source, $script:PendingWeakCount, $script:LastAcceptedPayload.id, $script:LastAcceptedPayload.source)
    return $null
  }

  Write-StateLog ("accept weak source change id={0} source={1} after {2} confirmations" -f $Song.id, $Source, $script:PendingWeakCount)
  $script:PendingWeakSongId = ""
  $script:PendingWeakSource = ""
  $script:PendingWeakCount = 0
  return $Song
}

function Get-SongFromApi {
  param([string]$SongId)

  $url = "https://music.163.com/api/song/detail/?ids=[$SongId]"
  $response = Invoke-Utf8Json -Url $url

  if (-not $response.songs -or $response.songs.Count -eq 0) {
    return $null
  }

  $song = $response.songs[0]
  return [ordered]@{
    id = [string]$song.id
    title = [string]$song.name
    artist = [string](($song.artists | ForEach-Object { $_.name }) -join ", ")
    album = [string]$song.album.name
    coverUrl = [string]$song.album.picUrl
    durationSeconds = [math]::Round(([double]$song.duration) / 1000, 3)
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

function Update-NowPlaying {
  $song = Get-SongFromCdp
  if ($song) {
    $source = "netease-cdp"
  }

  if (-not $song) {
    $song = Get-SongFromAudioCache
    if ($song) {
      $source = "netease-cache-audio"
    }
  }

  if (-not $song) {
    $song = Get-SongFromWebDbHistory
    if ($song) {
      $source = "netease-webdb-history"
    }
  }

  if (-not $song) {
    $song = Get-SongFromWebDbPlayingCount
    if ($song) {
      $source = "netease-webdb-playingCount"
    }
  }

  if (-not $song) {
    $song = Get-SongFromPlayingListMarker
    if ($song) {
      $source = "netease-playingList-isPlayedOnce"
    }
  }

  if (-not $song) {
    $song = Get-SongFromRecentIndexCache
    if ($song) {
      $source = "netease-cache-index-fallback"
    }
  }
  if (-not $song) {
    Write-EmptyPayload -Reason "No current item found in NetEase webdb, cache, or playingList. Need LevelDB playingInfo decoding."
    return
  }

  $stableSong = Resolve-StableSong -Song $song -Source $source
  if (-not $stableSong) {
    if ($script:LastAcceptedPayload) {
      Write-Payload -Payload $script:LastAcceptedPayload
      Write-Heartbeat -Status "running" -Title $script:LastAcceptedPayload.title -Source $script:LastAcceptedPayload.source -Message ("Holding unstable {0}" -f $source)
    }
    return
  }
  $song = $stableSong

  $cover = Save-Cover -CoverUrl $song.coverUrl -SongId $song.id
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

try {
  do {
    try {
      Update-NowPlaying
    } catch {
      $message = $_.Exception.Message
      Write-EmptyPayload -Reason $message
      Write-Heartbeat -Status "error" -Message $message
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
