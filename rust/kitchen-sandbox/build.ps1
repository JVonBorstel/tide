# Build kitchen-sandbox.exe offline (std only, no crates). On this PC the VS 2022 Preview install has only the onecore CRT libs and
# no vcvars environment, so plain `cargo build` fails with LNK1104 msvcrt.lib; this points LIB at the Windows SDK and that CRT first.
# Usage: pwsh -NoProfile -File rust/kitchen-sandbox/build.ps1   -> rust/kitchen-sandbox/target/release/kitchen-sandbox.exe
$ErrorActionPreference = 'Stop'
if (-not $env:LIB) {
    $sdk = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Lib' -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    $vc = Get-ChildItem 'C:\Program Files\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\lib' -Directory -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
    $dirs = @()
    if ($sdk) { $dirs += (Join-Path $sdk.FullName 'um\x64'), (Join-Path $sdk.FullName 'ucrt\x64') }
    if ($vc) { $dirs += @((Join-Path $vc.FullName 'x64'), (Join-Path $vc.FullName 'onecore\x64') | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'msvcrt.lib') }) }
    $env:LIB = ($dirs | Where-Object { Test-Path -LiteralPath $_ }) -join ';'
}
& cargo build --release --offline --manifest-path (Join-Path $PSScriptRoot 'Cargo.toml')
exit $LASTEXITCODE
