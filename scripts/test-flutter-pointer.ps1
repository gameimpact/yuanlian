$ErrorActionPreference = "Stop"
Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct RECTF { public int Left, Top, Right, Bottom; }
public struct POINTF { public int X, Y; }
public static class WF {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECTF r);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECTF r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINTF p);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINTF p);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
}
"@
[WF]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$p = Get-Process yuanlian_client -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
$h = $p.MainWindowHandle
Add-Type -AssemblyName Microsoft.VisualBasic
[Microsoft.VisualBasic.Interaction]::AppActivate($p.Id) | Out-Null
Start-Sleep -Milliseconds 300
$c = New-Object RECTF; [WF]::GetClientRect($h, [ref]$c) | Out-Null
$w = New-Object RECTF; [WF]::GetWindowRect($h, [ref]$w) | Out-Null
$o = New-Object POINTF; [WF]::ClientToScreen($h, [ref]$o) | Out-Null
$orig = New-Object POINTF; [WF]::GetCursorPos([ref]$orig) | Out-Null
$cw = $c.Right - $c.Left; $ch = $c.Bottom - $c.Top
# Toolbar 56 logical, status 30 logical. Flutter scales logical to physical.
$dpiScale = [double]$cw / 1280.0
$bodyTop = $o.Y + [int](56 * $dpiScale)
$bodyBottom = $o.Y + $ch - [int](30 * $dpiScale)
$bodyHeight = $bodyBottom - $bodyTop
$bodyWidth = $cw
$scale = [math]::Min($bodyWidth / 3200.0, $bodyHeight / 2000.0)
$drawW = [int](3200 * $scale); $drawH = [int](2000 * $scale)
$offX = $o.X + [int](($bodyWidth - $drawW) / 2)
$offY = $bodyTop + [int](($bodyHeight - $drawH) / 2)
$localX = $offX + [int]($drawW * 0.78)
$localY = $offY + [int]($drawH * 0.78)
$expectedRemoteX = [int](3200 * 0.78)
$expectedRemoteY = [int](2000 * 0.78)
[WF]::SetCursorPos($localX, $localY) | Out-Null
"client={0}x{1} origin=({2},{3}) window=({4},{5})-({6},{7}) dpiScale={8}" -f $cw,$ch,$o.X,$o.Y,$w.Left,$w.Top,$w.Right,$w.Bottom,$dpiScale
"image={0}x{1} at ({2},{3}) scale={4} localTarget=({5},{6}) expectedRemote=({7},{8})" -f $drawW,$drawH,$offX,$offY,$scale,$localX,$localY,$expectedRemoteX,$expectedRemoteY
for ($i=1; $i -le 8; $i++) {
  Start-Sleep -Milliseconds 150
  $now = New-Object POINTF; [WF]::GetCursorPos([ref]$now) | Out-Null
  "sample {0}: ({1},{2})" -f $i,$now.X,$now.Y
}
[WF]::SetCursorPos($orig.X, $orig.Y) | Out-Null
