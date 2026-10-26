# Builds windows/shared/torrent_streamer.dll (Windows x64) from the go/
# sources: the same engine and C API as the Android libtorrent_streamer.so.
#
# Needs Go (the Android libraries were built with Go 1.27.1) and a MinGW C
# compiler for cgo; llvm-mingw's UCRT build is what this was written for
# (https://github.com/mstorsjo/llvm-mingw), so the DLL needs only Windows'
# own libraries. Nothing has to be installed: pass both folders.
#   powershell -ExecutionPolicy Bypass -File packages\flutter_go_torrent_streamer\go\build_windows.ps1 `
#     -Go C:\tools\go\bin\go.exe -LlvmMingw C:\tools\llvm-mingw [-Install]
# With -Install the DLL and its header replace windows\shared; update
# TORRENT_STREAMER_SHA256 in .github/workflows/release-windows.yml with the
# printed hash.
param(
  [string]$Go = 'go',
  [Parameter(Mandatory)][string]$LlvmMingw,
  [switch]$Install
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$bin = Join-Path $LlvmMingw 'bin'
$cc = Join-Path $bin 'x86_64-w64-mingw32-clang.exe'
$readobj = Join-Path $bin 'llvm-readobj.exe'
if (-not (Test-Path $cc)) { throw "No x86_64-w64-mingw32-clang.exe in $bin." }

$out = Join-Path $env:TEMP 'reelish-torrent-streamer'
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Path $out | Out-Null
$dll = Join-Path $out 'torrent_streamer.dll'

$env:CGO_ENABLED = '1'
$env:GOOS = 'windows'
$env:GOARCH = 'amd64'
$env:CC = $cc
$env:PATH = "$bin;$env:PATH"
# -trimpath, an empty build ID (with cgo it differs on every build) and no
# linker timestamp make the build reproducible: the same toolchain gives
# the same SHA-256. -static links the C/C++ runtimes into the DLL: uTP
# (go-libutp) is C++, and libc++.dll / libunwind.dll are not part of Windows.
# (Single quotes inside: Windows PowerShell drops embedded double quotes.)
& $Go build -a -buildmode=c-shared -trimpath `
  -ldflags "-s -w -buildid= '-extldflags=-static -Wl,--no-insert-timestamp'" -o $dll .
if ($LASTEXITCODE -ne 0) { throw "go build failed ($LASTEXITCODE)." }

# The C API the Dart side looks up (lib/flutter_go_torrent_streamer.dart).
$exports = & $readobj --coff-exports $dll | Out-String
foreach ($symbol in 'Init', 'Configure', 'StartStream', 'SelectFile', 'GetFiles',
  'GetStreamStatus', 'DownloadFile', 'PauseSession', 'ResumeSession',
  'GetAllSessions', 'StopClient', 'FreeString') {
  if ($exports -notmatch "Name: $symbol\r?\n") { throw "Missing export: $symbol" }
}
# Only libraries every Windows 10/11 has: a MinGW runtime DLL (libgcc,
# libwinpthread, libc++) would be missing on a clean install.
$imports = (& $readobj --coff-imports $dll | Select-String 'Name: (\S+\.dll)' |
  ForEach-Object { $_.Matches[0].Groups[1].Value.ToLower() }) | Sort-Object -Unique
foreach ($name in $imports) {
  if ($name -notmatch '^(kernel32|advapi32|ws2_32|winmm|ntdll|userenv|bcrypt|crypt32|iphlpapi|dnsapi|mswsock|secur32|shell32|ole32|user32|api-ms-win-.*)\.dll$') {
    throw "Imports a library Windows does not ship: $name"
  }
}

Write-Host "Built $dll"
Write-Host ('Imports: ' + ($imports -join ', '))
Write-Host ('SHA-256 ' + (Get-FileHash $dll -Algorithm SHA256).Hash.ToLower())
if ($Install) {
  $shared = Join-Path $PSScriptRoot '..\windows\shared'
  New-Item -ItemType Directory -Force -Path $shared | Out-Null
  Copy-Item $dll, (Join-Path $out 'torrent_streamer.h') $shared -Force
  Write-Host "Installed into $((Resolve-Path $shared).Path)."
}
