#requires -Version 5.1
<#
.SYNOPSIS
  check_pii.ps1 的回归自测：临时 git 仓库 + 已知夹具，断言判定与输出格式都对。

.DESCRIPTION
  覆盖三条真出过问题的路径：
    1) 单行文件 —— Get-Content 返回**字符串标量**，$lines[$i] 变成字符，整份文件等于没扫
       （2026-11-13 定位并修；本文件就是它的回归用例）
    2) 已文档化的占位号段（2024000xxxxx / 生教2401班）不得误报
    3) 带 -NoValueInOutput 时，输出里只允许出现「路径:行号 [规则名]」，不得出现命中原文

  夹具里的敏感形态全部由片段拼出来，避免本文件自己被门禁拦下。

.EXAMPLE
  pwsh -NoProfile -File tool/test_check_pii.ps1
#>
[CmdletBinding()]
param(
    [string]$CheckPiiPath = (Join-Path $PSScriptRoot 'check_pii.ps1')
)

$ErrorActionPreference = 'Stop'

$badId     = '2024' + '0010' + '0001'
$badClass  = '生教' + '2502' + '班'
$okId      = '2024' + '0000' + '0001'
$okClass   = '生教' + '2401' + '班'

$failures = 0
function Assert-Case {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        Write-Host ('[ OK ] ' + $Name) -ForegroundColor Green
    } else {
        Write-Host ('[FAIL] ' + $Name + '   ' + $Detail) -ForegroundColor Red
        $script:failures++
    }
}

function New-TempRepo {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('check_pii_selftest_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    & git -C $dir init -q
    return $dir
}

function Invoke-Gate {
    param([string]$Repo, [switch]$Redact)
    $argv = @('-NoProfile', '-File', $CheckPiiPath, '-RepoRoot', $Repo)
    if ($Redact) { $argv += '-NoValueInOutput' }
    $out = & pwsh @argv 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

function Add-Fixture {
    param([string]$Repo, [string]$Name, [string]$Content)
    Set-Content -LiteralPath (Join-Path $Repo $Name) -Encoding utf8 -Value $Content
    & git -C $Repo add $Name
}

# --- 1) 单行文件里的越界学号：必须拦下，且脱敏输出不带原文 ---------------------
$repo = New-TempRepo
try {
    Add-Fixture -Repo $repo -Name 'one_line.dart' -Content ('// 学号 ' + $badId)
    $r = Invoke-Gate -Repo $repo -Redact
    Assert-Case 'single-line file is scanned' ($r.ExitCode -eq 1) ('exit=' + $r.ExitCode)
    Assert-Case 'redacted output hides the value' (-not $r.Output.Contains($badId))
    Assert-Case 'redacted output names rule and path' (($r.Output -match 'one_line\.dart:\d+: \[student-id\]'))
} finally { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }

# --- 2) 单行文件里的合法占位值：不得误报 -------------------------------------
$repo = New-TempRepo
try {
    Add-Fixture -Repo $repo -Name 'placeholder.dart' -Content ('// 学号 ' + $okId + ' 班级 ' + $okClass)
    $r = Invoke-Gate -Repo $repo -Redact
    Assert-Case 'documented placeholders pass' ($r.ExitCode -eq 0) ('exit=' + $r.ExitCode)
} finally { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }

# --- 3) 多行文件里的违规班级名：必须拦下 -------------------------------------
$repo = New-TempRepo
try {
    Add-Fixture -Repo $repo -Name 'multi.dart' -Content ('line one' + [Environment]::NewLine + '// 班级 ' + $badClass)
    $r = Invoke-Gate -Repo $repo -Redact
    Assert-Case 'multi-line file still scanned' ($r.ExitCode -eq 1) ('exit=' + $r.ExitCode)
    Assert-Case 'class-name rule reported' (($r.Output -match 'multi\.dart:2: \[class-name\]'))
} finally { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }

# --- 4) 非文本扩展名跳过 ------------------------------------------------------
$repo = New-TempRepo
try {
    Add-Fixture -Repo $repo -Name 'blob.bin' -Content ('// 学号 ' + $badId)
    $r = Invoke-Gate -Repo $repo -Redact
    Assert-Case 'non-text extension skipped' ($r.ExitCode -eq 0) ('exit=' + $r.ExitCode)
} finally { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }

if ($failures -gt 0) {
    Write-Host ''
    Write-Host ('[FAIL] {0} case(s) failed.' -f $failures) -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host '[ OK ] check_pii.ps1 self-test passed.' -ForegroundColor Green
exit 0
