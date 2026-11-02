#requires -Version 5.1
<#
.SYNOPSIS
    脱敏发布构建：把仓库复制到一个**中性路径**再构建，构建完自动跑发布前断言门，
    门失败就删掉产物并非 0 退出。

.DESCRIPTION
    为什么必须"先复制到脱敏目录再构建"
    ----------------------------------
    Dart AOT 快照（Android 的 `lib/<abi>/libapp.so`、Windows 的 `data/app.so`）会把
    **构建时的工作目录绝对路径**编进去。在真实工作区里直接 `flutter build`，
    `<工作区根>/...`、`<系统用户目录>/...` 这类路径就随产物一起公开分发；
    改成从中性目录（如 `C:\build\jizhicha-<ver>-sanitize\jizhicha`）构建，
    编进去的就是中性路径，问题自然消失。这是 v1.0.2/v1.0.3 用过、
    v1.0.4 起被丢弃、需要恢复的做法。

    本脚本负责：
      1) 把签名凭据从 **User 级环境变量**提升进当前进程（已启动的 shell 不会回溯继承）；
      2) 复制仓库到中性目录，**排除 .git / build / .dart_tool / release / HANDOFF.md /
         docs/internal / *.jks / key.properties / *.apk / *.zip**，并校验脱敏目录里
         **没有任何签名密钥文件**；
      3) 在脱敏目录里执行作者既定口径的单 APK 构建：
         `flutter build apk --release --target-platform android-arm64`；
      4) 自动调用 `tool/check_release_artifacts.ps1` 断言门；
      5) 门失败 → **删除产物** 并非 0 退出；门通过 → 可选把 APK 拷到指定输出目录。

    本脚本**不做** git 写操作（不 commit / add / stash / checkout）。

.PARAMETER Version
    版本号，用于拼接脱敏目录名与产物名，例如 `1.1.0+13000` 或 `1.1.0`。
    省略时自动读 `pubspec.yaml` 的 `version:`。

.PARAMETER SanitizeRoot
    脱敏工作区根目录，默认 `C:\build`。实际构建目录为
    `<SanitizeRoot>\jizhicha-<version>-sanitize\jizhicha`。

.PARAMETER OutDir
    可选：门通过后把 APK 复制到该目录。

.PARAMETER Force
    工作区有未提交改动时继续（默认只告警并要求本开关）。
    ⚠️ 构建会调用 cargo（`android/app/build.gradle.kts` 的 buildRustAndroid*），
       `huse-vpn-next/` 下的未完成改动会被编进原生库，导致"半改状态"产物。

.PARAMETER SkipBuild
    只做环境准备 + 复制 + 断言门（对已存在的产物），不执行 flutter build。用于验证流程本身。

.PARAMETER NoCopy
    跳过第 4 步的复制（复用已存在的脱敏目录）。用于在已复制好的目录上做流程验证；
    ⚠️ 日常发布**不要**用它 —— 不重新复制就无法保证产物是在中性目录里构建的。

.PARAMETER KeepWorkDir
    构建结束后保留脱敏目录（默认保留，便于排查；传 -KeepWorkDir:$false 可删）。

.EXAMPLE
    .\tool\build_release_sanitized.ps1 -Version 1.1.0+13000
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$SanitizeRoot = 'C:\build',
    [string]$OutDir,
    [switch]$Force,
    [switch]$SkipBuild,
    [switch]$NoCopy,
    [bool]$KeepWorkDir = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)      # .../jizhicha
$script:ToolDir = Join-Path $RepoRoot 'tool'
$script:GateScript = Join-Path $ToolDir 'check_release_artifacts.ps1'

# 复制时要排除的目录（相对仓库根，脚本会展开成绝对路径）。
#   * 密钥/内部资料：`.git`（含全部历史，绝不能带出去）、`release`（未公开归档 + 密钥）、
#     `docs\internal`、`android\app\release`、`.idea`
#   * 重新生成的构建产物（不带过去纯粹是省时间省空间，都会在脱敏目录里重建）：
#     `build`、`.dart_tool`、`huse-vpn-next\target`（本机实测 ~19 GB 的 cargo 中间产物）、
#     `windows\flutter\ephemeral`（含 .plugin_symlinks，正是 Windows 包路径泄漏的来源）、
#     `android\.gradle`、`android\build`
# ⚠️ robocopy 的 /XD、/XF 是拿**绝对路径**与通配模式比对的：传相对路径不会命中，
#    所以下面统一展开成绝对路径（`release` 当初"看起来生效"只是巧合 —— 绝对路径里恰好含 release）。
$ExcludeDirNames = @(
    '.git', '.idea', 'build', '.dart_tool', 'release', 'docs\internal', 'android\app\release',
    'huse-vpn-next\target', 'windows\flutter\ephemeral', 'linux\flutter\ephemeral',
    'android\.gradle', 'android\build'
)
$ExcludeFilePatterns = @('HANDOFF.md', '*.jks', '*.keystore', '*.p12', '*.pfx', 'key.properties', '*.apk', '*.zip', '*.aab', '*.iml')

function Get-SafePathLabel {
    param([string]$p)
    # 日志里不打印真实工作区路径/账户名
    # 工作区根按 RepoRoot 反推（3 层父目录），脚本里不写死任何本机路径字面量。
    $wsRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $RepoRoot))
    if ($wsRoot) { $p = $p -replace [regex]::Escape($wsRoot), '<workspace-root>' }
    return ($p -replace '(?i)([A-Z]:\{1,2}Users\{1,2})[^\/]+', '${1}***')
}

function Write-Step { param([string]$m) Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }
function Write-Warn { param([string]$m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Err { param([string]$m) Write-Host "[ERROR] $m" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# 0. 前置检查
# ---------------------------------------------------------------------------
Write-Step '0. 前置检查'

if (-not (Test-Path -LiteralPath $GateScript)) {
    Write-Err "找不到断言门脚本: $GateScript"
    exit 2
}

if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'pubspec.yaml'))) {
    Write-Err "此处不是 jizhicha 仓库（缺 pubspec.yaml）: $(Get-SafePathLabel $RepoRoot)"
    exit 2
}

# 版本号：未指定则从 pubspec.yaml 读
if (-not $Version) {
    $verLine = Select-String -LiteralPath (Join-Path $RepoRoot 'pubspec.yaml') -Pattern '^version:\s*(.+)$' | Select-Object -First 1
    if (-not $verLine) { Write-Err '无法从 pubspec.yaml 读出 version，请用 -Version 指定'; exit 2 }
    $Version = $verLine.Matches[0].Groups[1].Value.Trim()
}
$verSafe = ($Version -replace '[^A-Za-z0-9._\-]', '_')
$workRoot = Join-Path $SanitizeRoot ("jizhicha-{0}-sanitize" -f $verSafe)
$src = Join-Path $workRoot 'jizhicha'

# 磁盘空间：Android release 构建（含 cargo 重编原生库）需要数 GB 余量
try {
    $driveLetter = (Split-Path -Qualifier $SanitizeRoot).TrimEnd(':')
    $freeGB = [math]::Round((Get-PSDrive -Name $driveLetter).Free / 1GB, 1)
    if ($freeGB -lt 3) { Write-Err ("脱敏根所在盘可用空间仅 {0} GB，不足以完成构建" -f $freeGB); exit 2 }
    Write-Host ("脱敏根所在盘可用空间: {0} GB" -f $freeGB)
}
catch { Write-Warn '无法读取磁盘可用空间，跳过该项检查' }

Write-Host ("仓库根      : {0}" -f (Get-SafePathLabel $RepoRoot))
Write-Host ("版本        : {0}" -f $Version)
Write-Host ("脱敏构建目录: {0}" -f $workRoot)

# ---------------------------------------------------------------------------
# 0.5 源码隐私门禁（按字段形态扫描已跟踪文件）
# ---------------------------------------------------------------------------
Write-Step '0.5 源码隐私门禁（按字段形态扫描已跟踪文件）'
$piiScript = Join-Path $ToolDir 'check_pii.ps1'
if (Test-Path -LiteralPath $piiScript) {
    & $piiScript -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) { Write-Err '源码隐私门禁未通过，已中止构建。'; exit 1 }
} else {
    Write-Warn '未找到 tool/check_pii.ps1，跳过源码隐私门禁（不建议）。'
}

# ---------------------------------------------------------------------------
# 1. 签名凭据：从 User 级环境变量提升到当前进程（已启动的 shell 不会回溯继承）
# ---------------------------------------------------------------------------
Write-Step '1. 提升签名凭据环境变量（User 级 → 进程级）'

foreach ($n in 'JIZHICHA_KEYSTORE_FILE', 'JIZHICHA_KEY_ALIAS', 'JIZHICHA_STORE_PASSWORD', 'JIZHICHA_KEY_PASSWORD') {
    $v = [Environment]::GetEnvironmentVariable($n, 'User')
    if ($v) { Set-Item -Path "env:$n" -Value $v }
}

$missing = @()
foreach ($n in 'JIZHICHA_KEYSTORE_FILE', 'JIZHICHA_KEY_ALIAS', 'JIZHICHA_STORE_PASSWORD', 'JIZHICHA_KEY_PASSWORD') {
    if (-not [Environment]::GetEnvironmentVariable($n, 'Process')) { $missing += $n }
}
if ($missing.Count -gt 0) {
    Write-Err ("缺少签名环境变量（User 级未设置）: {0}" -f ($missing -join ', '))
    Write-Err '按 §4 红线：正式构建必须使用独立 release keystore，没有密钥时构建应主动失败。'
    exit 2
}
# 只报"已设置/指向的文件是否存在"，绝不打印值
$ksPath = [Environment]::GetEnvironmentVariable('JIZHICHA_KEYSTORE_FILE', 'Process')
if (-not (Test-Path -LiteralPath $ksPath)) {
    Write-Err ("JIZHICHA_KEYSTORE_FILE 指向的文件不存在（值已掩码）: {0}" -f (Get-SafePathLabel $ksPath))
    exit 2
}
Write-Host '  4 个签名环境变量均已提升到进程环境（值不打印）'

# ---------------------------------------------------------------------------
# 2. 工具链环境
# ---------------------------------------------------------------------------
Write-Step '2. 工具链环境'

$env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr'
# PUB_CACHE 不写死本机路径：优先用调用者传入的，否则按工作区根推导。
if (-not $env:PUB_CACHE) {
    $wsRootGuess = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $RepoRoot))
    if ($wsRootGuess) { $env:PUB_CACHE = Join-Path $wsRootGuess 'jizhicha-pub-cache' }
}
# Gradle 缓存放到中性路径：gradle 的 daemon/日志里也可能带构建目录路径
$gradleHome = Join-Path $SanitizeRoot 'gradle-home-sanitize'
$env:GRADLE_USER_HOME = $gradleHome
New-Item -ItemType Directory -Force -Path $gradleHome | Out-Null

if (-not $env:ANDROID_HOME) {
    $sdkGuess = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
    if (Test-Path -LiteralPath $sdkGuess) { $env:ANDROID_HOME = $sdkGuess } else { $env:ANDROID_HOME = $env:ANDROID_SDK_ROOT }
}
if (-not $env:ANDROID_HOME) {
    Write-Err 'ANDROID_HOME / ANDROID_SDK_ROOT 均未设置，无法进行 Android 构建'
    exit 2
}

$flutter = (Get-Command flutter -ErrorAction SilentlyContinue)
if (-not $flutter) { Write-Err 'PATH 里找不到 flutter'; exit 2 }
$cargo = (Get-Command cargo -ErrorAction SilentlyContinue)
if (-not $cargo) { Write-Warn 'PATH 里找不到 cargo —— 若构建需要重编 Rust 原生库会失败' }

Write-Host ("  JAVA_HOME       = {0}" -f $env:JAVA_HOME)
Write-Host ("  PUB_CACHE       = {0}" -f (Get-SafePathLabel $env:PUB_CACHE))
Write-Host ("  GRADLE_USER_HOME= {0}" -f (Get-SafePathLabel $env:GRADLE_USER_HOME))
Write-Host ("  ANDROID_HOME    = {0}" -f (Get-SafePathLabel $env:ANDROID_HOME))
Write-Host ("  flutter         = {0}" -f $flutter.Source)

# ---------------------------------------------------------------------------
# 3. 未提交改动检查（**只读**，不做任何 git 写操作）
# ---------------------------------------------------------------------------
Write-Step '3. 未提交改动检查（只读 git status）'

$dirty = @()
try {
    $st = & git -C $RepoRoot status --porcelain 2>$null
    if ($LASTEXITCODE -eq 0 -and $st) { $dirty = @($st) }
}
catch { Write-Warn 'git status 调用失败，跳过该项检查' }

$rustDirty = @($dirty | Where-Object { $_ -match 'huse-vpn-next' })
if ($dirty.Count -gt 0) {
    Write-Warn ("工作区有 {0} 处未提交改动" -f $dirty.Count)
    foreach ($d in $dirty) { Write-Host ("    {0}" -f $d) -ForegroundColor DarkYellow }
    if ($rustDirty.Count -gt 0) {
        Write-Warn ("其中 {0} 处落在 huse-vpn-next/ —— 构建会调用 cargo 重编原生库，未完成的 Rust 改动会被编进产物" -f $rustDirty.Count)
    }
    else {
        Write-Warn '构建会调用 cargo 重编 Rust 原生库，未提交改动都会进入产物'
    }
    if (-not $Force) {
        Write-Err '拒绝在未提交改动上构建。确认无碍后加 -Force 重跑。'
        exit 3
    }
    Write-Warn '-Force 已指定，继续；请自行确认上述改动的可发布性。'
}
else {
    Write-Host '  工作区干净'
}

# ---------------------------------------------------------------------------
# 4. 复制到中性路径（排除密钥与内部资料）
# ---------------------------------------------------------------------------
Write-Step '4. 复制仓库到脱敏目录'

if ($NoCopy) {
    if (-not (Test-Path -LiteralPath (Join-Path $src 'pubspec.yaml'))) {
        Write-Err ("-NoCopy 但脱敏目录不存在或不完整: {0}" -f (Get-SafePathLabel $src))
        exit 4
    }
    Write-Warn '-NoCopy：复用已存在的脱敏目录，跳过了重新复制与排除项校验（仅用于流程验证）'
}
else {

    if (Test-Path -LiteralPath $src) {
        $resolved = (Resolve-Path -LiteralPath $src).ProviderPath
        if ($resolved -notlike "$SanitizeRoot*") {
            Write-Err ("拒绝删除不在 SanitizeRoot 下的目录: {0}" -f (Get-SafePathLabel $resolved))
            exit 2
        }
        Write-Host ("  清理已存在的脱敏目录: {0}" -f (Get-SafePathLabel $src))
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

    $robocopyArgs = @($RepoRoot, $src, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/R:1', '/W:1')
    $robocopyArgs += '/XD'
    foreach ($d in $ExcludeDirNames) { $robocopyArgs += (Join-Path $RepoRoot $d) }
    $robocopyArgs += '/XF'
    $robocopyArgs += $ExcludeFilePatterns
    & robocopy @robocopyArgs | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { Write-Err ("robocopy 失败，退出码 {0}" -f $rc); exit 4 }
    Write-Host ("  robocopy 完成（退出码 {0}）" -f $rc)

    if (-not (Test-Path -LiteralPath (Join-Path $src 'pubspec.yaml'))) { Write-Err '复制结果不完整（缺 pubspec.yaml）'; exit 4 }

    # 排除项校验：这些目录/文件在脱敏目录里**必须不存在**（robocopy 的 /XD、/XF 是绝对路径匹配，
    # 配错了会静默漏拷 —— 比如 19 GB 的 cargo target 目录）
    foreach ($d in $ExcludeDirNames) {
        $p = Join-Path $src $d
        if (Test-Path -LiteralPath $p) {
            Write-Err ("排除失败：脱敏目录里仍有 {0}，请检查 robocopy 参数" -f $d)
            exit 4
        }
    }
}

# 脱敏目录里**绝不能**有签名密钥文件
$keyHits = Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.jks', '.keystore', '.p12', '.pfx' -or $_.Name -eq 'key.properties' -or $_.Name -eq 'HANDOFF.md' }
$keyHits = @($keyHits)
if ($keyHits.Count -gt 0) {
    Write-Err ("脱敏目录里仍有不该出现的文件 {0} 个，已中止并清理:" -f $keyHits.Count)
    foreach ($k in $keyHits) {
        Write-Err ("    {0}" -f (Get-SafePathLabel $k.FullName))
        Remove-Item -LiteralPath $k.FullName -Force -ErrorAction SilentlyContinue
    }
    exit 5
}
Write-Host ("  脱敏目录已校验：无 *.jks/*.keystore/*.p12/*.pfx/key.properties/HANDOFF.md")
Write-Host ("  脱敏目录: {0}" -f (Get-SafePathLabel $src))

# ---------------------------------------------------------------------------
# 5. 构建
# ---------------------------------------------------------------------------
$apk = Join-Path $src 'build\app\outputs\flutter-apk\app-release.apk'

if ($SkipBuild) {
    Write-Step '5. 构建 —— 已跳过（-SkipBuild）'
    if (-not (Test-Path -LiteralPath $apk)) {
        Write-Err ("-SkipBuild 但脱敏目录里没有产物可验: {0}" -f (Get-SafePathLabel $apk))
        exit 6
    }
}
else {
    Write-Step '5. 在脱敏目录执行 flutter build apk（单 APK 口径：仅 arm64）'
    Push-Location $src
    try {
        & flutter pub get
        if ($LASTEXITCODE -ne 0) { Write-Err 'flutter pub get 失败'; exit 7 }

        & flutter build apk --release --target-platform android-arm64
        if ($LASTEXITCODE -ne 0) { Write-Err ("flutter build apk 失败（退出码 {0}）" -f $LASTEXITCODE); exit 7 }
    }
    finally { Pop-Location }
}

if (-not (Test-Path -LiteralPath $apk)) { Write-Err ("构建结束但找不到产物: {0}" -f (Get-SafePathLabel $apk)); exit 7 }

# ---------------------------------------------------------------------------
# 6. 发布前断言门（失败即删产物）
# ---------------------------------------------------------------------------
Write-Step '6. 发布前断言门'

& $GateScript -Path $apk -NoColor
$gateRc = $LASTEXITCODE
if ($gateRc -ne 0) {
    Write-Err ("断言门失败（退出码 {0}）—— 删除产物并中止发布" -f $gateRc)
    Remove-Item -LiteralPath $apk -Force -ErrorAction SilentlyContinue
    Write-Err ("已删除: {0}" -f (Get-SafePathLabel $apk))
    Write-Err '恢复方式：把仓库复制到中性目录再构建（本脚本就是干这个的），不要跳过断言门。'
    exit 8
}

# ---------------------------------------------------------------------------
# 7. 交付
# ---------------------------------------------------------------------------
Write-Step '7. 完成'
$size = (Get-Item -LiteralPath $apk).Length
Write-Host ("  APK   : {0}" -f (Get-SafePathLabel $apk))
Write-Host ("  大小  : {0} B" -f $size)
Write-Host ("  版本  : {0}" -f $Version)

if ($OutDir) {
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $outName = "Jizhicha-v{0}-arm64.apk" -f ($Version -replace '\+.*$', '')
    $target = Join-Path $OutDir $outName
    Copy-Item -LiteralPath $apk -Destination $target -Force
    Write-Host ("  已输出: {0}" -f (Get-SafePathLabel $target))
}

if (-not $KeepWorkDir) {
    Remove-Item -LiteralPath $src -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '  已删除脱敏工作目录'
}

exit 0
