$ErrorActionPreference = "Stop"
Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct RECT3 { public int Left, Top, Right, Bottom; }
public struct POINT3 { public int X, Y; }
public static class W3 {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT3 r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT3 p);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT3 p);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
}
"@
[W3]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$p = Get-Process yl-viewer -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
$hwnd = $p.MainWindowHandle
Add-Type -AssemblyName Microsoft.VisualBasic
[Microsoft.VisualBasic.Interaction]::AppActivate($p.Id) | Out-Null
Start-Sleep -Milliseconds 300
$rect = New-Object RECT3
[W3]::GetClientRect($hwnd, [ref]$rect) | Out-Null
$origin = New-Object POINT3
[W3]::ClientToScreen($hwnd, [ref]$origin) | Out-Null
$orig = New-Object POINT3
[W3]::GetCursorPos([ref]$orig) | Out-Null
$localX = [int](($rect.Right-$rect.Left)/2); $localY = [int](($rect.Bottom-$rect.Top)/2)
[W3]::SetCursorPos($origin.X+$localX, $origin.Y+$localY) | Out-Null
$expectedX = [math]::Round($localX*3200/($rect.Right-$rect.Left))
$expectedY = [math]::Round($localY*2000/($rect.Bottom-$rect.Top))
"client={0}x{1} origin=({2},{3}) local_target=({4},{5}) expected_remote=({6},{7})" -f ($rect.Right-$rect.Left),($rect.Bottom-$rect.Top),$origin.X,$origin.Y,($origin.X+$localX),($origin.Y+$localY),$expectedX,$expectedY
for ($i=1; $i -le 8; $i++) {
  Start-Sleep -Milliseconds 150
  $now = New-Object POINT3
  [W3]::GetCursorPos([ref]$now) | Out-Null
  "sample {0}: ({1},{2})" -f $i,$now.X,$now.Y
}
[W3]::SetCursorPos($orig.X, $orig.Y) | Out-Null
