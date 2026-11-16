# Joy of Painting local helper for Windows
# Uses built-in Windows PowerShell/.NET and Win32 APIs; no Python or EXE.
$ErrorActionPreference = "Stop"
$Origin = "https://joy-of-painting-guide.onrender.com"
$Listener = [System.Net.HttpListener]::new()
$Listener.Prefixes.Add("http://127.0.0.1:8765/")
$Listener.Start()
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class JoyPaintWin32 {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
}
"@
$script:Armed = $false
$script:Label = "target"
$script:PreviousLeft = $false
$script:LastClick = $null
function Send-Json($Context, [int]$Status, $Data) {
  $bytes = [Text.Encoding]::UTF8.GetBytes(($Data | ConvertTo-Json -Compress -Depth 5))
  $Context.Response.StatusCode = $Status
  $Context.Response.ContentType = "application/json; charset=utf-8"
  $Context.Response.Headers["Cache-Control"] = "no-store"
  if ($Context.Request.Headers["Origin"] -eq $Origin) {
    $Context.Response.Headers["Access-Control-Allow-Origin"] = $Origin
    $Context.Response.Headers["Vary"] = "Origin"
    $Context.Response.Headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    $Context.Response.Headers["Access-Control-Allow-Headers"] = "Content-Type"
    if ($Context.Request.Headers["Access-Control-Request-Private-Network"] -eq "true") {
      $Context.Response.Headers["Access-Control-Allow-Private-Network"] = "true"
    }
  }
  $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $Context.Response.Close()
}
function Get-Click {
  $down = ([JoyPaintWin32]::GetAsyncKeyState(1) -band 0x8000) -ne 0
  if ($script:Armed -and $down -and -not $script:PreviousLeft) {
    $p = New-Object JoyPaintWin32+POINT
    [void][JoyPaintWin32]::GetCursorPos([ref]$p)
    $script:LastClick = @{ x=$p.X; y=$p.Y; label=$script:Label }
    $script:Armed = $false
  }
  $script:PreviousLeft = $down
}
Write-Host "Joy of Painting helper running at http://127.0.0.1:8765"
Write-Host "Only requests from the official Joy of Painting page are accepted."
Write-Host "Keep this window open. Press Ctrl+C to stop."
try {
  while ($Listener.IsListening) {
    $Context = $Listener.GetContext()
    try {
      $OriginHeader = $Context.Request.Headers["Origin"]
      $HostHeader = $Context.Request.Headers["Host"]
      if ($OriginHeader -ne $Origin -or $HostHeader -notin @("127.0.0.1:8765","localhost:8765")) {
        Send-Json $Context 403 @{ error="Origin not allowed" }; continue
      }
      if ($Context.Request.HttpMethod -eq "OPTIONS") {
        Send-Json $Context 204 @{}; continue
      }
      $Path = $Context.Request.Url.AbsolutePath
      if ($Context.Request.HttpMethod -eq "GET" -and $Path -eq "/status") {
        $w=[JoyPaintWin32]::GetSystemMetrics(0); $h=[JoyPaintWin32]::GetSystemMetrics(1)
        Send-Json $Context 200 @{ ok=$true; screen=@{width=$w;height=$h} }; continue
      }
      if ($Context.Request.HttpMethod -eq "GET" -and $Path -eq "/last") {
        Get-Click
        $click=$script:LastClick; $script:LastClick=$null
        Send-Json $Context 200 @{ click=$click }; continue
      }
      if ($Context.Request.HttpMethod -eq "POST") {
        $reader=[IO.StreamReader]::new($Context.Request.InputStream)
        $body=$reader.ReadToEnd(); $reader.Dispose()
        if ($body.Length -gt 4096) { Send-Json $Context 413 @{error="Request too large"}; continue }
        $data=@{}; if ($body) { $data=ConvertFrom-Json -AsHashtable $body }
        if ($Path -eq "/arm") {
          $script:Label=[string]$data.label; $script:Armed=$true; $script:LastClick=$null
          Send-Json $Context 200 @{ok=$true}; continue
        }
        if ($Path -eq "/click") {
          $x=[int]$data.x; $y=[int]$data.y
          $w=[JoyPaintWin32]::GetSystemMetrics(0); $h=[JoyPaintWin32]::GetSystemMetrics(1)
          if ($x -lt 0 -or $y -lt 0 -or $x -ge $w -or $y -ge $h) { Send-Json $Context 400 @{error="Coordinates outside screen"}; continue }
          $p=New-Object JoyPaintWin32+POINT; [void][JoyPaintWin32]::GetCursorPos([ref]$p)
          if ($p.X -le 1 -and $p.Y -le 1) { Send-Json $Context 403 @{error="Emergency stop is active"}; continue }
          [void][JoyPaintWin32]::SetCursorPos($x,$y)
          [JoyPaintWin32]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
          [JoyPaintWin32]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
          Send-Json $Context 200 @{ok=$true}; continue
        }
        if ($Path -eq "/stop") { $script:Armed=$false; Send-Json $Context 200 @{ok=$true}; continue }
      }
      Send-Json $Context 404 @{error="Not found"}
    } catch {
      try { Send-Json $Context 500 @{error="Local helper error"} } catch {}
      Write-Host $_.Exception.Message
    }
  }
} finally {
  $Listener.Stop(); $Listener.Close()
  Write-Host "Helper stopped."
}
