Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class WRel {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out PT2 p);
}
public struct PT2 { public int X; public int Y; }
"@
[WRel]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
[WRel]::SetCursorPos(1200, 900) | Out-Null
Start-Sleep -Milliseconds 500
[WRel]::mouse_event(0x0001, 15, 15, 0, [UIntPtr]::Zero)  # relative move
Start-Sleep -Milliseconds 500
$p = New-Object PT2; [WRel]::GetCursorPos([ref]$p) | Out-Null
"relative moved cursor to ({0},{1})" -f $p.X,$p.Y
