<#
.SYNOPSIS
    Starts the llama.cpp RPC server on port 50052 for LAN model offloading.
#>

$binDir = Join-Path $PSScriptRoot "..\bin"
$rpcServer = Join-Path $binDir "rpc-server.exe"

if (-not (Test-Path $rpcServer)) {
    Write-Host "rpc-server.exe not found in bin/. Downloading binaries first..." -ForegroundColor Yellow
    & "$PSScriptRoot\download_desktop_binaries.ps1"
}

if (-not (Test-Path $rpcServer)) {
    Write-Error "Could not locate rpc-server.exe."
    exit 1
}

# Find local LAN IP
$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { 
    $_.InterfaceAlias -notmatch "vEthernet|Virtual|WSL|Docker|Loopback" -and 
    $_.IPAddress -notlike "169.254.*" -and 
    $_.IPAddress -notlike "127.*" 
} | Select-Object -First 1).IPAddress

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  PrivateLM PC Cluster Worker" -ForegroundColor Cyan
Write-Host "  LAN Endpoint: $ip`:50052" -ForegroundColor Green
Write-Host "  Listening on 0.0.0.0:50052..." -ForegroundColor Yellow
Write-Host "======================================================" -ForegroundColor Cyan

& $rpcServer -H 0.0.0.0 -p 50052
