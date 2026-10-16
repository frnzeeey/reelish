# Rebuilds third_party/flutter_js/windows/shared/quickjs_c_bridge.dll.
#
# Source: https://github.com/abner/quickjs-c-bridge at the commit below
# (QuickJS 2021-03-27, the upstream of flutter_js 0.8.7's Windows DLL).
# Reelish adds two things, both in CMake, no source changes:
#   1. /Oi- for QuickJS: newer MSVC treats fabs/floor/... as intrinsics, whose
#      addresses are not constant, so QuickJS's Math table fails to compile.
#   2. /EXPORT:JS_SetMemoryLimit and /EXPORT:JS_SetInterruptHandler, so the
#      provider sandbox gets its heap cap and interrupt deadline on Windows.
#
# Needs Visual Studio with "Desktop development with C++" (MSVC, CMake and
# Ninja ship with it). Run from the repository root:
#   powershell -ExecutionPolicy Bypass -File tool\build_quickjs_bridge_windows.ps1
# MSVC output is not bit-reproducible (timestamps); verify by exports.
param(
  [string]$Commit = '7204d9b',
  [string]$WorkDir = (Join-Path $env:TEMP 'reelish-quickjs-bridge'),
  [switch]$Install
)
$ErrorActionPreference = 'Stop'

$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" `
  -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'Visual Studio with the C++ workload was not found.' }

$src = Join-Path $WorkDir 'src'
$build = Join-Path $WorkDir 'build'
if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
git clone --quiet https://github.com/abner/quickjs-c-bridge.git $src
git -C $src checkout --quiet $Commit

Add-Content (Join-Path $src 'cxx\quickjs-windows.cmake') "`ntarget_compile_options(quickjs PRIVATE `"/Oi-`")"
Add-Content (Join-Path $src 'windows\CMakeLists.txt') @'

target_link_options(${PLUGIN_NAME} PRIVATE
  "/EXPORT:JS_SetMemoryLimit"
  "/EXPORT:JS_SetInterruptHandler"
)
'@

$cm = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake'
$script = @"
@echo off
call "$vs\VC\Auxiliary\Build\vcvarsall.bat" x64 >nul || exit /b 1
set "PATH=$cm\CMake\bin;$cm\Ninja;%PATH%"
cmake -S "$src\windows" -B "$build" -DCMAKE_BUILD_TYPE=Release -G Ninja || exit /b 1
cmake --build "$build" || exit /b 1
dumpbin /nologo /exports "$build\quickjs_c_bridge.dll" > "$build\exports.txt" || exit /b 1
"@
$bat = Join-Path $WorkDir 'build.bat'
Set-Content -Path $bat -Value $script -Encoding ascii
cmd /c "`"$bat`""
if ($LASTEXITCODE -ne 0) { throw "Build failed ($LASTEXITCODE)." }

$exports = Get-Content (Join-Path $build 'exports.txt')
foreach ($symbol in 'JS_SetMemoryLimit', 'JS_SetInterruptHandler', 'jsEval', 'jsNewRuntime') {
  if (-not ($exports -match "\s$symbol$")) { throw "Missing export: $symbol" }
}
$dll = Join-Path $build 'quickjs_c_bridge.dll'
Write-Host "Built $dll"
Write-Host ("SHA-256 " + (Get-FileHash $dll -Algorithm SHA256).Hash.ToLower())
if ($Install) {
  Copy-Item $dll 'third_party\flutter_js\windows\shared\quickjs_c_bridge.dll' -Force
  Write-Host 'Installed into third_party\flutter_js\windows\shared.'
}
