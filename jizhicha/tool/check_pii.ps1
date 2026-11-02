#requires -Version 5.1
<#
.SYNOPSIS
  源码级隐私门禁：扫描**已跟踪文件**里不该出现的个人数据形态。

.DESCRIPTION
  与 check_release_artifacts.ps1 互补：那个查**构建产物**（APK / AOT 快照里的构建机路径），
  这个查**源码**（会被提交进仓库、并被公开网页渲染的文本）。

  为什么必须存在：2026-09 ~ 2026-11 连续三次把真实教师姓名 / 真实教室号 / 真实课表内容
  带进仓库和发布公告。根因不是"不小心"，而是**用记忆里的名单去查，而不是按字段形态查** ——
  名单天然只能发现你已经想到的那些值。本脚本只认**形态**，不认名字。

  规则分两类：
    * 硬门禁：命中即失败（学号 / 班级 / 会话虚拟 IP / 本机绝对路径 / 真实房号 / 真实教师名）
    * 说明：本脚本只扫文本，不扫二进制；APK 由 check_release_artifacts.ps1 负责。

.PARAMETER RepoRoot
  仓库根目录，默认取本脚本上一级。

.EXAMPLE
  pwsh -NoProfile -File tool/check_pii.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
)

$ErrorActionPreference = 'Stop'

# --- 允许存在的取值（已文档化的占位值；扩这个名单必须写清理由） -----------------
$AllowedStudentIds = @('202400000000', '202400000001', '202400000002', '202600000001')
# 仓库既有测试大量使用 2024000000xx 这一整段作为占位学号（与 CI 守卫的排除式一致）。
$AllowedStudentIdPattern = '^2024000\d{5}$'
$AllowedClassNames = @('生教2401班')
$AllowedTeacherNames = @('张三', '李四', '王五', '赵六', '钱七', '示例教师')

# 个别文件里有作者明确保留的历史测试夹具（2026-11-02 决策：不改）。
$RoomRuleSkipFiles = @('huse-vpn-next/core/src/nc.rs')
# 作者 2026-11-02 决策：这两个会话 IP 是协议单测夹具，保留不改（见 HANDOFF §9.23）。
$SessionIpSkipFiles = @('huse-vpn-next/core/src/nc.rs')

$Rules = @(
    @{ Name = 'student-id';   Pattern = '\b20\d{10}\b' }
    @{ Name = 'class-name';   Pattern = '生教\d{4}班' }
    @{ Name = 'session-ip';   Pattern = '\b172\.16\.\d{1,3}\.\d{1,3}\b' }
    @{ Name = 'local-path';   Pattern = '[A-Za-z]:[\/]Users[\/]|D:[\/]AAAAA|/home/[a-z]' }
    @{ Name = 'room-number';  Pattern = '[一-龥]{2,5}楼[A-Z]?[0-9]{3}' }
)

$TextExtensions = @('.dart', '.kt', '.java', '.rs', '.md', '.ps1', '.sh', '.yml', '.yaml',
                    '.json', '.xml', '.gradle', '.kts', '.toml', '.txt', '.properties', '.html')

Push-Location $RepoRoot
try {
    $files = & git ls-files 2>$null
} finally {
    Pop-Location
}
if (-not $files) {
    Write-Host '[ERROR] git ls-files 没有返回任何文件，无法扫描。' -ForegroundColor Red
    exit 1
}

$violations = New-Object System.Collections.Generic.List[string]

foreach ($rel in $files) {
    # 门禁脚本自身必然包含这些形态（它就是规则的载体），扫自己没有意义。
    if ($rel -eq 'tool/check_pii.ps1') { continue }
    $ext = [System.IO.Path]::GetExtension($rel).ToLowerInvariant()
    if ($TextExtensions -notcontains $ext) { continue }
    $abs = Join-Path $RepoRoot $rel
    if (-not (Test-Path -LiteralPath $abs)) { continue }

    $lines = Get-Content -LiteralPath $abs -Encoding utf8
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $lineNo = $i + 1

        foreach ($rule in $Rules) {
            foreach ($m in [regex]::Matches($line, $rule['Pattern'])) {
                $hit = $m.Value

                # 逐条判定是否属于"已文档化的允许值"
                $ok = $false
                switch ($rule['Name']) {
                    'student-id' {
                        if ($AllowedStudentIds -contains $hit) { $ok = $true }
                        elseif ($hit -match $AllowedStudentIdPattern) { $ok = $true }
                    }
                    'class-name' { if ($AllowedClassNames -contains $hit) { $ok = $true } }
                    'session-ip' { if ($SessionIpSkipFiles -contains $rel) { $ok = $true } }
                    'room-number' {
                        if ($RoomRuleSkipFiles -contains $rel) { $ok = $true }
                        # 只允许 9xx 号（明确合成，真实教室不会用 9 开头三位数）
                        elseif ($hit -match '楼9\d{2}$') { $ok = $true }
                    }
                }
                if (-not $ok) {
                    $violations.Add(('{0}:{1}: [{2}] {3}' -f $rel, $lineNo, $rule['Name'], $hit))
                }
            }
        }

        # 强智课表 HTML 夹具里的教师字段只允许合成姓名
        foreach ($m in [regex]::Matches($line, "title='教师'>([^<]+)")) {
            $names = $m.Groups[1].Value -split ','
            foreach ($n in $names) {
                $n = $n.Trim()
                if ($n -and ($AllowedTeacherNames -notcontains $n)) {
                    $violations.Add(('{0}:{1}: [teacher-name] {2}' -f $rel, $lineNo, $n))
                }
            }
        }
    }
}

Write-Host ''
Write-Host '=== 源码隐私门禁（按字段形态扫描已跟踪文件） ===' -ForegroundColor Cyan
if ($violations.Count -eq 0) {
    Write-Host ('[ OK ] 扫描 {0} 个文本文件，未发现个人数据形态。' -f $files.Count) -ForegroundColor Green
    exit 0
}

Write-Host ('[FAIL] 发现 {0} 处可疑取值（只列路径与形态，不打印上下文）：' -f $violations.Count) -ForegroundColor Red
foreach ($v in $violations) { Write-Host ('  ' + $v) -ForegroundColor Red }
Write-Host ''
Write-Host '处理方式：换成合成占位（学号 202400000000 / 班级 生教2401班 / 房号 楼9xx / 教师 张三,李四），' -ForegroundColor Yellow
Write-Host '若确有必须保留的例外，在 tool/check_pii.ps1 的允许名单里写明理由后再加。' -ForegroundColor Yellow
exit 1
