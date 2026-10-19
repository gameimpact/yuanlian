param(
    [string]$Version = "0.2.0",
    [string]$Output = ""
)

$ErrorActionPreference = "Stop"
if ($Version -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$') {
    throw "Invalid package version"
}
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$vendor = Join-Path $repo "third_party\moonlight"
if (-not $Output) {
    $Output = Join-Path $repo "dist\$Version\quality-preview"
}
$Output = [System.IO.Path]::GetFullPath($Output)
if ($Output -eq [System.IO.Path]::GetPathRoot($Output)) { throw "Output must be a dedicated directory" }
$ancestor = [System.IO.DirectoryInfo]::new($Output)
while ($null -ne $ancestor) {
    if ($ancestor.Exists -and ($ancestor.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "Output must not traverse reparse points"
    }
    $ancestor = $ancestor.Parent
}
$zip = Join-Path $Output "yuanlian-quality-preview-$Version-windows-x64.zip"
if (Test-Path -LiteralPath $zip) { throw "Package already exists; choose a new output directory. Existing files will not be replaced." }
$workName = ".yuanlian-quality-build-$([Guid]::NewGuid().ToString('N'))"
$workRoot = Join-Path $Output $workName
$stage = Join-Path $workRoot "windows-x64"

# Pinned upstream release assets. These hashes are the same values recorded in
# third_party/moonlight/README.md; a mismatch must stop packaging.
$pins = @{
    "MoonlightPortable-x64-6.2.0.zip" = "6f91d268b41ed5ca8066d9d7578dc403b8db190991ff48f00b1700465f8f7ebf"
    "Sunshine-Windows-AMD64-lite.zip" = "233008e46f4c0e501a586cbfd6c4fd4a4c0d414a0b5fc7f13c070eb92ec3824b"
}

foreach ($name in $pins.Keys) {
    $path = Join-Path $vendor $name
    if (-not (Test-Path $path)) {
        throw "Missing upstream archive: $path`nDownload it from the URL in third_party/moonlight/README.md; do not substitute a different build."
    }
    $actual = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $pins[$name]) {
        throw "SHA-256 mismatch for $name`nexpected $($pins[$name])`nactual   $actual"
    }
}

New-Item -ItemType Directory -Force -Path $Output | Out-Null
New-Item -ItemType Directory -Path $workRoot | Out-Null
New-Item -ItemType Directory -Force -Path `
    $stage,
    (Join-Path $stage "moonlight"),
    (Join-Path $stage "sunshine"),
    (Join-Path $stage "licenses") | Out-Null

$expandRoot = Join-Path $workRoot "upstream"
try {
    $mlTemp = Join-Path $expandRoot "moonlight"
    $sunTemp = Join-Path $expandRoot "sunshine"
    Expand-Archive -LiteralPath (Join-Path $vendor "MoonlightPortable-x64-6.2.0.zip") -DestinationPath $mlTemp
    Expand-Archive -LiteralPath (Join-Path $vendor "Sunshine-Windows-AMD64-lite.zip") -DestinationPath $sunTemp

    Copy-Item -Recurse (Join-Path $mlTemp "*") (Join-Path $stage "moonlight")
    Copy-Item -Recurse (Join-Path $sunTemp "Sunshine\*") (Join-Path $stage "sunshine")

    if (-not (Test-Path (Join-Path $stage "moonlight\Moonlight.exe"))) {
        throw "Moonlight.exe was not found after extraction"
    }
    if (-not (Test-Path (Join-Path $stage "sunshine\sunshine.exe"))) {
        throw "sunshine.exe was not found after extraction"
    }

    Get-ChildItem (Join-Path $PSScriptRoot "licenses") -File |
        Copy-Item -Destination (Join-Path $stage "licenses")
    Copy-Item (Join-Path $PSScriptRoot "README.zh-CN.md") $stage
    Copy-Item (Join-Path $PSScriptRoot "THIRD-PARTY-NOTICES.txt") $stage
    Copy-Item (Join-Path $PSScriptRoot "SOURCE-OFFER.txt") $stage
    Copy-Item (Join-Path $repo "client\assets\quality\moonlight-6.2.0.json") (Join-Path $stage "moonlight-component-manifest.json")
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $stage "moonlight-component-manifest.json") | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.version -ne '6.2.0' -or
        $manifest.archive_sha256 -ne $pins['MoonlightPortable-x64-6.2.0.zip']) { throw 'Trusted manifest identity mismatch' }
    $componentRoot = (Join-Path $stage 'moonlight') + '\'
    foreach ($entry in $manifest.files) {
        $componentFile = [System.IO.Path]::GetFullPath((Join-Path $componentRoot $entry.path))
        if (-not $componentFile.StartsWith($componentRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Manifest path escapes component root' }
        if (-not (Test-Path -LiteralPath $componentFile -PathType Leaf) -or
            (Get-Item -LiteralPath $componentFile).Length -ne $entry.size -or
            (Get-FileHash -LiteralPath $componentFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.sha256) { throw 'Trusted manifest does not match fixed upstream files' }
    }
    if (@(Get-ChildItem -LiteralPath $componentRoot -Recurse -File).Count -ne @($manifest.files).Count) { throw 'Trusted manifest file count mismatch' }

    $moonlightVersion = (Get-Item (Join-Path $stage "moonlight\Moonlight.exe")).VersionInfo.ProductVersion
    $sunshineVersion = (Get-Item (Join-Path $stage "sunshine\sunshine.exe")).VersionInfo.ProductVersion
    if (([version]$moonlightVersion) -ne ([version]'6.2.0.0')) {
        throw "Unexpected Moonlight version: $moonlightVersion"
    }
    if (([version]$sunshineVersion) -ne ([version]'2026.914.233613')) {
        throw "Unexpected Sunshine version: $sunshineVersion"
    }

    # Runtime state belongs to the user, never to the distribution. Reject a
    # package if an extractor accidentally produced a pairing database.
    $forbidden = Get-ChildItem $stage -Recurse -File -Force | Where-Object {
        $_.Name -match '^(sunshine_state\.json|Moonlight\.ini|credentials)$'
    }
    if ($forbidden) {
        throw "Refusing to package runtime credentials/settings: $($forbidden.FullName -join ', ')"
    }

    $sumFile = Join-Path $stage "SHA256SUMS.txt"
    $lines = Get-ChildItem $stage -Recurse -File |
        Where-Object { $_.FullName -ne $sumFile } |
        ForEach-Object {
            $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $relative = $_.FullName.Substring($stage.Length).TrimStart('\')
            "$hash *$relative"
        }
    Set-Content -Path $sumFile -Value $lines -Encoding ASCII

    $temporaryZip = Join-Path $workRoot "package.zip"
    Compress-Archive -LiteralPath $stage -DestinationPath $temporaryZip -CompressionLevel Optimal
    # Same filesystem, atomic and no overwrite even if another build wins a race.
    [System.IO.File]::Move($temporaryZip, $zip)

    Write-Output "Moonlight: $moonlightVersion (GPL-3.0)"
    Write-Output "Sunshine:  $sunshineVersion (GPL-3.0)"
    Write-Output "package:   $zip"
    Get-FileHash $zip -Algorithm SHA256 | Select-Object Path, Hash | Format-List
}
finally {
    $resolvedWork = [System.IO.Path]::GetFullPath($workRoot)
    $expectedWork = [System.IO.Path]::GetFullPath((Join-Path $Output $workName))
    if ($resolvedWork -ne $expectedWork -or
        -not $resolvedWork.StartsWith($Output.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
        [System.IO.Path]::GetFileName($resolvedWork) -ne $workName) {
        throw "Refusing cleanup outside this build's private directory"
    }
    if (Test-Path -LiteralPath $resolvedWork) {
        $links = @(Get-Item -LiteralPath $resolvedWork -Force; Get-ChildItem -LiteralPath $resolvedWork -Recurse -Force) |
            Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint }
        if ($links) { throw "Refusing recursive cleanup of a build directory containing reparse points" }
        Remove-Item -LiteralPath $resolvedWork -Recurse -Force
    }
}
