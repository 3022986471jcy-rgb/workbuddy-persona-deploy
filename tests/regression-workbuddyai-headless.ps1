# ==============================================================
# 国际版 WorkBuddyAI 回归测试
# --------------------------------------------------------------
# 只断言"始终成立"的结构性不变量，因此无论是否已部署都能跑：
#   1. 国际版必须定位到 WorkBuddyAI.exe 所在目录，绝不能落到国内版 WorkBuddy
#   2. 必须至少发现一个可注入程序包（否则说明版本结构又变了）
#   3. 每个程序包都能算出 > 0 的预期注入点数（锚点被识别）
#   4. 注入点数不得超出预期，且只能是 0 或 完全注入（不存在半吊子状态）
#
# 用法： powershell -ExecutionPolicy Bypass -File tests\regression-workbuddyai-headless.ps1
# ==============================================================

$ErrorActionPreference = "Stop"

$deployScript = Join-Path (Split-Path -Parent $PSScriptRoot) "deploy.ps1"
$statusOutput = (& $deployScript status workbuddyai 6>&1 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"

$failed = @()

function Assert-Match {
    param([string]$Name, [string]$Pattern)
    if ($statusOutput -notmatch $Pattern) { $script:failed += $Name }
}

# 1. 目录定位
Assert-Match "国际版必须定位到 WorkBuddyAI 目录" '检测到的目录: .*WorkBuddyAI'
if ($statusOutput -match '检测到的目录: (?!.*WorkBuddyAI).*WorkBuddy') {
    $failed += "国际版误落到国内版 WorkBuddy 目录"
}

# 2/3/4. 程序包级别的不变量
$bundleLines = @([regex]::Matches($statusOutput, '(?m)^(?<file>.+?): 人格注入点 = (?<n>\d+).*预期为 (?<e>\d+)'))
if ($bundleLines.Count -eq 0) {
    $failed += "未解析到任何程序包状态行（可能一个程序包都没发现）"
} else {
    foreach ($m in $bundleLines) {
        $file = $m.Groups['file'].Value
        $n = [int]$m.Groups['n'].Value
        $e = [int]$m.Groups['e'].Value
        if ($e -le 0) { $failed += ("$file 预期注入点必须 > 0（锚点未识别）") }
        if ($n -gt $e) { $failed += ("$file 注入点 $n 超出预期 $e（疑似重复注入）") }
        if ($n -ne 0 -and $n -ne $e) { $failed += ("$file 处于半吊子状态：$n/$e") }
    }
}

Write-Host "--- 国际版状态 ---" -ForegroundColor Gray
$statusOutput -split "`n" | Where-Object { $_ -match '检测到的目录|人格注入点|身份模板为空' } |
    ForEach-Object { Write-Host ("  " + $_.Trim()) -ForegroundColor DarkGray }

if ($failed.Count -gt 0) {
    Write-Error ("WorkBuddyAI regression failed: " + ($failed -join "; ") + "`n" + $statusOutput)
}

$summary = ($bundleLines | ForEach-Object { $_.Groups['file'].Value + "=" + $_.Groups['n'].Value + "/" + $_.Groups['e'].Value }) -join ", "
Write-Host ("PASS: 国际版回归通过（" + $bundleLines.Count + " 个程序包：" + $summary + "）") -ForegroundColor Green
