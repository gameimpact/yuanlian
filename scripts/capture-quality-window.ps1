param([Parameter(Mandatory=$true)][int]$ProcessId,[Parameter(Mandatory=$true)][int]$ParentId)
$ErrorActionPreference='Stop'
$process=Get-Process -Id $ProcessId
$metadata=Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId"
if($metadata.ParentProcessId -ne $ParentId -or [IO.Path]::GetFileName($process.Path) -ine 'Moonlight.exe') {throw 'Not the owned test Moonlight'}
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class QualityWindowCapture {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
}
'@
$handle=$process.MainWindowHandle
$rect=New-Object QualityWindowCapture+RECT
if($handle -eq 0 -or [QualityWindowCapture]::IsIconic($handle) -or -not [QualityWindowCapture]::GetWindowRect($handle,[ref]$rect)) {throw 'Window minimized or unavailable; no visual pass'}
$bitmap=New-Object Drawing.Bitmap(($rect.Right-$rect.Left),($rect.Bottom-$rect.Top))
$graphics=[Drawing.Graphics]::FromImage($bitmap)
$dc=$graphics.GetHdc()
try{$ok=[QualityWindowCapture]::PrintWindow($handle,$dc,2)}finally{$graphics.ReleaseHdc($dc)}
try {
 if(-not $ok){throw 'PrintWindow failed; no visual pass'}
 $output=Join-Path $env:TEMP ('yl-quality-window-'+[Guid]::NewGuid().ToString('N')+'.png')
 $bitmap.Save($output)
 Write-Output $output
}finally{$graphics.Dispose();$bitmap.Dispose()}
