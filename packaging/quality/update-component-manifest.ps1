$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$source = Join-Path $repo 'third_party\moonlight\MoonlightPortable-x64-6.2.0.zip'
$pin = '6f91d268b41ed5ca8066d9d7578dc403b8db190991ff48f00b1700465f8f7ebf'
if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pin) { throw 'Pinned archive hash mismatch' }
$archive = [System.IO.Compression.ZipFile]::OpenRead($source)
try {
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $archive.Entries) {
        if (-not $entry.FullName.EndsWith('/')) { $names.Add($entry.FullName) }
    }
    $names.Sort([System.StringComparer]::Ordinal)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $files = @()
    foreach ($name in $names) {
        if ($name -match '[\\:\x00-\x1f]' -or @($name.Split('/') | Where-Object { $_ -in @('','..','.') }).Count -gt 0 -or -not $seen.Add($name)) { throw 'Unsafe archive entry' }
        $entry = $archive.GetEntry($name)
        $stream = $entry.Open()
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $stream.Dispose(); $sha.Dispose() }
        $files += [ordered]@{path=$name;size=$entry.Length;sha256=$hash}
    }
    $manifest = [ordered]@{schema=1;component='moonlight';version='6.2.0';archive_sha256=$pin;files=$files}
    $destination = Join-Path $repo 'client\assets\quality\moonlight-6.2.0.json'
    New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
    [System.IO.File]::WriteAllText($destination, ($manifest | ConvertTo-Json -Depth 6) + "`n", [System.Text.UTF8Encoding]::new($false))
    Write-Output "Generated trusted manifest: $($files.Count) files from verified Moonlight 6.2.0 archive"
} finally { $archive.Dispose() }
