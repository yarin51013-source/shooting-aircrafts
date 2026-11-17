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
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
    public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo;
  }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT {
    public uint type; public MOUSEINPUT mi;
  }
  [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr SetActiveWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
  [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int dwProcessId);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
}
"@
$script:Armed = $false
$script:Label = "target"
$script:PreviousLeft = $false
$script:AwaitMouseRelease = $false
$script:LastClick = $null
$script:MinecraftHwnd = [IntPtr]::Zero
function Focus-Minecraft {
  # Re-detect the game window every time: Java launchers can create several
  # javaw processes, and a cached handle can point at the wrong window.
  $script:MinecraftHwnd = [IntPtr]::Zero
  $candidates = @("javaw", "Minecraft.Windows", "Minecraft")
  foreach ($name in $candidates) {
    foreach ($proc in [Diagnostics.Process]::GetProcessesByName($name)) {
      try {
        $proc.Refresh()
        $title = [string]$proc.MainWindowTitle
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero -and
            ($name -ne "javaw" -or $title -match "Minecraft")) {
          $script:MinecraftHwnd = $proc.MainWindowHandle
          break
        }
      } catch {}
    }
    if ($script:MinecraftHwnd -ne [IntPtr]::Zero) { break }
  }
  if ($script:MinecraftHwnd -eq [IntPtr]::Zero) { return $false }

  # Temporarily attach the browser/helper foreground input thread to the
  # Minecraft thread so Windows reliably activates the game before SendInput.
  $fg = [JoyPaintWin32]::GetForegroundWindow()
  [uint32]$fgPid = 0
  [uint32]$targetPid = 0
  $fgThread = [JoyPaintWin32]::GetWindowThreadProcessId($fg, [ref]$fgPid)
  $targetThread = [JoyPaintWin32]::GetWindowThreadProcessId($script:MinecraftHwnd, [ref]$targetPid)
  $currentThread = [JoyPaintWin32]::GetCurrentThreadId()
  $attached = $false
  try {
    if ($fgThread -ne 0 -and $targetThread -ne 0 -and $fgThread -ne $targetThread) {
      $attached = [JoyPaintWin32]::AttachThreadInput($fgThread, $targetThread, $true)
    }
    [void][JoyPaintWin32]::ShowWindow($script:MinecraftHwnd, 9)
    [void][JoyPaintWin32]::BringWindowToTop($script:MinecraftHwnd)
    [void][JoyPaintWin32]::SetForegroundWindow($script:MinecraftHwnd)
    [void][JoyPaintWin32]::SetActiveWindow($script:MinecraftHwnd)
    [void][JoyPaintWin32]::SetFocus($script:MinecraftHwnd)
    Start-Sleep -Milliseconds 180
  } finally {
    if ($attached) { [void][JoyPaintWin32]::AttachThreadInput($fgThread, $targetThread, $false) }
  }
  return ([JoyPaintWin32]::GetForegroundWindow() -eq $script:MinecraftHwnd)
}
function Send-Json($Context, [int]$Status, $Data) {
  # A 204 preflight response must not contain a body. For all other
  # responses, set the exact byte length before writing to HttpListener.
  $Context.Response.StatusCode = $Status
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
  try {
    if ($Status -eq 204) {
      $Context.Response.ContentLength64 = 0
    } else {
      $bytes = [Text.Encoding]::UTF8.GetBytes(($Data | ConvertTo-Json -Compress -Depth 5))
      $Context.Response.ContentType = "application/json; charset=utf-8"
      $Context.Response.ContentLength64 = $bytes.Length
      if ($bytes.Length -gt 0) {
        $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
      }
    }
  } finally {
    $Context.Response.Close()
  }
}
function Get-Click {
  # Ignore the click that pressed the website calibration button. First wait
  # until the left mouse button is released, then accept a fresh Minecraft click.
  $state = [JoyPaintWin32]::GetAsyncKeyState(1)
  if ($script:Armed -and $script:AwaitMouseRelease) {
    if (($state -band 0x8000) -eq 0) { $script:AwaitMouseRelease = $false }
    return
  }
  # The low bit catches quick clicks between the browser's polling requests.
  $pressed = ($state -band 1) -ne 0
  if ($script:Armed -and $pressed) {
    $p = New-Object JoyPaintWin32+POINT
    [void][JoyPaintWin32]::GetCursorPos([ref]$p)
    $script:LastClick = @{ x=$p.X; y=$p.Y; label=$script:Label }
    $script:Armed = $false
  }
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
        $data=@{}; if ($body) { $data=ConvertFrom-Json $body }
        if ($Path -eq "/arm") {
          $script:Label=[string]$data.label; $script:Armed=$true; $script:AwaitMouseRelease=$true; $script:LastClick=$null
          # Drain any stale click edge from the website button itself.
          [void][JoyPaintWin32]::GetAsyncKeyState(1)
          Send-Json $Context 200 @{ok=$true}; continue
        }
        if ($Path -eq "/click") {
          $x=[int]$data.x; $y=[int]$data.y
          $w=[JoyPaintWin32]::GetSystemMetrics(0); $h=[JoyPaintWin32]::GetSystemMetrics(1)
          if ($x -lt 0 -or $y -lt 0 -or $x -ge $w -or $y -ge $h) { Send-Json $Context 400 @{error="Coordinates outside screen"}; continue }
          $p=New-Object JoyPaintWin32+POINT; [void][JoyPaintWin32]::GetCursorPos([ref]$p)
          if ($p.X -le 1 -and $p.Y -le 1) { Send-Json $Context 403 @{error="Emergency stop is active"}; continue }
          if (-not (Focus-Minecraft)) {
            Send-Json $Context 409 @{error="Minecraft was not found. Open Minecraft and its canvas, then try again."}; continue
          }
          [void][JoyPaintWin32]::SetForegroundWindow($script:MinecraftHwnd)
          [void][JoyPaintWin32]::SetCursorPos($x,$y)
          Start-Sleep -Milliseconds 35
          $inputs = New-Object 'JoyPaintWin32+INPUT[]' 2
          $inputs[0].type = 0
          $inputs[0].mi.dwFlags = 0x0002
          $inputs[0].mi.dwExtraInfo = [UIntPtr]::Zero
          $inputs[1].type = 0
          $inputs[1].mi.dwFlags = 0x0004
          $inputs[1].mi.dwExtraInfo = [UIntPtr]::Zero
          $sent = [JoyPaintWin32]::SendInput(2, $inputs, [Runtime.InteropServices.Marshal]::SizeOf([type][JoyPaintWin32+INPUT]))
          if ($sent -ne 2) {
            Send-Json $Context 500 @{error="Windows did not accept the mouse click. Click the Minecraft window once, then try again."}; continue
          }
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
