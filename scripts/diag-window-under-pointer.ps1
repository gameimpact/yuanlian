$ErrorActionPreference = "Stop"
Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct PTD { public int X; public int Y; }
public static class WD {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(PTD p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}
"@
[WD]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$app = Get-Process yuanlian_client | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
$pt = New-Object PTD; $pt.X = 1909; $pt.Y = 1249
[WD]::SetCursorPos($pt.X, $pt.Y) | Out-Null
Start-Sleep -Milliseconds 300
$under = [WD]::WindowFromPoint($pt)
$root = [WD]::GetAncestor($under, 2)
$pidUnder = 0; [WD]::GetWindowThreadProcessId($under, [ref]$pidUnder) | Out-Null
$fg = [WD]::GetForegroundWindow()
$pidFg = 0; [WD]::GetWindowThreadProcessId($fg, [ref]$pidFg) | Out-Null
"app_pid={0} app_hwnd={1}" -f $app.Id, $app.MainWindowHandle
"under_hwnd={0} under_root={1} under_pid={2} under_proc={3}" -f $under,$root,$pidUnder,(Get-Process -Id $pidUnder -ErrorAction SilentlyContinue).ProcessName
"fg_hwnd={0} fg_pid={1} fg_proc={2}" -f $fg,$pidFg,(Get-Process -Id $pidFg -ErrorAction SilentlyContinue).ProcessName
