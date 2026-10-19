$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$vs = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'
Import-Module (Join-Path $vs 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
$testName = 'yl-quality-native-' + [Guid]::NewGuid().ToString('N')
$testRoot = Join-Path $env:TEMP $testName
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    Copy-Item -LiteralPath (Join-Path $repo 'client\windows\runner\quality_process.cpp') $testRoot
    Copy-Item -LiteralPath (Join-Path $repo 'client\windows\runner\quality_process.h') $testRoot
    Copy-Item -LiteralPath (Join-Path $repo 'client\windows\tests\quality_process_test.cpp') $testRoot
    Push-Location $testRoot
    try {
        & cl.exe /nologo /std:c++17 /EHsc /W4 /WX /utf-8 /DNOMINMAX quality_process.cpp quality_process_test.cpp user32.lib /Fe:quality-native-test.exe
        if ($LASTEXITCODE -ne 0) { throw 'Native test compilation failed' }
        & .\quality-native-test.exe
        if ($LASTEXITCODE -ne 0) { throw "Native process test failed with exit $LASTEXITCODE" }
    } finally { Pop-Location }
} finally {
    $full = [System.IO.Path]::GetFullPath($testRoot)
    $parent = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if (-not $full.StartsWith($parent, [System.StringComparison]::OrdinalIgnoreCase) -or
        [System.IO.Path]::GetFileName($full) -ne $testName) { throw 'Unsafe test cleanup target' }
    Remove-Item -LiteralPath $full -Recurse -Force
}
