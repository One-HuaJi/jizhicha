<#
.SYNOPSIS
校验一个 release APK 的包名、versionCode/versionName、ABI 与签名证书。

.DESCRIPTION
发布前手工核对六项（versionCode、ABI、签名、SHA……）时，最容易出错的是
「以为验过了，其实验的是上一个包」。这个脚本把能从 APK 里直接读出来的事实
全部读出来并和期望值比对，任何一项不符就非零退出，供 CI 或本地门禁调用。

.EXAMPLE
pwsh tool/verify_release_apk.ps1 -Apk release/official/v1.1.1/jizhicha-1.1.1-arm64-v8a.apk -ExpectedVersionName 1.1.1 -ExpectedVersionCode 13001
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Apk,
    [Parameter(Mandatory = $true)][string]$ExpectedVersionName,
    [Parameter(Mandatory = $true)][int]$ExpectedVersionCode,
    [string]$ExpectedPackage = 'com.one.huaji',
    [string[]]$ExpectedAbi = @('arm64-v8a'),
    # 期望的签名证书 SHA-256（大写十六进制，不带冒号）。留空则只要求「已签名且校验通过」。
    [string]$ExpectedCertSha256 = '',
    [string]$AndroidSdk = ''
)

$ErrorActionPreference = 'Stop'

function Fail([string]$message) {
    Write-Host "FAIL: $message" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $Apk)) { Fail "APK 不存在：$Apk" }
$Apk = (Resolve-Path -LiteralPath $Apk).Path

if ([string]::IsNullOrWhiteSpace($AndroidSdk)) {
    $AndroidSdk = $env:ANDROID_SDK_ROOT
    if ([string]::IsNullOrWhiteSpace($AndroidSdk)) { $AndroidSdk = $env:ANDROID_HOME }
}
if ([string]::IsNullOrWhiteSpace($AndroidSdk)) { Fail '找不到 Android SDK：请设置 ANDROID_SDK_ROOT / ANDROID_HOME。' }

$buildToolsRoot = Join-Path $AndroidSdk 'build-tools'
if (-not (Test-Path -LiteralPath $buildToolsRoot)) { Fail "SDK 里没有 build-tools：$buildToolsRoot" }

# 取版本号最大的 build-tools（目录名形如 36.0.0）。
$buildTools = Get-ChildItem -LiteralPath $buildToolsRoot -Directory |
    Where-Object { $_.Name -match '^\d+(\.\d+)*$' } |
    Sort-Object { [version]($_.Name) } -Descending |
    Where-Object { (Test-Path (Join-Path $_.FullName 'aapt2.exe')) -or (Test-Path (Join-Path $_.FullName 'aapt2')) } |
    Select-Object -First 1
if (-not $buildTools) { Fail "build-tools 里找不到 aapt2：$buildToolsRoot" }

$aapt2 = Join-Path $buildTools.FullName 'aapt2.exe'
if (-not (Test-Path -LiteralPath $aapt2)) { $aapt2 = Join-Path $buildTools.FullName 'aapt2' }
$apksigner = Join-Path $buildTools.FullName 'apksigner.bat'
if (-not (Test-Path -LiteralPath $apksigner)) { $apksigner = Join-Path $buildTools.FullName 'apksigner' }

Write-Host "build-tools: $($buildTools.Name)"

# ---- 1) badging：包名 / versionCode / versionName / ABI ----
$badging = & $aapt2 dump badging $Apk 2>&1
if ($LASTEXITCODE -ne 0) { Fail "aapt2 dump badging 失败：$badging" }
$packageLine = $badging | Where-Object { $_ -like 'package:*' } | Select-Object -First 1
if (-not $packageLine) { Fail 'badging 输出里没有 package 行' }

$packageName = if ($packageLine -match "name='([^']+)'") { $Matches[1] } else { '' }
$versionCode = if ($packageLine -match "versionCode='(\d+)'") { [int]$Matches[1] } else { -1 }
$versionName = if ($packageLine -match "versionName='([^']*)'") { $Matches[1] } else { '' }

$nativeCode = @()
$nativeLine = $badging | Where-Object { $_ -like 'native-code:*' } | Select-Object -First 1
if ($nativeLine -and $nativeLine -match 'native-code:\s*\[?([^\]]*)\]?') {
    $nativeCode = $Matches[1].Split(',') | ForEach-Object { $_.Trim().Trim("'") } | Where-Object { $_ }
}

Write-Host "package      : $packageName"
Write-Host "versionName  : $versionName"
Write-Host "versionCode  : $versionCode"
Write-Host "native-code  : $($nativeCode -join ', ')"

if ($packageName -ne $ExpectedPackage) { Fail "包名不符：期望 $ExpectedPackage，实际 $packageName" }
if ($versionName -ne $ExpectedVersionName) { Fail "versionName 不符：期望 $ExpectedVersionName，实际 $versionName" }
if ($versionCode -ne $ExpectedVersionCode) { Fail "versionCode 不符：期望 $ExpectedVersionCode，实际 $versionCode" }

$installedIn = $nativeCode -join ','
$wantedIn = $ExpectedAbi -join ','
if ($installedIn -ne $wantedIn) { Fail "ABI 不符：期望 $wantedIn，实际 $installedIn" }

# ---- 2) apksigner：必须已签名且校验通过 ----
$verifyOutput = & $apksigner verify --verbose --print-certs $Apk 2>&1
if ($LASTEXITCODE -ne 0) { Fail "apksigner verify 失败：$verifyOutput" }
$certLine = $verifyOutput | Where-Object { $_ -match 'certificate SHA-256 digest:' } | Select-Object -First 1
if (-not $certLine) { Fail 'apksigner 输出里没有证书 SHA-256' }
# apksigner 输出的标签本身含冒号：`Signer #1 certificate SHA-256 digest: AB:CD…`。
# 必须取**最后一个**冒号后的值；用 -split 2 会把 `CERTIFICATE SHA-256 DIGEST …` 也留下。
$certSha256 = ($certLine -split ':')[-1].Trim().Replace(':','').ToUpperInvariant()
if ($certSha256 -notmatch '^[0-9A-F]{64}$') { Fail "无法解析签名证书 SHA-256：$certLine" }
Write-Host "signer SHA256: $certSha256"

if (-not [string]::IsNullOrWhiteSpace($ExpectedCertSha256)) {
    $expected = $ExpectedCertSha256.Replace(':','').ToUpperInvariant()
    if ($expected -notmatch '^[0-9A-F]{64}$') { Fail 'ExpectedCertSha256 必须是 64 位十六进制指纹。' }
    if ($certSha256 -ne $expected) { Fail "签名证书不符：期望 $expected，实际 $certSha256" }
}

Write-Host 'OK: APK 元数据与签名校验通过。' -ForegroundColor Green
