# Set NDK path - try environment variable first, then hardcoded fallback
Set-Location $PSScriptRoot
$NDK_PATH = $env:ANDROID_NDK_HOME
if (-not $NDK_PATH) {
    # Try common default locations or fallback to the specific path
    $PotentialPaths = @(
        "C:\Users\yyyy\AppData\Local\Android\Sdk\ndk\27.0.12077973",
        "C:\Users\yyyy\AppData\Local\Android\Sdk\ndk\26.3.11579264",
        "$env:LOCALAPPDATA\Android\Sdk\ndk\*"
    )
    
    foreach ($path in $PotentialPaths) {
        $found = Get-Item $path -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($found) {
            $NDK_PATH = $found.FullName
            break
        }
    }
}

if (-not $NDK_PATH -or -not (Test-Path $NDK_PATH)) {
    Write-Host "Error: Android NDK not found."
    Write-Host "Please set ANDROID_NDK_HOME environment variable or update this script."
    exit 1
}

Write-Host "Using NDK at: $NDK_PATH"

# Find toolchain
$TOOLCHAIN = "$NDK_PATH\toolchains\llvm\prebuilt\windows-x86_64\bin"
if (-not (Test-Path $TOOLCHAIN)) {
    Write-Host "Error: Toolchain bin not found at $TOOLCHAIN"
    exit 1
}

# Define targets
$Targets = @(
    @{
        Arch = "arm64"
        Abi = "arm64-v8a"
        CompilerPrefix = "aarch64-linux-android"
    },
    @{
        Arch = "amd64"
        Abi = "x86_64"
        CompilerPrefix = "x86_64-linux-android"
    }
)

$env:CGO_ENABLED = "1"
$env:GOOS = "android"
$API_LEVEL = "24" # Minimum supported API level

foreach ($Target in $Targets) {
    $Arch = $Target.Arch
    $Abi = $Target.Abi
    $Prefix = $Target.CompilerPrefix
    
    Write-Host "--------------------------------------------------"
    Write-Host "Building for $Abi ($Arch)..."
    
    # Find compiler
    $CC = "$TOOLCHAIN\$Prefix$API_LEVEL-clang.cmd"
    if (-not (Test-Path $CC)) {
        # Fallback to checking without .cmd or fuzzy match
         $CC_Files = Get-ChildItem "$TOOLCHAIN\$Prefix*-clang.cmd"
         if ($CC_Files) {
             # Pick the highest version
             $CC = ($CC_Files | Sort-Object Name -Descending | Select-Object -First 1).FullName
         } else {
             Write-Host "Error: Compiler for $Abi not found ($CC)"
             continue
         }
    }

    # Find C++ compiler (CXX)
    $CXX = $CC.Replace("clang.cmd", "clang++.cmd")
    if (-not (Test-Path $CXX)) {
         Write-Host "Warning: CXX compiler not found at $CXX, trying to find by pattern"
         $CXX_Files = Get-ChildItem "$TOOLCHAIN\$Prefix*-clang++.cmd"
         if ($CXX_Files) {
             $CXX = ($CXX_Files | Sort-Object Name -Descending | Select-Object -First 1).FullName
         } else {
             Write-Host "Error: CXX Compiler for $Abi not found"
             # Try to proceed, maybe CC handles it? But likely fail.
         }
    }
    
    Write-Host "Using Compiler: CC=$CC"
    Write-Host "Using CXX: CXX=$CXX"
    
    $env:GOARCH = $Arch
    $env:CC = $CC
    $env:CXX = $CXX
    
    $OutputDir = "../android/src/main/jniLibs/$Abi"
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    }
    
    $OutputFile = "$OutputDir/libtorrent_streamer.so"
    
    # Remove existing file to ensure clean build
    if (Test-Path $OutputFile) {
        Remove-Item $OutputFile -Force
    }

    go build -buildmode=c-shared -o $OutputFile .
    
    if ($?) {
        Write-Host "Build Successful for $Abi!"
    } else {
        Write-Host "Build Failed for $Abi!"
        exit 1
    }
}

Write-Host "--------------------------------------------------"
Write-Host "All builds completed."
