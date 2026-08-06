# Download and verify the bundled gof5 (open-source F5 VPN client) and wintun driver.
# Usage: run in project root, or:  .\tools\download_gof5.ps1

$ErrorActionPreference = 'Stop'

$root      = $PSScriptRoot
$gof5Dst   = Join-Path $root 'gof5_windows_amd64.exe'
$gof5Url   = 'https://github.com/kayrus/gof5/releases/download/v0.1.5/gof5_windows_amd64.exe'
$gof5Sha   = '3AE2114B9D9799276B22F612B8986705CBCD41B4F94272A8BA79E149978534EA'

$wintunDst = Join-Path $root 'wintun.dll'
$wintunZip = Join-Path $root 'wintun.zip'
$wintunUrl = 'https://www.wintun.net/builds/wintun-0.14.1.zip'
$wintunSha = '07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51'

function Clean-File($p) {
  if (Test-Path $p) { Remove-Item $p -Force -Recurse -ErrorAction SilentlyContinue }
}

function Verify-Sha256($file, $expected, $label) {
  $hash = (Get-FileHash -Algorithm SHA256 $file).Hash.ToUpper()
  Write-Host "    $label SHA256: $hash"
  if ($hash -ne $expected.ToUpper()) {
    Write-Host "[!] $label SHA256 mismatch, file corrupted or replaced. Retry or use another network." -ForegroundColor Red
    exit 1
  }
}

# --- gof5 ----------------------------------------------------------------
Clean-File $gof5Dst
Write-Host "[1/4] Downloading gof5 ..." -ForegroundColor Cyan
Write-Host "    $gof5Url"
Invoke-WebRequest -Uri $gof5Url -OutFile $gof5Dst -UseBasicParsing

Write-Host "[2/4] Verifying gof5 SHA256 ..." -ForegroundColor Cyan
Verify-Sha256 $gof5Dst $gof5Sha 'gof5'
$gof5Size = [math]::Round((Get-Item $gof5Dst).Length / 1MB, 2)
Write-Host "    gof5 size: $gof5Size MB" -ForegroundColor Green

# --- wintun --------------------------------------------------------------
Clean-File $wintunDst
Clean-File $wintunZip
Write-Host "[3/4] Downloading wintun ..." -ForegroundColor Cyan
Write-Host "    $wintunUrl"
Invoke-WebRequest -Uri $wintunUrl -OutFile $wintunZip -UseBasicParsing

Write-Host "[4/4] Verifying wintun SHA256 and extracting amd64/wintun.dll ..." -ForegroundColor Cyan
Verify-Sha256 $wintunZip $wintunSha 'wintun.zip'

$tmp = Join-Path $root '_wintun_unpack'
Clean-File $tmp
Expand-Archive -Path $wintunZip -DestinationPath $tmp -Force
$src = Join-Path $tmp 'wintun\bin\amd64\wintun.dll'
if (-not (Test-Path $src)) {
  Write-Host "[!] Expected $src not found in zip" -ForegroundColor Red
  exit 1
}
Move-Item $src -Destination $wintunDst -Force
Clean-File $tmp
Clean-File $wintunZip

$wintunSize = [math]::Round((Get-Item $wintunDst).Length / 1KB, 1)
Write-Host "    wintun size: $wintunSize KB" -ForegroundColor Green

Write-Host ""
Write-Host "All assets ready. Now run:  flutter clean; flutter run -d windows  (as Administrator)" -ForegroundColor Yellow
