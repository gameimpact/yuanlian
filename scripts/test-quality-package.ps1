$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$name = 'yl-quality-package-' + [Guid]::NewGuid().ToString('N')
$root = Join-Path $env:TEMP $name
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $oldState = Join-Path $root 'windows-x64\moonlight\Moonlight.ini'
    New-Item -ItemType Directory -Path (Split-Path $oldState) -Force | Out-Null
    [System.IO.File]::WriteAllText($oldState, 'synthetic-existing-user-state')
    & (Join-Path $repo 'packaging\quality\build-quality-preview.ps1') -Output $root
    $zip = Join-Path $root 'yuanlian-quality-preview-0.2.0-windows-x64.zip'
    if (-not (Test-Path -LiteralPath $zip)) { throw 'Package missing' }
    if ([System.IO.File]::ReadAllText($oldState) -ne 'synthetic-existing-user-state') { throw 'Existing state modified' }
    $before = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    $refused = $false
    try { & (Join-Path $repo 'packaging\quality\build-quality-preview.ps1') -Output $root } catch { $refused = $true }
    if (-not $refused -or (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $before) { throw 'Existing archive overwritten' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        if (-not ($archive.Entries.FullName -contains 'windows-x64/moonlight-component-manifest.json')) { throw 'Trusted component manifest missing' }
        if (@($archive.Entries | Where-Object { $_.Name -match '^(Moonlight\.ini|sunshine_state\.json|credentials)$' }).Count) { throw 'Runtime state leaked into package' }
    } finally { $archive.Dispose() }
    if (@(Get-ChildItem -LiteralPath $root -Directory -Filter '.yuanlian-quality-build-*').Count) { throw 'Private staging directory not cleaned' }
    Write-Output 'PASS: fresh package, existing state preserved, existing zip refused, no credentials, private staging cleaned'
} finally {
    $full = [System.IO.Path]::GetFullPath($root)
    if (-not $full.StartsWith([System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
        [System.IO.Path]::GetFileName($full) -ne $name) { throw 'Unsafe package test cleanup target' }
    Remove-Item -LiteralPath $full -Recurse -Force
}
