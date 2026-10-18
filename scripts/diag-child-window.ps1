Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public struct RECTD { public int Left, Top, Right, Bottom; }
public static class WDC {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECTD r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECTD r);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
}
"@
[WDC]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$app = Get-Process yuanlian_client | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
$parent = $app.MainWindowHandle
$child = [WDC]::FindWindowEx($parent, [IntPtr]::Zero, $null, $null)
while ($child -ne [IntPtr]::Zero) {
  $r = New-Object RECTD; [WDC]::GetWindowRect($child, [ref]$r) | Out-Null
  $c = New-Object RECTD; [WDC]::GetClientRect($child, [ref]$c) | Out-Null
  $sb = New-Object System.Text.StringBuilder 256
  [WDC]::GetClassName($child, $sb, 256) | Out-Null
  "child={0} class={1} visible={2} rect=({3},{4})-({5},{6}) client={7}x{8}" -f $child,$sb.ToString(),[WDC]::IsWindowVisible($child),$r.Left,$r.Top,$r.Right,$r.Bottom,($c.Right-$c.Left),($c.Bottom-$c.Top)
  $child = [WDC]::FindWindowEx($parent, $child, $null, $null)
}
