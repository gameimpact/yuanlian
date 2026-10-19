param([string]$Output,[switch]$Resume,[switch]$UseWsl)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if(-not $Output){$Output=Join-Path $repo 'third_party/moonlight/source-checkouts'}
$root=[IO.Path]::GetFullPath($Output)
if((Test-Path -LiteralPath $root) -and -not $Resume){throw 'Source destination already exists; choose a new directory'}
New-Item -ItemType Directory -Path $root -Force | Out-Null
$items=@(
 @{name='moonlight';url='https://github.com/moonlight-stream/moonlight-qt.git';tag='v6.2.0';commit='de2467e433821664cdd2224aad8c89a625be1ad9'},
 @{name='sunshine';url='https://github.com/LizardByte/Sunshine.git';tag='v2026.914.233613';commit='63d35f702ee9e362e43263742981836ec0710384'}
)
$record=@()
foreach($item in $items){
 $destination=Join-Path $root $item.name
 if(-not (Test-Path -LiteralPath (Join-Path $destination '.git'))) {
 & git -c core.longpaths=true -c advice.detachedHead=false -c core.hooksPath=NUL clone --quiet --depth 1 --branch $item.tag $item.url $destination
 if($LASTEXITCODE -ne 0){throw 'Pinned public source clone failed'}
 }
 $commit=(& git -C $destination rev-parse HEAD).Trim()
 if($commit -ne $item.commit){throw 'Upstream tag does not match pinned commit; source rejected'}
 if($UseWsl){
  $windowsPath=$destination.Replace('\','/')
  $translated=& wsl.exe -d Ubuntu --exec wslpath -a -u $windowsPath
  if($LASTEXITCODE -ne 0){throw 'WSL path translation failed'}
  $linuxPath=($translated | Out-String).Trim()
  & wsl.exe -d Ubuntu -- git -C $linuxPath -c core.hooksPath=/dev/null submodule update --init --recursive --depth 1
 }else{
  & git -C $destination -c core.longpaths=true -c core.hooksPath=NUL submodule update --init --recursive --depth 1
 }
 if($LASTEXITCODE -ne 0){throw 'Pinned recursive submodule checkout failed (Windows deep paths may require -UseWsl)'}
 if($UseWsl){$modules=@(& wsl.exe -d Ubuntu -- git -C $linuxPath submodule status --recursive)}else{$modules=@(& git -C $destination submodule status --recursive)}
 if($LASTEXITCODE -ne 0 -or @($modules|Where-Object{$_ -match '^[+\-U]'}).Count){throw 'Incomplete or mismatched source submodule'}
 $record += [ordered]@{component=$item.name;repository=$item.url;commit=$commit;submodules=$modules}
}
$record|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $root 'source-checkout-manifest.json') -Encoding UTF8
Write-Output "Verified source and recursive submodules: $root"
