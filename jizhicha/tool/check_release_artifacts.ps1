#requires -Version 5.1
<#
.SYNOPSIS
    发布前断言门：扫描发布产物（Android APK / Windows 发布 zip）里是否嵌入了
    "构建机本地路径"等不应出现在公开产物中的字符串。命中即失败（退出码 1）。

.DESCRIPTION
    背景（为什么需要这道门）
    ------------------------
    Dart AOT 快照会把**构建时的工作目录绝对路径**编进产物：
    受影响条目为 Android APK 的 `lib/<abi>/libapp.so`、Windows 发布包的 `data/app.so`
    以及插件 DLL（`gal_plugin.dll`，其 `.plugin_symlinks` 路径同样来自构建目录）。
    一旦在 `/home/...`、`C:\Users\<账户>\...`、`D:/<工作区>/...` 这类真实路径下直接
    `flutter build`，这些路径就会随产物一起公开分发；而把仓库复制到一个**中性的脱敏目录**
    再构建，编进去就是中性路径，问题自然消失。

    ⇒ 因此正确做法是"**先复制到脱敏目录再构建**"（见同目录 build_release_sanitized.ps1），
      本脚本只负责在**发出去之前**把它验出来。本脚本**只检查、不修复**（没有 -Fix）。

.PARAMETER Path
    一个或多个路径：APK 文件、Windows 发布 zip 文件，或包含它们的目录（目录会被递归展开）。

.PARAMETER NoColor
    关闭红/绿着色（便于把输出贴进 CI 日志或文档）。

.OUTPUTS
    退出码 0 = 全部通过；1 = 有命中 / 参数或读取错误；2 = 用法错误。

.EXAMPLE
    .\tool\check_release_artifacts.ps1 -Path .\build\app\outputs\flutter-apk\app-release.apk

.EXAMPLE
    .\tool\check_release_artifacts.ps1 -Path .\release\official\v1.0.3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]]$Path,

    [switch]$NoColor,

    # 每个产物最多列出多少条命中明细（默认 20；总数与"按规则"计数始终完整给出）。
    # 存在的理由：debug/内部产物里同一个形态可能出现几百次（实测某内部 Windows 包
    # 在 huse_vpn_ffi.dll 里有 538 处），全量打印会把 CI 日志冲爆、反而让人看不清。
    [ValidateRange(1, 10000)]
    [int]$MaxHits = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 规则：命中即失败的形态
#   * AAAAAihaveideas —— 本机工作区盘根目录名，出现即说明用的是真实构建目录
#   * com\.one\.       —— 工作区上层目录名；**但本应用自己的包名 com.one.huaji 是合法标识**，
#                         它在 MethodChannel 名（com.one.huaji/widget_settings 等）里必然出现，
#                         故对"恰好就是本包名"的出现做精确豁免（见 Test-Forbidden）
#   * C:\\Users\\      —— Windows 用户目录（真实构建账户名）
#   * /Users/          —— macOS 用户目录
#   * /home/           —— Linux 用户目录
# ---------------------------------------------------------------------------
$ForbiddenPatterns = [ordered]@{
    'workspace-root' = 'AAAAAihaveideas'
    # 匹配整个 token（必须带上 '.' 后面的字符），否则无法对"恰好是本应用包名"
    # 的形态做精确豁免 —— 只看前缀 com.one. 的话，合法包名与泄漏路径长得一模一样。
    'workspace-dir'  = 'com\.one\.[A-Za-z0-9_.\-]*'
    'windows-user'   = 'C:\\Users\\'
    'macos-user'     = '/Users/'
    'linux-user'     = '/home/'
}

# 允许出现的"本应用自有标识"：包名本身及其自有派生（MethodChannel 名 / 广播 action 名）。
# 这些是应用自己的命名空间，必然出现在 classes.dex 与 libapp.so 里，不是隐私泄漏。
# ⚠️ 维护提醒：若将来 Android 侧新增 `com.one.huaji.<TOKEN>` 形态的字面串，
#    必须把该 token 补进这张表，否则断言门会把它当命中而拦下正确产物。
#    （表内每一项都已在 android/ 源码里核过形态，见 tool/README.md。）
$AllowedSelfIdentifiers = @(
    'com.one.huaji',                      # 包名 / MethodChannel 前缀（com.one.huaji/android_vpn 等）
    'com.one.huaji.ACTION_CLASS_REMINDER',
    'com.one.huaji.ACTION_PIN_WIDGET_RESULT',
    'com.one.huaji.action.CONNECT',
    'com.one.huaji.action.DISCONNECT'
)

# 信息项（不判失败）：构建目录形态，用于人工判断该产物是不是脱敏构建产物。
# 注意 dart_plugin_registrant 这个文件名**任何** Flutter 构建都会有（中性目录也一样），
# 它本身不是违规；违规的是它前面那段构建目录路径 —— 那由上面的禁止规则负责。
$InformationalPatterns = [ordered]@{
    'build-dir' = '(?i)(?:file:///)?[A-Z]:/(?:build|ci|jenkins|work|home|Users)/[^"\x00]{0,72}'
}

# ---------------------------------------------------------------------------
# 掩码：命中原文**绝不**原样进日志（日志会被公开）
# ---------------------------------------------------------------------------
function Get-SafeMask {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Raw)

    $s = $Raw

    # /home/<用户>/... 与 /Users/<用户>/...
    $s = [regex]::Replace($s, '(?i)(/(?:home|Users)/)[^/\\\s"'']+', '${1}***')
    # Windows 用户目录（含双反斜杠变体）
    $s = [regex]::Replace($s, '(?i)([A-Z]:\\{1,2}Users\\{1,2})[^\\/\s"'']+', '${1}***')
    # 本机工作区盘根目录名
    $s = [regex]::Replace($s, '(?i)AAAAAihaveideas', '<workspace-root>')
    # 工作区上层目录名 com.one.<...>
    $s = [regex]::Replace($s, '(?i)(com\.one\.)[A-Za-z0-9_.\-]+', '${1}***')
    # 其余盘符路径：只保留盘符，路径主体掩掉（避免任何账户/目录名外泄）
    $s = [regex]::Replace($s, '(?i)([A-Z]:[\\/])(?:[^\\/\s"''\x00]{1,40}[\\/])+[^\\/\s"''\x00]{0,40}', '${1}***')
    # 兜底：依然很长的 token 截断
    if ($s.Length -gt 96) { $s = $s.Substring(0, 96) + '…' }

    return $s
}

function ConvertTo-Latin1String {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    # 不复制数组：直接按字节解释成字符，保证 index 与字节位置一一对应。
    return [System.Text.Encoding]::GetEncoding(28591).GetString($Bytes)
}

function ConvertTo-NormalizedEntryName {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    # zip 条目名的两种写法（'/' 与 '\'）以及 './' 前缀统一成 '/<相对路径>' 形态，
    # 这样匹配规则只需写一套。
    $n = $Name -replace '\\', '/'
    $n = $n.TrimStart('.')
    $n = $n.TrimStart('/')
    return $n
}

function Test-Forbidden {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $ForbiddenPatterns.GetEnumerator()) {
        $found = [regex]::Matches($Text, $entry.Value, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($m in $found) {
            # 豁免：本应用自有标识（精确匹配整段 token，不做前缀放宽）
            $isSelf = $false
            foreach ($self in $AllowedSelfIdentifiers) {
                if ($m.Value -ceq $self) { $isSelf = $true; break }
            }
            if ($isSelf) { continue }
            $hits.Add([pscustomobject]@{
                    Rule     = $entry.Key
                    Offset   = $m.Index
                    Sample   = Get-SafeMask $m.Value
                    # 规则自身的正则在产物里命中的**字面前缀**（不含被掩码的部分）。
                    # 存在的理由：通用掩码会把 `C:\Users\<name>` 与 `C:\<目录>\...` 都压成
                    # `C:\***`，光看"形态"无法判断到底命中了什么；把规则字面量列出来，
                    # 日志就自证其明（且规则字面量本身不是隐私——它就是这脚本自己写的正则）。
                    Pattern  = $entry.Value
                })
        }
    }
    return $hits
}

function Get-InfoHits {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $InformationalPatterns.GetEnumerator()) {
        $m = [regex]::Match($Text, $entry.Value)
        if ($m.Success) {
            $hits.Add([pscustomobject]@{
                    Rule   = $entry.Key
                    Sample = Get-SafeMask $m.Value
                })
        }
    }
    return $hits
}

# ---------------------------------------------------------------------------
# 条目筛选：只扫"二进制里可能嵌构建路径"的高风险条目，避免把图片资源误判。
#   * Android：lib/<abi>/libapp.so —— Dart AOT 快照就住在这里，构建目录路径嵌在它的
#     dart_plugin_registrant 文件 URI 里。编译后的 classes*.dex 也会扫（成本低，
#     且能顺带发现被硬编码进 Java/Kotlin 侧的绝对路径）。
#   * Windows：data/app.so（同一份 AOT 快照）、data/flutter_assets/kernel_blob.bin
#     （仅 debug 构建存在，仍扫以防混入）、gal_plugin.dll / huse_vpn_ffi.dll（本仓库自己
#     参与构建的原生库，其内嵌路径同样来自构建目录）。
# 说明：libflutter.so / flutter_windows.dll 是官方预编译产物，其内嵌路径来自 Google/
# Flutter 的构建机（与"本机工作区"无关），按设计不纳入判定，避免噪声盖掉真命中。
#
# 条目名先做**规范化**（见 ConvertTo-NormalizedEntryName）再匹配，因为实测本仓库的
# Windows 发布 zip 存在两种打包形态（同一条目名在两种形态下写法不同）：
#   形态 A（v1.0.2/1.0.3 等）：`data/app.so`、`data/flutter_assets/...`   —— 正斜杠、无顶层目录
#   形态 B（v1.0.4 起）：`Jizhicha-v1.0.4-Windows/data/app.so`（有顶层目录）
#   形态 C（v1.0.8 / 1.0.9）：`data\app.so`、`data\flutter_assets\...`   —— **反斜杠**（Windows 打包）
# 早期实现只认 `^data/app\.so$`，导致形态 B/C 被误判成 Android APK 并"扫描条目数 0"，
# 等于**漏检**——本门最危险的失效模式就是"看起来通过，其实没扫"。
# ---------------------------------------------------------------------------
$AndroidEntryRegex = '(?i)^lib/[^/]+/libapp\.so$|^classes\d*\.dex$'
$WindowsEntryRegex = '(?i)(?:^|/)data/app\.so$|(?:^|/)data/flutter_assets/kernel_blob\.bin$|(?:^|/)(?:gal_plugin|huse_vpn_ffi)\.dll$'

function Add-ArtifactTarget {
    param([string]$LiteralPath)

    if (Test-Path -LiteralPath $LiteralPath -PathType Container) {
        foreach ($p in Get-ChildItem -LiteralPath $LiteralPath -Recurse -File -Include '*.apk', '*.zip') {
            $script:Roots.Add($p.FullName)
        }
        return
    }
    $script:Roots.Add((Resolve-Path -LiteralPath $LiteralPath).ProviderPath)
}

function Test-OneArtifact {
    param([Parameter(Mandatory)][string]$ArtifactPath)

    $name = Split-Path $ArtifactPath -Leaf
    $ext = [System.IO.Path]::GetExtension($ArtifactPath).ToLowerInvariant()

    if ($ext -ne '.apk' -and $ext -ne '.zip') {
        Write-Host ("[SKIP] {0}: 不支持的产物类型（只支持 .apk / .zip）" -f $name) -ForegroundColor Yellow
        $script:Unsupported.Add($ArtifactPath)
        return
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ArtifactPath)
    $scanned = 0
    $hitRecords = New-Object System.Collections.Generic.List[object]
    $infoRecords = New-Object System.Collections.Generic.List[object]
    $ruleCounts = @{}
    try {
        # 先按规范化条目名判类型。Windows 判据 = 存在发布目录布局（jizhicha.exe 或
        # flutter_assets），即便这份包恰好没带 data/app.so 也要按 Windows 规则扫，
        # 不能因为"没找到那个文件"就退化成 Android 规则 ⇒ 那样等于漏检。
        $isApk = $false
        $isWindowsBundle = $false
        foreach ($e in $zip.Entries) {
            $en = ConvertTo-NormalizedEntryName $e.FullName
            if (-not $isApk -and $en -match '(?i)^classes\d*\.dex$|^AndroidManifest\.xml$|^resources\.arsc$|^lib/[^/]+/libapp\.so$') { $isApk = $true }
            if (-not $isWindowsBundle -and $en -match '(?i)(?:^|/)jizhicha\.exe$|(?:^|/)data/flutter_assets/|(?:^|/)flutter_windows\.dll$') { $isWindowsBundle = $true }
        }
        # APK 标记优先（Windows 包与 APK 的条目集完全不重叠，正常不会同时命中）
        if ($isApk) { $isWindowsBundle = $false }
        $regex = if ($isWindowsBundle) { $WindowsEntryRegex } else { $AndroidEntryRegex }
        $kind = if ($isWindowsBundle) { 'Windows 发布包' } else { 'Android APK' }

        foreach ($e in $zip.Entries) {
            if ($e.FullName.EndsWith('/') -or $e.FullName.EndsWith('\')) { continue }
            # 用规范化名匹配；条目标签里保留**脱敏后的**原始写法，便于人工对照
            $entryName = ConvertTo-NormalizedEntryName $e.FullName
            if ($entryName -notmatch $regex) { continue }

            $stream = $e.Open()
            try {
                $ms = New-Object System.IO.MemoryStream
                $stream.CopyTo($ms)
                $text = ConvertTo-Latin1String $ms.ToArray()
            }
            finally {
                $stream.Dispose()
                if ($ms) { $ms.Dispose() }
            }
            $scanned++

            foreach ($h in (Test-Forbidden $text)) {
                if ($ruleCounts.ContainsKey($h.Rule)) { $ruleCounts[$h.Rule]++ } else { $ruleCounts[$h.Rule] = 1 }
                # 总数始终精确；明细只留前 $MaxHits 条（避免日志被同一个形态刷屏）
                if ($hitRecords.Count -lt $MaxHits) {
                    $hitRecords.Add([pscustomobject]@{
                            Entry   = Get-SafeMask $entryName
                            Rule    = $h.Rule
                            Offset  = $h.Offset
                            Sample  = $h.Sample
                            Pattern = $h.Pattern
                        })
                }
            }
            foreach ($h in (Get-InfoHits $text)) {
                $infoRecords.Add([pscustomobject]@{ Entry = Get-SafeMask $entryName; Rule = $h.Rule; Sample = $h.Sample })
            }
        }
    }
    finally { $zip.Dispose() }

    Write-Host ("[{0}] {1}  (类型: {2}, 扫描条目数: {3})" -f $(if ($hitRecords.Count -gt 0) { 'FAIL' } else { ' OK ' }), $name, $kind, $scanned)

    if ($hitRecords.Count -gt 0) {
        $script:Failures.AddRange($hitRecords)
        $total = ($ruleCounts.Values | Measure-Object -Sum).Sum
        $script:HitTotal += $total
        foreach ($k in $ruleCounts.Keys) {
            $script:ForbiddenRuleTotals[$k] = $script:ForbiddenRuleTotals[$k] + $ruleCounts[$k]
        }
        Write-Host ("       命中 {0} 处（原文已掩码）:" -f $total) -ForegroundColor Red
        $i = 0
        foreach ($h in $hitRecords) {
            $i++
            $line = "         {0}) 规则={1} 命中字面={2} 条目={3} 偏移={4} 掩码形态={5}" -f $i, $h.Rule, $h.Pattern, $h.Entry, $h.Offset, $h.Sample
            Write-Host $line -ForegroundColor Red
        }
        if ($total -gt $hitRecords.Count) {
            Write-Host ("       … 其余 {0} 条明细已省略（-MaxHits {1}）；按规则计数: {2}" -f ($total - $hitRecords.Count), $MaxHits, ((($ruleCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join ', '))) -ForegroundColor Red
        }
    }
    else {
        Write-Host "       未命中禁止形态"
    }

    # 信息项（不判失败）：帮助人工判断产物来自哪种构建目录
    if ($infoRecords.Count -gt 0) {
        foreach ($h in $infoRecords) {
            Write-Host ("       [info] 条目={0} 形态={1}" -f $h.Entry, $h.Sample) -ForegroundColor DarkGray
        }
    }
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
if ($NoColor) { $Host.UI.RawUI.ForegroundColor = 'Gray' }

$Roots = New-Object System.Collections.Generic.List[string]
$Failures = New-Object System.Collections.Generic.List[object]
$Unsupported = New-Object System.Collections.Generic.List[string]
$ForbiddenRuleTotals = New-Object System.Collections.Hashtable
$HitTotal = 0

foreach ($p in $Path) {
    try {
        Add-ArtifactTarget -LiteralPath $p
    }
    catch {
        Write-Host ("[ERROR] 路径不可用: {0}" -f $p) -ForegroundColor Red
        exit 2
    }
}

if ($Roots.Count -eq 0) {
    Write-Host '[ERROR] 没有找到任何 .apk / .zip 产物' -ForegroundColor Red
    exit 2
}

Write-Host '=== 发布前断言门：产物构建路径扫描 ==='
foreach ($r in $Roots) {
    try {
        Test-OneArtifact -ArtifactPath $r
    }
    catch {
        Write-Host ("[ERROR] {0}: {1}" -f (Split-Path $r -Leaf), (Get-SafeMask $_.Exception.Message)) -ForegroundColor Red
        $Unsupported.Add($r)
    }
}

Write-Host ''
if ($Failures.Count -gt 0) {
    $perRule = ($ForbiddenRuleTotals.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join ', '
    Write-Host ("FAIL: 共 {0} 处命中（按规则: {1}）" -f $HitTotal, $perRule) -ForegroundColor Red
    Write-Host '      说明：产物里嵌了构建机本地路径。修复方式只有一种——把仓库复制到中性目录（如 C:\build\jizhicha-<ver>-sanitize\jizhicha）后重新构建。' -ForegroundColor Red
    Write-Host ('      注：应用自有标识（{0}）已在白名单中豁免；上面列出了具体规则与条目，原文一律掩码。' -f ($AllowedSelfIdentifiers -join ' / ')) -ForegroundColor DarkGray
    exit 1
}
if ($Unsupported.Count -gt 0) {
    Write-Host ("FAIL: 有 {0} 个产物无法扫描（类型不支持或读取失败）" -f $Unsupported.Count) -ForegroundColor Red
    exit 1
}

Write-Host 'OK: 所有产物均未命中禁止形态' -ForegroundColor Green
exit 0
