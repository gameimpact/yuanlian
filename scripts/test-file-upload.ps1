$ErrorActionPreference = "Stop"
Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct PTY { public int X; public int Y; }
public static class WY {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e);
}
"@
[WY]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$p = Get-Process yuanlian_client -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
Add-Type -AssemblyName Microsoft.VisualBasic
[Microsoft.VisualBasic.Interaction]::AppActivate($p.Id) | Out-Null
Start-Sleep -Milliseconds 400
function Move-And-Click([int]$x, [int]$y) {
  [WY]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 120
  [WY]::mouse_event(0x0001, 1, 1, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 180
  [WY]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  [WY]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 300
}
# Local upload-test.txt row, then "上传" button.
Move-And-Click 1640 330
Move-And-Click 1304 820
Start-Sleep -Seconds 4
$target = 'C:\Users\Lenovo\Desktop\远程控制软件\artifacts\file-root\upload-test.txt'
if (Test-Path $target) {
  $hash = (Get-FileHash -Algorithm SHA256 -Path $target).Hash.ToLower()
  $content = Get-Content -Raw -Path $target
  "UPLOAD_OK path=$target sha256=$hash"
  "CONTENT_START"; $content; "CONTENT_END"
} else {
  "UPLOAD_MISSING expected=$target"
}
