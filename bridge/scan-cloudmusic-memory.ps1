param(
  [int]$MaxCandidates = 1200
)

$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ProcMem {
  [Flags]
  public enum ProcessAccessFlags : uint {
    QueryInformation = 0x0400,
    VirtualMemoryRead = 0x0010
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct MEMORY_BASIC_INFORMATION {
    public UIntPtr BaseAddress;
    public UIntPtr AllocationBase;
    public uint AllocationProtect;
    public UIntPtr RegionSize;
    public uint State;
    public uint Protect;
    public uint Type;
  }

  [DllImport("kernel32.dll")]
  public static extern IntPtr OpenProcess(ProcessAccessFlags dwDesiredAccess, bool bInheritHandle, int dwProcessId);

  [DllImport("kernel32.dll")]
  public static extern bool CloseHandle(IntPtr hObject);

  [DllImport("kernel32.dll")]
  public static extern UIntPtr VirtualQueryEx(IntPtr hProcess, UIntPtr lpAddress, out MEMORY_BASIC_INFORMATION lpBuffer, UIntPtr dwLength);

  [DllImport("kernel32.dll")]
  public static extern bool ReadProcessMemory(IntPtr hProcess, UIntPtr lpBaseAddress, byte[] lpBuffer, UIntPtr nSize, out UIntPtr lpNumberOfBytesRead);
}
'@

$neteaseRoot = Join-Path $env:LOCALAPPDATA "NetEase\CloudMusic"
$playingListPath = Join-Path $neteaseRoot "webdata\file\playingList"
if (-not (Test-Path -LiteralPath $playingListPath)) {
  throw "playingList not found: $playingListPath"
}

$playing = Get-Content -LiteralPath $playingListPath -Raw -Encoding UTF8 | ConvertFrom-Json
$candidates = $playing.list |
  Where-Object { $_.track -and $_.track.name } |
  Select-Object -First $MaxCandidates |
  ForEach-Object {
    [pscustomobject]@{
      id = [string]$_.track.id
      name = [string]$_.track.name
      artist = [string](($_.track.artists | ForEach-Object { $_.name }) -join ", ")
      album = [string]$_.track.album.name
      picUrl = [string]$_.track.album.picUrl
      duration = [double]$_.track.duration
    }
  }

$patterns = @()
foreach ($c in $candidates) {
  if ($c.name.Length -ge 2) {
    $patterns += [pscustomobject]@{ Candidate = $c; Kind = "name-utf8"; Bytes = [System.Text.Encoding]::UTF8.GetBytes($c.name) }
    $patterns += [pscustomobject]@{ Candidate = $c; Kind = "name-utf16"; Bytes = [System.Text.Encoding]::Unicode.GetBytes($c.name) }
  }
  if ($c.artist.Length -ge 2) {
    $patterns += [pscustomobject]@{ Candidate = $c; Kind = "artist-utf8"; Bytes = [System.Text.Encoding]::UTF8.GetBytes($c.artist) }
    $patterns += [pscustomobject]@{ Candidate = $c; Kind = "artist-utf16"; Bytes = [System.Text.Encoding]::Unicode.GetBytes($c.artist) }
  }
}

function Index-OfBytes {
  param(
    [byte[]]$Haystack,
    [byte[]]$Needle
  )
  if ($Needle.Length -eq 0 -or $Haystack.Length -lt $Needle.Length) {
    return -1
  }
  $last = $Haystack.Length - $Needle.Length
  for ($i = 0; $i -le $last; $i++) {
    if ($Haystack[$i] -ne $Needle[0]) { continue }
    $ok = $true
    for ($j = 1; $j -lt $Needle.Length; $j++) {
      if ($Haystack[$i + $j] -ne $Needle[$j]) { $ok = $false; break }
    }
    if ($ok) { return $i }
  }
  return -1
}

$scores = @{}
$processes = Get-Process cloudmusic -ErrorAction SilentlyContinue
foreach ($proc in $processes) {
  $handle = [ProcMem]::OpenProcess(
    [ProcMem+ProcessAccessFlags]::QueryInformation -bor [ProcMem+ProcessAccessFlags]::VirtualMemoryRead,
    $false,
    $proc.Id
  )
  if ($handle -eq [IntPtr]::Zero) { continue }
  try {
    $addr = [UIntPtr]::Zero
    $maxAddress = [UInt64]0x00007fffffffffff
    $mbiSize = [UIntPtr]::new([uint64][Runtime.InteropServices.Marshal]::SizeOf([type][ProcMem+MEMORY_BASIC_INFORMATION]))
    while ($addr.ToUInt64() -lt $maxAddress) {
      $mbi = New-Object ProcMem+MEMORY_BASIC_INFORMATION
      $result = [ProcMem]::VirtualQueryEx($handle, $addr, [ref]$mbi, $mbiSize)
      if ($result -eq [UIntPtr]::Zero) { break }

      $base = $mbi.BaseAddress.ToUInt64()
      $size = [Math]::Min([UInt64]$mbi.RegionSize.ToUInt64(), [UInt64](8 * 1024 * 1024))
      $committed = $mbi.State -eq 0x1000
      $readable = ($mbi.Protect -band 0x01) -eq 0 -and ($mbi.Protect -band 0x100) -eq 0
      if ($committed -and $readable -and $size -gt 0) {
        $buffer = New-Object byte[] ([int]$size)
        $read = [UIntPtr]::Zero
        if ([ProcMem]::ReadProcessMemory($handle, $mbi.BaseAddress, $buffer, [UIntPtr]::new($size), [ref]$read) -and $read.ToUInt64() -gt 0) {
          foreach ($p in $patterns) {
            if (Index-OfBytes -Haystack $buffer -Needle $p.Bytes -ge 0) {
              $id = $p.Candidate.id
              if (-not $scores.ContainsKey($id)) {
                $scores[$id] = [pscustomobject]@{
                  candidate = $p.Candidate
                  score = 0
                  hits = New-Object System.Collections.Generic.List[string]
                }
              }
              $weight = if ($p.Kind -like "name-*") { 3 } else { 1 }
              $scores[$id].score += $weight
              $scores[$id].hits.Add("pid=$($proc.Id):$($p.Kind):0x$($base.ToString('x'))")
            }
          }
        }
      }

      $next = $base + [UInt64]$mbi.RegionSize.ToUInt64()
      if ($next -le $base) { break }
      $addr = [UIntPtr]$next
    }
  } finally {
    [void][ProcMem]::CloseHandle($handle)
  }
}

$scores.Values |
  Sort-Object -Property score -Descending |
  Select-Object -First 20 |
  ForEach-Object {
    [pscustomobject]@{
      score = $_.score
      id = $_.candidate.id
      name = $_.candidate.name
      artist = $_.candidate.artist
      album = $_.candidate.album
      hits = ($_.hits | Select-Object -First 8) -join "; "
    }
  } |
  Format-List
