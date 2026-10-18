param(
    [string]$Version = "0.2.0",
    [Parameter(Mandatory = $true)][string]$ClientRelease,
    [string]$Nsis = "C:\Users\Lenovo\dev\nsis\nsis-3.11\makensis.exe",
    [string]$Output = ""
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if (-not $Output) { $Output = Join-Path $repo "dist\$Version\windows-x64" }
$stage = Join-Path $Output "staging\YuanLian"

if (-not (Test-Path (Join-Path $ClientRelease "yuanlian_client.exe"))) {
    throw "ClientRelease must contain the Flutter Windows runner: $ClientRelease"
}
if (-not (Test-Path $Nsis)) { throw "makensis.exe not found: $Nsis" }
if (-not (Test-Path (Join-Path $repo "target\release\yl-host.exe"))) {
    throw "run cargo build --release --locked -p yl-host -p yl-viewer first"
}

Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path `
    (Join-Path $stage "client"), (Join-Path $stage "bin"), (Join-Path $stage "docs") | Out-Null
Copy-Item -Recurse (Join-Path $ClientRelease "*") (Join-Path $stage "client")
Copy-Item (Join-Path $repo "target\release\yl-host.exe") (Join-Path $stage "bin")
Copy-Item (Join-Path $repo "target\release\yl-viewer.exe") (Join-Path $stage "bin")
Copy-Item (Join-Path $repo "LICENSE") $stage
Copy-Item (Join-Path $repo "THIRD_PARTY.md") $stage
Copy-Item (Join-Path $repo "packaging\docs\*") (Join-Path $stage "docs")
Copy-Item (Join-Path $repo "THIRD_PARTY.md") (Join-Path $stage "docs\THIRD-PARTY-NOTICES.txt")
$revision = (& git -C $repo rev-parse --short HEAD).Trim()
$dirty = (& git -C $repo status --porcelain | Measure-Object).Count -gt 0
@(
    "version=$Version",
    "protocol=2",
    "revision=$revision",
    "source_dirty=$($dirty.ToString().ToLower())",
    "built_at=$((Get-Date).ToUniversalTime().ToString('o'))"
) | Set-Content (Join-Path $stage "VERSION.txt") -Encoding UTF8

$zip = Join-Path $Output "YuanLian-$Version-windows-x64-portable.zip"
Remove-Item $zip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal

$nsiSource = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot "installer.nsi")
$nsi = Join-Path $env:TEMP "yuanlian-installer-$Version.nsi"
[IO.File]::WriteAllText($nsi, $nsiSource, (New-Object Text.UTF8Encoding($true)))
$setup = Join-Path $Output "YuanLian-$Version-windows-x64-setup.exe"
& $Nsis "/DVERSION=$Version" "/DSTAGE=$stage" "/DOUTFILE=$setup" $nsi
if ($LASTEXITCODE -ne 0) { throw "makensis failed with exit code $LASTEXITCODE" }

Get-FileHash $zip, $setup -Algorithm SHA256 |
    Select-Object Path, Hash |
    Format-Table -AutoSize
Write-Output "portable: $zip"
Write-Output "installer: $setup"
