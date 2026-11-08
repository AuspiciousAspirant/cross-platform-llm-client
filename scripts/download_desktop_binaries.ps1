<#
.SYNOPSIS
    Downloads and extracts official llama.cpp binaries (llama-server.exe & ggml-rpc-server.exe)
    for PrivateLM on Windows.
#>

[CmdletBinding()]
param(
    [string]$TargetDir = ""
)

$ErrorActionPreference = "Stop"

if (-not [string]::IsNullOrWhiteSpace($TargetDir)) {
    $binDir = $TargetDir
} elseif (Test-Path "bin") {
    $binDir = (Resolve-Path "bin").Path
} else {
    $binDir = Join-Path $PSScriptRoot "..\bin"
}

if (-not (Test-Path $binDir)) {
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
}

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "  PrivateLM: Automated Engine & RPC Installer       " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "Target Directory: $binDir" -ForegroundColor White
Write-Host "Checking latest llama.cpp release from GitHub..." -ForegroundColor Cyan

$apiUrls = @(
    "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest",
    "https://api.github.com/repos/ggerganov/llama.cpp/releases/latest"
)
$headers = @{
    "User-Agent" = "PrivateLM-LLM-Client"
    "Accept"     = "application/vnd.github.v3+json"
}

$release = $null
foreach ($url in $apiUrls) {
    try {
        $release = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 15
        if ($release) { break }
    } catch {
        Write-Warning "Could not reach $url : $_"
    }
}

$vulkanAsset = $release.assets | Where-Object { $_.name -like "*bin-win-vulkan-x64.zip" } | Select-Object -First 1
$avx2Asset   = $release.assets | Where-Object { $_.name -like "*bin-win-avx2-x64.zip" } | Select-Object -First 1
$chosenAsset = if ($vulkanAsset) { $vulkanAsset } else { $avx2Asset }

if (-not $chosenAsset) {
    Write-Error "No compatible Windows binary release found."
    exit 1
}

$zipPath = Join-Path $binDir $chosenAsset.name
Write-Host "Downloading $($chosenAsset.name) ($([math]::Round($chosenAsset.size / 1MB, 1)) MB)..." -ForegroundColor Green
Invoke-WebRequest -Uri $chosenAsset.browser_download_url -OutFile $zipPath

Write-Host "Extracting binaries to $binDir..." -ForegroundColor Green
Expand-Archive -Path $zipPath -DestinationPath $binDir -Force

# Clean up zip
Remove-Item $zipPath -Force

Write-Host "`n✓ Setup complete! Found tools in $binDir:" -ForegroundColor Cyan
Get-ChildItem -Path $binDir -Filter "*.exe" | ForEach-Object {
    Write-Host "  - $($_.Name)" -ForegroundColor Yellow
}
