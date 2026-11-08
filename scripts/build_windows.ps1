<#
.SYNOPSIS
    Automated Native Windows Executable (.exe) Build & Packaging Script for PrivateLM.
.DESCRIPTION
    Builds the production-ready Release executable for Windows desktop, copies all
    required runtime DLLs, Flutter engine assets, and bundled llama-server/rpc-server
    binaries into a standalone distribution directory (dist\PrivateLM-Windows-x64).
#>

[CmdletBinding()]
param(
    [switch]$LaunchAfterBuild,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
Set-Location $projectRoot

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "  PrivateLM: Native Windows .exe Build & Package   " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# 1. Locate Flutter binary
$flutterBin = "flutter"
$flutterCmd = Get-Command $flutterBin -ErrorAction SilentlyContinue

if (-not $flutterCmd) {
    $candidatePaths = @(
        "$projectRoot\tools\flutter\bin\flutter.bat",
        "C:\src\flutter\bin\flutter.bat",
        "C:\flutter\bin\flutter.bat",
        "$env:USERPROFILE\flutter\bin\flutter.bat",
        "$env:LOCALAPPDATA\flutter\bin\flutter.bat"
    )

    foreach ($path in $candidatePaths) {
        if (Test-Path $path) {
            $flutterBin = $path
            Write-Host "-> Found Flutter at: $flutterBin" -ForegroundColor Green
            break
        }
    }
}

if (-not (Get-Command $flutterBin -ErrorAction SilentlyContinue) -and -not (Test-Path $flutterBin)) {
    Write-Host "`n[ERROR] Flutter SDK not found in PATH or standard directories." -ForegroundColor Red
    Write-Host "To install Flutter on Windows:" -ForegroundColor Yellow
    Write-Host "  1. Run in PowerShell: winget install Google.Flutter" -ForegroundColor White
    Write-Host "  2. Or extract from:   https://docs.flutter.dev/get-started/install/windows/desktop" -ForegroundColor White
    Write-Host "  3. Re-run this script: .\scripts\build_windows.ps1`n" -ForegroundColor White
    exit 1
}

# 2. Check Visual Studio C++ Environment
$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vsWhere) {
    $vsPath = & $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vsPath) {
        Write-Host "-> Detected Visual Studio C++ Tools at: $vsPath" -ForegroundColor Green
    }
}

# 3. Configure and prepare dependencies
Write-Host "`n[1/4] Enabling Windows desktop and fetching dependencies..." -ForegroundColor Cyan
& $flutterBin config --enable-windows-desktop | Out-Null
& $flutterBin pub get

if (-not $SkipTests) {
    Write-Host "`n[2/4] Running automated cluster & engine tests..." -ForegroundColor Cyan
    & $flutterBin test test/desktop_cluster_test.dart test/lan_discovery_test.dart
} else {
    Write-Host "`n[2/4] Skipping tests (-SkipTests passed)..." -ForegroundColor Yellow
}

# 4. Build release executable
Write-Host "`n[3/4] Compiling native Windows Release binary (privatelm.exe)..." -ForegroundColor Cyan

# Pre-populate ephemeral engine assets if needed
$flutterBinDir = Split-Path -Parent (Resolve-Path $flutterBin)
$engineArtifacts = Join-Path $flutterBinDir "cache\artifacts\engine\windows-x64"
$ephemeralDir = "$projectRoot\windows\flutter\ephemeral"
if (Test-Path $engineArtifacts) {
    if (-not (Test-Path "$ephemeralDir\cpp_client_wrapper")) {
        Copy-Item -Path "$engineArtifacts\cpp_client_wrapper" -Destination "$ephemeralDir\cpp_client_wrapper" -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($f in @("flutter_windows.dll", "flutter_windows.dll.lib", "icudtl.dat")) {
        if (-not (Test-Path "$ephemeralDir\$f")) {
            Copy-Item -Path "$engineArtifacts\$f" -Destination "$ephemeralDir\$f" -Force -ErrorAction SilentlyContinue
        }
    }
}

& $flutterBin build windows --release

$buildOutput = "$projectRoot\build\windows\x64\runner\Release"
if (-not (Test-Path "$buildOutput\privatelm.exe")) {
    Write-Host "`n[ERROR] Build output not found at: $buildOutput\privatelm.exe" -ForegroundColor Red
    exit 1
}

# 5. Assemble standalone distribution directory
Write-Host "`n[4/4] Assembling standalone distribution package..." -ForegroundColor Cyan
$distDir = "$projectRoot\dist\PrivateLM-Windows-x64"
if (Test-Path $distDir) {
    Remove-Item -Path $distDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $distDir | Out-Null

# Copy application binaries and flutter engine
Copy-Item -Path "$buildOutput\*" -Destination $distDir -Recurse -Force

# Bundle local bin/ daemons if present
if (Test-Path "$projectRoot\bin") {
    $targetBin = "$distDir\bin"
    New-Item -ItemType Directory -Force -Path $targetBin | Out-Null
    Copy-Item -Path "$projectRoot\bin\*" -Destination $targetBin -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "-> Bundled local engine binaries into distribution bin/ directory." -ForegroundColor Green
}

# Add quick start readme
$readmeContent = @"
PrivateLM - Cross-Platform Distributed LLM Client (Windows x64)
===============================================================

How to Run:
  Double-click 'privatelm.exe' to launch PrivateLM natively.

LAN Cluster Ports:
  - Port 50052: llama.cpp RPC Layer Splitting & Distributed Workers
  - Port 50053: UDP Zero-Configuration LAN Peer Discovery
  - Port 50050: Local OpenAI-compatible API Gateway (Optional)

Documentation & Roadmap:
  Open 'docs/index.html' in any browser to view the interactive architecture,
  live cluster RAM and layer calculator, and milestone tracker.
"@
$readmeContent | Out-File -FilePath "$distDir\README.txt" -Encoding utf8

# Create standalone zip archive
$zipPath = "$projectRoot\dist\PrivateLM-Windows-x64.zip"
if (Test-Path $zipPath) {
    Remove-Item -Path $zipPath -Force
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($distDir, $zipPath)
Write-Host "-> Created standalone ZIP archive: $zipPath" -ForegroundColor Green

Write-Host "`n====================================================" -ForegroundColor Green
Write-Host "  SUCCESS: Native Windows Executable Built!         " -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Green
Write-Host "Executable:  $distDir\privatelm.exe" -ForegroundColor White
Write-Host "Package Dir: $distDir" -ForegroundColor White

if ($LaunchAfterBuild) {
    Write-Host "`nLaunching privatelm.exe..." -ForegroundColor Cyan
    Start-Process -FilePath "$distDir\privatelm.exe"
}
