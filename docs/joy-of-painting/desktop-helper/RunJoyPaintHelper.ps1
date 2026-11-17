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
  [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr hWnd, ref POINT p);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
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
  public static bool ClickAt(IntPtr hwnd, int x, int y, int screenW, int screenH) {
    if (GetForegroundWindow() != hwnd) {
      IntPtr foreground = GetForegroundWindow();
      uint foregroundPid, targetPid;
      uint foregroundThread = GetWindowThreadProcessId(foreground, out foregroundPid);
      uint targetThread = GetWindowThreadProcessId(hwnd, out targetPid);
      uint currentThread = GetCurrentThreadId();
      AllowSetForegroundWindow(-1);
      bool attachedForeground = foregroundThread != 0 && AttachThreadInput(currentThread, foregroundThread, true);
      bool attachedTarget = targetThread != 0 && AttachThreadInput(currentThread, targetThread, true);
      try {
        ShowWindow(hwnd, 9);
        BringWindowToTop(hwnd);
        SetForegroundWindow(hwnd);
        SetActiveWindow(hwnd);
        SetFocus(hwnd);
      } finally {
        if (attachedTarget) AttachThreadInput(currentThread, targetThread, false);
        if (attachedForeground) AttachThreadInput(currentThread, foregroundThread, false);
      }
      System.Threading.Thread.Sleep(120);
      if (GetForegroundWindow() != hwnd) return false;
    }
    INPUT[] inputs = new INPUT[3];
    int ax = (int)Math.Round(Math.Max(0, Math.Min(screenW - 1, x)) * 65535.0 / Math.Max(1, screenW - 1));
    int ay = (int)Math.Round(Math.Max(0, Math.Min(screenH - 1, y)) * 65535.0 / Math.Max(1, screenH - 1));
    inputs[0].type = 0; inputs[0].mi.dx = ax; inputs[0].mi.dy = ay; inputs[0].mi.dwFlags = 0x8001;
    inputs[1].type = 0; inputs[1].mi.dwFlags = 0x0002;
    inputs[2].type = 0; inputs[2].mi.dwFlags = 0x0004;
    return SendInput(3, inputs, Marshal.SizeOf(typeof(INPUT))) == 3;
  }
}
"@
$script:Armed = $false
$script:Label = "target"
$script:PreviousLeft = $false
$script:AwaitMouseRelease = $false
$script:LastClick = $null
$script:MinecraftHwnd = [IntPtr]::Zero
function Find-MinecraftWindow {
  # Find the Java Edition game window without changing focus or window size.
  $script:MinecraftHwnd = [IntPtr]::Zero
  foreach ($proc in [Diagnostics.Process]::GetProcessesByName("javaw")) {
    try {
      $proc.Refresh()
      if ($proc.MainWindowHandle -ne [IntPtr]::Zero -and [string]$proc.MainWindowTitle -match "Minecraft") {
        $script:MinecraftHwnd = $proc.MainWindowHandle
        return $true
      }
    } catch {}
  }
  return $false
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
          if (-not (Find-MinecraftWindow)) {
            Send-Json $Context 409 @{error="Minecraft Java window was not found. Open the game and its painting screen, then try again."}; continue
          }
          # Send genuine Windows mouse input. Minecraft Java reads real mouse input;
          # posted window messages can be ignored by its GLFW/LWJGL input layer.
          if (-not [JoyPaintWin32]::ClickAt($script:MinecraftHwnd, $x, $y, $w, $h)) {
            Send-Json $Context 409 @{error="Could not focus Minecraft. Keep the game open and try Start painting again."}; continue
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
