$ErrorActionPreference = "Stop"
Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct RECTG { public int Left, Top, Right, Bottom; }
public struct POINTG { public int X, Y; }
public static class WG {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECTG r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINTG p);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINTG p);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
}
"@
[WG]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$p = Get-Process yuanlian_client -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
$h = $p.MainWindowHandle
Add-Type -AssemblyName Microsoft.VisualBasic
[Microsoft.VisualBasic.Interaction]::AppActivate($p.Id) | Out-Null
Start-Sleep -Milliseconds 300
$c = New-Object RECTG; [WG]::GetClientRect($h, [ref]$c) | Out-Null
$o = New-Object POINTG; [WG]::ClientToScreen($h, [ref]$o) | Out-Null
$orig = New-Object POINTG; [WG]::GetCursorPos([ref]$orig) | Out-Null
$cw = $c.Right - $c.Left; $ch = $c.Bottom - $c.Top
$dpiScale = [double]$cw / 1280.0
$bodyTop = [int](56 * $dpiScale); $bodyHeight = $ch - $bodyTop - [int](30 * $dpiScale)
$scale = [math]::Min($cw / 3200.0, $bodyHeight / 2000.0)
$drawW = [int](3200 * $scale); $drawH = [int](2000 * $scale)
$offX = [int](($cw - $drawW) / 2); $offY = $bodyTop + [int](($bodyHeight - $drawH) / 2)
# Move to 78% of the image: expected remote ~ (2496,1560), which is inside this
# nearly full-screen window; a live feedback loop should then push toward the
# right edge or out of the window. The key signal is that the cursor moves away
# from the local target at all.
$localX = $o.X + $offX + [int]($drawW * 0.78)
$localY = $o.Y + $offY + [int]($drawH * 0.78)
$vx = [WG]::GetSystemMetrics(76); $vy = [WG]::GetSystemMetrics(77)
$vw = [WG]::GetSystemMetrics(78); $vh = [WG]::GetSystemMetrics(79)
$nx = [uint32](($localX - $vx) * 65535.0 / ($vw - 1))
$ny = [uint32](($localY - $vy) * 65535.0 / ($vh - 1))
[WG]::mouse_event(0x8000 -bor 0x4000 -bor 0x0001, $nx, $ny, 0, [UIntPtr]::Zero)
"client={0}x{1} origin=({2},{3}) dpiScale={4} localTarget=({5},{6}) expectedRemote=(2496,1560)" -f $cw,$ch,$o.X,$o.Y,$dpiScale,$localX,$localY
for ($i=1; $i -le 10; $i++) {
  Start-Sleep -Milliseconds 150
  $now = New-Object POINTG; [WG]::GetCursorPos([ref]$now) | Out-Null
  "sample {0}: ({1},{2})" -f $i,$now.X,$now.Y
}
[WG]::SetCursorPos($orig.X, $orig.Y) | Out-Null
