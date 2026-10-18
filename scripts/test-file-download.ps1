$ErrorActionPreference = "Stop"
Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct PTX { public int X; public int Y; }
public static class WX {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out PTX p);
}
"@
[WX]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$p = Get-Process yuanlian_client -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
Add-Type -AssemblyName Microsoft.VisualBasic
[Microsoft.VisualBasic.Interaction]::AppActivate($p.Id) | Out-Null
Start-Sleep -Milliseconds 400
function Move-And-Click([int]$x, [int]$y) {
  [WX]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 120
  [WX]::mouse_event(0x0001, 1, 1, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 180
  [WX]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  [WX]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 300
}
# Physical coordinates based on the 3200x2000 screenshot: remote hello.txt row,
# then the "download" button in the center action column.
Move-And-Click 600 488
Move-And-Click 1320 954
Start-Sleep -Seconds 4
$target = Join-Path $env:USERPROFILE 'hello.txt'
if (Test-Path $target) {
  $hash = (Get-FileHash -Algorithm SHA256 -Path $target).Hash.ToLower()
  $content = Get-Content -Raw -Path $target
  "DOWNLOAD_OK path=$target sha256=$hash"
  "CONTENT_START"; $content; "CONTENT_END"
} else {
  "DOWNLOAD_MISSING expected=$target"
}
