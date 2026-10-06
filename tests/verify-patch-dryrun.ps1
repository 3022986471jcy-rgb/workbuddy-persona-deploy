# ==============================================================
# WorkBuddy 部署脚本 —— 干跑验证（不触碰真实安装目录）
# --------------------------------------------------------------
# 覆盖三件事：
#   A. 路径探测：国内版必须落在 WorkBuddy.exe 的目录，国际版必须落在
#      WorkBuddyAI.exe 的目录，且两者不同（回归 "WorkBuddy AI" 误命中）
#   B. 注入正确性：对真实 bundle 的临时副本打补丁，校验
#        注入点总数 == 预期、锚点被完全消费、原 return 语句逐字未变、
#        语法自检通过
#   C. 运行时有效性：用 node 真正执行注入后的 create()，确认 system 消息
#      被人格文件内容替换（CJS 与 ESM 两种上下文各跑一遍）
#
# 用法： powershell -ExecutionPolicy Bypass -File tests\verify-patch-dryrun.ps1
# ==============================================================

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot "deploy-lib.ps1")

$script:Failures = @()
$script:PassCount = 0

function Assert-True {
    param(
        [bool]$Condition,
        [Parameter(Mandatory)][string]$Name,
        [string]$Detail = ""
    )
    if ($Condition) {
        Write-Host ("  [PASS] " + $Name) -ForegroundColor Green
        $script:PassCount++
    } else {
        Write-Host ("  [FAIL] " + $Name + $(if ($Detail) { " :: " + $Detail } else { "" })) -ForegroundColor Red
        $script:Failures += $Name
    }
}

function Get-RelativeTo {
    param([string]$Base, [string]$Path)
    if ($Path.StartsWith($Base, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($Base.Length).TrimStart('\', '/')
    }
    return $Path
}

# ---------------------------------------------------------------
# A. 路径探测
# ---------------------------------------------------------------
Write-Host ""
Write-Host "=== A. 安装路径探测 ===" -ForegroundColor Cyan

$resolved = @{}
foreach ($target in @("workbuddy", "workbuddyai")) {
    $resolved[$target] = Resolve-WBRoot -Target $target
    Write-Host ("  " + $target + " -> " + $(if ($resolved[$target]) { $resolved[$target] } else { "(未找到)" })) -ForegroundColor Gray
}

Assert-True ([bool]$resolved["workbuddy"]) "国内版找到安装目录"
Assert-True ([bool]$resolved["workbuddyai"]) "国际版找到安装目录"

if ($resolved["workbuddy"]) {
    Assert-True (Test-Path -LiteralPath (Join-Path $resolved["workbuddy"] "WorkBuddy.exe")) "国内版目录下存在 WorkBuddy.exe" $resolved["workbuddy"]
}
if ($resolved["workbuddyai"]) {
    Assert-True (Test-Path -LiteralPath (Join-Path $resolved["workbuddyai"] "WorkBuddyAI.exe")) "国际版目录下存在 WorkBuddyAI.exe" $resolved["workbuddyai"]
}
if ($resolved["workbuddy"] -and $resolved["workbuddyai"]) {
    Assert-True ($resolved["workbuddy"] -ne $resolved["workbuddyai"]) "两版目录互不串位"
}

$cnRoots = Get-WBCandidateRoots -Target "workbuddy"
$intlRoots = Get-WBCandidateRoots -Target "workbuddyai"
Assert-True (-not ($cnRoots -contains $resolved["workbuddyai"])) "国内版候选集中不含国际版目录"
Assert-True (-not ($intlRoots -contains $resolved["workbuddy"])) "国际版候选集中不含国内版目录"

# ---------------------------------------------------------------
# B. 注入正确性（在临时副本上打补丁）
# ---------------------------------------------------------------
Write-Host ""
Write-Host "=== B. 注入正确性（临时副本）===" -ForegroundColor Cyan

$DryRunRoot = Join-Path $PSScriptRoot "_dryrun"
if (Test-Path $DryRunRoot) { Remove-Item $DryRunRoot -Recurse -Force }
New-Item -ItemType Directory -Path $DryRunRoot | Out-Null

$PersonaDir = Join-Path $RepoRoot "人格"
$personaFiles = @(Get-ChildItem -LiteralPath $PersonaDir -Filter "*.txt" -File -ErrorAction SilentlyContinue | Sort-Object Name)
Assert-True ($personaFiles.Count -ge 1) "人格目录中至少存在一个 .txt 人格" $PersonaDir

# 第二个路径用合成值：既能验证"换人格只迁移路径"，又不依赖本机人格库内容
$PersonaA = if ($personaFiles.Count -ge 1) { $personaFiles[0].FullName } else { "" }
$PersonaB = Join-Path $DryRunRoot "_alt_persona_not_exist.txt"

$PromptJsA = ConvertTo-WBJsStringBody -Path $PersonaA
$PromptJsB = ConvertTo-WBJsStringBody -Path $PersonaB
$NodeRuntime = Resolve-WBNodeRuntime -FallbackExe $null
Assert-True ([bool]$NodeRuntime) "找到可用于语法自检的 node 运行时"

$chatRx = Get-WBChatAnchorRegex
$responsesRx = Get-WBResponsesAnchorRegex
$marker = Get-WBInjectionMarker

foreach ($target in @("workbuddy", "workbuddyai")) {
    $wbRoot = $resolved[$target]
    if (-not $wbRoot) { continue }
    $bundles = Get-WBBundles -WBRoot $wbRoot
    Write-Host ("  -- " + $target + " : " + $bundles.Count + " 个程序包") -ForegroundColor Gray

    Assert-True ($bundles.Count -gt 0) ($target + " 至少发现一个可注入程序包")

    foreach ($bundle in $bundles) {
        $destDir = Join-Path $DryRunRoot $target
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        $flatName = $bundle.RelName.Replace('\', '_').Replace('/', '_')
        $dest = Join-Path $destDir $flatName

        $original = [System.IO.File]::ReadAllText($bundle.Path)
        $chatMatches = @($chatRx.Matches($original))
        $respMatches = @($responsesRx.Matches($original))
        $patch = Get-WBBundlePatchedContent -Content $original -PromptJs $PromptJsA -InjectAnchors

        $label = $target + "/" + $bundle.RelName

        Assert-True ($patch.Expected -gt 0) ($label + " 预期注入点数 > 0") ("expected=" + $patch.Expected)
        Assert-True ($patch.InjectedAfter -eq $patch.Expected) ($label + " 注入点数等于预期") ("after=" + $patch.InjectedAfter + " expected=" + $patch.Expected)

        # 锚点必须被完全消费
        $leftChat = $chatRx.Matches($patch.Content).Count
        $leftResp = $responsesRx.Matches($patch.Content).Count
        Assert-True (($leftChat + $leftResp) -eq 0) ($label + " 锚点被完全消费") ("剩余 chat=" + $leftChat + " resp=" + $leftResp)

        # 原 return 语句必须逐字保留（证明只做了插入，没破坏原调用）
        $tailOk = $true
        foreach ($m in ($chatMatches + $respMatches)) {
            $idx = $m.Value.IndexOf("return ")
            $tail = $m.Value.Substring($idx)
            if (-not $patch.Content.Contains($tail)) { $tailOk = $false; break }
        }
        Assert-True $tailOk ($label + " 原 return 语句逐字未变")

        # 人格路径写入次数 == 注入点数
        $pathHits = ([regex]::Matches($patch.Content, [regex]::Escape('readFileSync("' + $PromptJsA + '"'))).Count
        Assert-True ($pathHits -eq $patch.Expected) ($label + " 人格路径写入次数正确") ("hits=" + $pathHits + " expected=" + $patch.Expected)

        # 语法自检
        [System.IO.File]::WriteAllText($dest, $patch.Content, [System.Text.UTF8Encoding]::new($false))
        $syntaxOk = Test-WBJavaScriptSyntax -Path $dest -NodeExe $NodeRuntime.Exe -UseElectronRunAsNode:$NodeRuntime.UseElectronRunAsNode
        Assert-True $syntaxOk ($label + " 语法自检通过") $script:WBLastSyntaxDiagnostic

        # 换人格重跑：只迁移路径，不新增注入点、不重复消费锚点
        $patch2 = Get-WBBundlePatchedContent -Content $patch.Content -PromptJs $PromptJsB -InjectAnchors
        Assert-True ($patch2.Injected -eq $patch.Expected) ($label + " 重跑时识别到既有注入点") ("injected=" + $patch2.Injected)
        Assert-True (($patch2.ChatAnchors + $patch2.RespAnchors) -eq 0) ($label + " 重跑时无冗余锚点可消费")
        Assert-True ($patch2.InjectedAfter -eq $patch.Expected) ($label + " 重跑后注入点总数不变") ("after=" + $patch2.InjectedAfter)
        $pathHitsB = ([regex]::Matches($patch2.Content, [regex]::Escape('readFileSync("' + $PromptJsB + '"'))).Count
        Assert-True ($pathHitsB -eq $patch.Expected) ($label + " 换人格后路径已整体迁移") ("hits=" + $pathHitsB)
        Assert-True (([regex]::Matches($patch2.Content, [regex]::Escape('readFileSync("' + $PromptJsA + '"'))).Count -eq 0) ($label + " 旧人格路径已无残留")
    }
}

# ---------------------------------------------------------------
# C. 运行时有效性（真跑一遍注入后的 create）
# ---------------------------------------------------------------
Write-Host ""
Write-Host "=== C. 运行时有效性 ===" -ForegroundColor Cyan

$harnessDir = Join-Path $DryRunRoot "_harness"
New-Item -ItemType Directory -Path $harnessDir -Force | Out-Null

$chatInjection = New-WBChatInjection -BodyVar "A" -PromptJs $PromptJsA
$responsesInjection = New-WBResponsesInjection -BodyVar "A" -PromptJs $PromptJsA

$harnessBody = @"
const expected = require("fs").readFileSync("__PERSONA__", "utf8").trim();

function create(A, B) {
$chatInjection
  return { messages: A.messages };
}

function createResponses(A, B) {
$responsesInjection
  return A;
}

module.exports = { create, createResponses, expected };
"@
$harnessBody = $harnessBody.Replace("__PERSONA__", $PromptJsA)

$cjsPath = Join-Path $harnessDir "harness.cjs"
[System.IO.File]::WriteAllText($cjsPath, $harnessBody, [System.Text.UTF8Encoding]::new($false))

# ESM 版本：不能出现 require，用来验证 process.getBuiltinModule 分支
$esmBody = $harnessBody.Replace('const expected = require("fs")', 'const expected = process.getBuiltinModule("fs")')
$esmBody = $esmBody.Replace("module.exports = { create, createResponses, expected };", "export { create, createResponses, expected };")
$esmPath = Join-Path $harnessDir "harness.mjs"
[System.IO.File]::WriteAllText($esmPath, $esmBody, [System.Text.UTF8Encoding]::new($false))

$driverCjs = Join-Path $harnessDir "driver.cjs"
[System.IO.File]::WriteAllText($driverCjs, @'
const h = require("./harness.cjs");
function run(name, fn) {
  const r = fn();
  const ok = r.system === h.expected && r.injected === true;
  console.log((ok ? "OK " : "BAD ") + name + " injected=" + r.injected + " len=" + (r.system || "").length);
  process.exitCode = ok ? 0 : 1;
}
run("chat-existing-system", () => {
  const body = { messages: [{ role: "system", content: "OLD PRODUCT PROMPT" }, { role: "user", content: "hi" }] };
  h.create(body, {});
  return { system: body.messages[0].content, injected: body.messages.length === 2 && body.messages[0].role === "system" };
});
run("chat-insert-system", () => {
  const body = { messages: [{ role: "user", content: "hi" }] };
  h.create(body, {});
  return { system: body.messages[0].content, injected: body.messages.length === 2 && body.messages[0].role === "system" };
});
run("responses-instructions", () => {
  const body = { instructions: "OLD", input: [] };
  h.createResponses(body, {});
  return { system: body.instructions, injected: true };
});
run("responses-input-array", () => {
  const body = { input: [{ role: "user", content: "hi" }] };
  h.createResponses(body, {});
  const first = body.input[0];
  return { system: first.content[0].text, injected: first.role === "system" };
});
'@, [System.Text.UTF8Encoding]::new($false))

$driverEsm = Join-Path $harnessDir "driver.mjs"
[System.IO.File]::WriteAllText($driverEsm, @'
import { create, createResponses, expected } from "./harness.mjs";
function run(name, fn) {
  const r = fn();
  const ok = r.system === expected && r.injected === true;
  console.log((ok ? "OK " : "BAD ") + name + " injected=" + r.injected + " len=" + (r.system || "").length);
  if (!ok) process.exitCode = 1;
}
run("chat-existing-system", () => {
  const body = { messages: [{ role: "system", content: "OLD" }, { role: "user", content: "hi" }] };
  create(body, {});
  return { system: body.messages[0].content, injected: body.messages.length === 2 };
});
run("responses-input-array", () => {
  const body = { input: [{ role: "user", content: "hi" }] };
  createResponses(body, {});
  const first = body.input[0];
  return { system: first.content[0].text, injected: first.role === "system" };
});
'@, [System.Text.UTF8Encoding]::new($false))

foreach ($pair in @(
        @{ Driver = $driverCjs; Label = "CJS (require 分支)" },
        @{ Driver = $driverEsm; Label = "ESM (process.getBuiltinModule 分支)" })) {
    $out = & $NodeRuntime.Exe $pair.Driver 2>&1
    $exit = $LASTEXITCODE
    Write-Host ("  --- " + $pair.Label) -ForegroundColor Gray
    $out | ForEach-Object { Write-Host ("      " + $_) -ForegroundColor DarkGray }
    Assert-True ($exit -eq 0) ($pair.Label + " 注入逻辑真实执行通过") (($out | Out-String).Trim())
}

# ---------------------------------------------------------------
# D. 失败回滚安全网：语法自检必须能识别损坏文件，回滚后必须逐字节还原
# ---------------------------------------------------------------
Write-Host ""
Write-Host "=== D. 失败回滚安全网 ===" -ForegroundColor Cyan

$safeDir = Join-Path $DryRunRoot "_safety"
New-Item -ItemType Directory -Path $safeDir -Force | Out-Null

$sourceBundle = $null
foreach ($target in @("workbuddy", "workbuddyai")) {
    if (-not $resolved[$target]) { continue }
    $candidate = @(Get-WBBundles -WBRoot $resolved[$target]) | Select-Object -First 1
    if ($candidate) { $sourceBundle = $candidate; break }
}
Assert-True ([bool]$sourceBundle) "取得用于安全网测试的程序包"

if ($sourceBundle) {
    $work = Join-Path $safeDir $sourceBundle.Name
    Copy-Item -LiteralPath $sourceBundle.Path -Destination $work -Force
    $beforeHash = (Get-FileHash -LiteralPath $work -Algorithm SHA256).Hash

    # 备份 + 写入损坏内容，模拟"写完自检失败"
    $bak = "$work.bak"
    Copy-Item -LiteralPath $work -Destination $bak -Force
    $broken = [System.IO.File]::ReadAllText($work) + "`nfunction broken( {"
    [System.IO.File]::WriteAllText($work, $broken, [System.Text.UTF8Encoding]::new($false))

    $detected = -not (Test-WBJavaScriptSyntax -Path $work -NodeExe $NodeRuntime.Exe -UseElectronRunAsNode:$NodeRuntime.UseElectronRunAsNode)
    Assert-True $detected "语法自检能识别损坏文件（从而触发回滚）" $script:WBLastSyntaxDiagnostic
    Assert-True ([bool]$script:WBLastSyntaxDiagnostic) "自检失败时给出非空诊断信息"

    # 回滚动作 = 用 .bak 覆盖回去
    Copy-Item -LiteralPath $bak -Destination $work -Force
    $afterHash = (Get-FileHash -LiteralPath $work -Algorithm SHA256).Hash
    Assert-True ($beforeHash -eq $afterHash) "回滚后文件逐字节还原 (SHA256 一致)"
    Assert-True (Test-WBJavaScriptSyntax -Path $work -NodeExe $NodeRuntime.Exe -UseElectronRunAsNode:$NodeRuntime.UseElectronRunAsNode) "回滚后语法自检恢复通过"
}

# ---------------------------------------------------------------
# E. 依赖可达性：接收方机器上没有 Node 时，必须能用目标客户端自带运行时做自检
# ---------------------------------------------------------------
Write-Host ""
Write-Host "=== E. 无 Node 时的自带运行时兜底 ===" -ForegroundColor Cyan

$fallbackExe = $null
foreach ($target in @("workbuddy", "workbuddyai")) {
    if (-not $resolved[$target]) { continue }
    $candidate = Join-Path $resolved[$target] ((Get-WBProductName -Target $target) + ".exe")
    if (Test-Path -LiteralPath $candidate) { $fallbackExe = $candidate; break }
}
Assert-True ([bool]$fallbackExe) "取得目标客户端自带运行时" $fallbackExe

if ($fallbackExe) {
    $okProbe = Join-Path $safeDir "fallback_ok.mjs"
    $badProbe = Join-Path $safeDir "fallback_bad.js"
    [System.IO.File]::WriteAllText($okProbe, "export const x = 1;`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($badProbe, "function broken( {`n", [System.Text.UTF8Encoding]::new($false))

    $okResult = Test-WBJavaScriptSyntax -Path $okProbe -NodeExe $fallbackExe -UseElectronRunAsNode
    $badResult = Test-WBJavaScriptSyntax -Path $badProbe -NodeExe $fallbackExe -UseElectronRunAsNode
    Assert-True $okResult "兜底运行时：合法文件判定通过"
    Assert-True (-not $badResult) "兜底运行时：损坏文件被识别为失败"
    Assert-True ([bool]$script:WBLastSyntaxDiagnostic) "兜底运行时：给出非空诊断信息" $script:WBLastSyntaxDiagnostic
}

# ---------------------------------------------------------------
# F. Qoder：profile 解析 / AGENTS.override.md 优先级 / 注入与恢复闭环
#    （全部在临时 profile 上做，不碰真实 ~/.qoder）
# ---------------------------------------------------------------
Write-Host ""
Write-Host "=== F. Qoder AGENTS.md 目标解析与闭环 ===" -ForegroundColor Cyan

$qoderHome = Join-Path $DryRunRoot "_qoder_home"
New-Item -ItemType Directory -Path (Join-Path $qoderHome ".qoder") -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $qoderHome ".qoder\settings.json"), "{}", [System.Text.UTF8Encoding]::new($false))

$qTargets = @(Get-QoderTargets -HomeDir $qoderHome)
Assert-True ($qTargets.Count -eq 1) "只把真被使用过的 profile 当目标" ("count=" + $qTargets.Count)
Assert-True ($qTargets[0].Path -ieq (Join-Path $qoderHome ".qoder\AGENTS.md")) "默认注入目标是 AGENTS.md"
Assert-True (-not $qTargets[0].UsingOverride) "无 override 文件时不切目标"

# AGENTS.override.md 优先级高于 AGENTS.md —— 不改投它，注入就会被顶掉
$overridePath = Join-Path $qoderHome ".qoder\AGENTS.override.md"
[System.IO.File]::WriteAllText($overridePath, "user override", [System.Text.UTF8Encoding]::new($false))
$qTargetsOverride = @(Get-QoderTargets -HomeDir $qoderHome)
Assert-True ($qTargetsOverride[0].UsingOverride -and ($qTargetsOverride[0].Path -ieq $overridePath)) "存在 AGENTS.override.md 时改投它"
Remove-Item -LiteralPath $overridePath -Force

# 空目录不得被误判；国内构建 profile 要能独立识别
$emptyHome = Join-Path $DryRunRoot "_qoder_empty"
New-Item -ItemType Directory -Path (Join-Path $emptyHome ".qoder") -Force | Out-Null
Assert-True (@(Get-QoderTargets -HomeDir $emptyHome).Count -eq 0) "未留下 profile 痕迹的目录不被误判"
New-Item -ItemType Directory -Path (Join-Path $emptyHome ".qoder-cn") -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $emptyHome ".qoder-cn\.auth"), "x", [System.Text.UTF8Encoding]::new($false))
$cnTargets = @(Get-QoderTargets -HomeDir $emptyHome)
Assert-True ($cnTargets.Count -eq 1 -and $cnTargets[0].Name -eq ".qoder-cn") "国内构建 profile（.qoder-cn）可独立识别"

$qTarget = $qTargets[0]
$personaContent = [System.IO.File]::ReadAllText($PersonaA)
[System.IO.File]::WriteAllText($qTarget.Path, $personaContent, [System.Text.UTF8Encoding]::new($false))
$matchedPersona = Test-WBFileMatchesPersona -Path $qTarget.Path -PersonaFiles $personaFiles
Assert-True ([bool]$matchedPersona) "注入后内容能被识别为本工具部署的人格"
Assert-True ($matchedPersona.FullName -ieq $PersonaA) "识别到的正是所选人格文件"

Assert-True (-not (Test-Path -LiteralPath $qTarget.Backup)) "原文件不存在时不会凭空产生备份"
Remove-Item -LiteralPath $qTarget.Path -Force
Assert-True (-not (Test-Path -LiteralPath $qTarget.Path)) "无备份且内容确认属于本工具时可安全删除（恢复路径）"

$originalAgents = "# 用户自己的 AGENTS.md`r`n保留我原来的内容`r`n"
[System.IO.File]::WriteAllText($qTarget.Path, $originalAgents, [System.Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath $qTarget.Path -Destination $qTarget.Backup -Force
[System.IO.File]::WriteAllText($qTarget.Path, $personaContent, [System.Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath $qTarget.Backup -Destination $qTarget.Path -Force
Assert-True (([System.IO.File]::ReadAllText($qTarget.Path)) -ceq $originalAgents) "有备份时恢复逐字节还原原文"

$foreignContent = "# 用户自己写的 rules`r`n不要动我`r`n"
[System.IO.File]::WriteAllText($qTarget.Path, $foreignContent, [System.Text.UTF8Encoding]::new($false))
Remove-Item -LiteralPath $qTarget.Backup -Force
Assert-True ($null -eq (Test-WBFileMatchesPersona -Path $qTarget.Path -PersonaFiles $personaFiles)) "非本工具写入的内容不会被误判为可删"

$realQoderTargets = @(Get-QoderTargets)
if ($realQoderTargets.Count -gt 0) {
    Write-Host ("  本机 profile: " + (($realQoderTargets | ForEach-Object { $_.Name + " -> " + $_.Path }) -join "; ")) -ForegroundColor DarkGray
    Assert-True ($realQoderTargets[0].Dir.StartsWith($env:USERPROFILE, [System.StringComparison]::OrdinalIgnoreCase)) "本机目标位于用户 profile 目录下"
} else {
    Write-Host "  本机未安装 Qoder，跳过真机断言" -ForegroundColor DarkGray
}

# 双安装（国际 Qoder.exe / 国内 Qoder CN.exe）必须分别识别，并映射到各自 profile
$allQoderInstalls = @(Get-QoderInstallRoots)
foreach ($qoderInstall in $allQoderInstalls) {
    $channel = Get-QoderChannelOfInstall -Root $qoderInstall
    Assert-True ($channel -in @(".qoder", ".qoder-cn")) ("安装渠道可判定: " + $qoderInstall) $channel
    Assert-True ([bool](Get-QoderInstallExe -Root $qoderInstall)) ("能定位主程序: " + $qoderInstall)
    Write-Host ("  " + $channel + "  <-  " + $qoderInstall) -ForegroundColor DarkGray
}
if (@($realQoderTargets | Where-Object { $_.Name -eq ".qoder-cn" }).Count -gt 0) {
    Assert-True (@($allQoderInstalls | Where-Object { (Get-QoderChannelOfInstall -Root $_) -eq ".qoder-cn" }).Count -gt 0) "存在 .qoder-cn profile 时能探测到国内版安装"
}
$cnInstallRoot = $allQoderInstalls | Where-Object { (Get-QoderChannelOfInstall -Root $_) -eq ".qoder-cn" } | Select-Object -First 1
if ($cnInstallRoot) {
    Assert-True (([System.IO.Path]::GetFileName((Get-QoderInstallExe -Root $cnInstallRoot))) -ieq "Qoder CN.exe") "国内版主程序名是 Qoder CN.exe"
    $cnTarget = $realQoderTargets | Where-Object { $_.Name -eq ".qoder-cn" } | Select-Object -First 1
    Assert-True ($cnTarget -and ($cnTarget.InstallRoot -ieq $cnInstallRoot)) ".qoder-cn 正确映射到国内版安装"
}

# 目标 -> 渠道 映射，以及按渠道过滤后只返回该渠道的 profile
# （与 workbuddy / workbuddyai 同级的隔离要求：一个目标绝不越界动另一套）
Assert-True ((Get-QoderChannelOfTarget -Target "qoder") -eq ".qoder") "目标 qoder 映射到 ~/.qoder"
Assert-True ((Get-QoderChannelOfTarget -Target "qodercn") -eq ".qoder-cn") "目标 qodercn 映射到 ~/.qoder-cn"
Assert-True ((Get-QoderProductLabel -Target "qoder") -match '国际版') "目标 qoder 标签含「国际版」"
Assert-True ((Get-QoderProductLabel -Target "qodercn") -match '国内版') "目标 qodercn 标签含「国内版」"

# 让 $qoderHome 同时具备两套 profile，再验证渠道过滤
New-Item -ItemType Directory -Path (Join-Path $qoderHome ".qoder-cn") -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $qoderHome ".qoder-cn\.auth"), "x", [System.Text.UTF8Encoding]::new($false))
$intlOnly = @(Get-QoderTargets -HomeDir $qoderHome -Channel ".qoder")
$cnOnly = @(Get-QoderTargets -HomeDir $qoderHome -Channel ".qoder-cn")
Assert-True ($intlOnly.Count -eq 1 -and $intlOnly[0].Name -eq ".qoder") "-Channel .qoder 只返回国际版 profile" ("count=" + $intlOnly.Count)
Assert-True ($cnOnly.Count -eq 1 -and $cnOnly[0].Name -eq ".qoder-cn") "-Channel .qoder-cn 只返回国内版 profile" ("count=" + $cnOnly.Count)
Assert-True (@(Get-QoderTargets -HomeDir $qoderHome -Channel ".qoder-none").Count -eq 0) "不存在的渠道返回空集"
Assert-True (@(Get-QoderTargets -HomeDir $qoderHome).Count -eq 2) "不传 Channel 时返回全部在用 profile"

# ---------------------------------------------------------------
# G. Qoder 全链路 + 双目标严格隔离
#    手法：假 home 里同时准备 .qoder 与 .qoder-cn，把 USERPROFILE 指过去，
#    真实走 deploy.ps1 的 install / status / restore —— 覆盖真实分支代码，
#    又绝不触碰真机 profile。
# ---------------------------------------------------------------
Write-Host ""
Write-Host "=== G. Qoder 全链路与双目标隔离 ===" -ForegroundColor Cyan

$deployScript = Join-Path $RepoRoot "deploy.ps1"
$probePersona = $personaFiles[0].Name

function Invoke-DeployProbe {
    param([string]$Action, [string]$Target)
    return (& $deployScript $Action $Target $probePersona 6>&1 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
}

$fakeHome = Join-Path $DryRunRoot "_fake_home"
$intlDir = Join-Path $fakeHome ".qoder"
$cnDir = Join-Path $fakeHome ".qoder-cn"
New-Item -ItemType Directory -Path $intlDir -Force | Out-Null
New-Item -ItemType Directory -Path $cnDir -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $intlDir ".auth"), "x", [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText((Join-Path $cnDir ".auth"), "x", [System.Text.UTF8Encoding]::new($false))

$originalIntl = "# 国际版原有的 AGENTS.md`r`n原有内容`r`n"
$intlAgents = Join-Path $intlDir "AGENTS.md"
$cnAgents = Join-Path $cnDir "AGENTS.md"
[System.IO.File]::WriteAllText($intlAgents, $originalIntl, [System.Text.UTF8Encoding]::new($false))
# 国内版刻意不预置 AGENTS.md，用来覆盖「原文件不存在 -> 恢复时删除」这条路径
$personaContent = [System.IO.File]::ReadAllText($personaFiles[0].FullName)

$realIntl = Join-Path $env:USERPROFILE ".qoder\AGENTS.md"
$realCn = Join-Path $env:USERPROFILE ".qoder-cn\AGENTS.md"
$realIntlBefore = Test-Path -LiteralPath $realIntl
$realCnBefore = Test-Path -LiteralPath $realCn

$savedHome = $env:USERPROFILE
$env:USERPROFILE = $fakeHome
try {
    $intlInstall = Invoke-DeployProbe -Action "install" -Target "qoder"
    $intlAfterInstall = [System.IO.File]::ReadAllText($intlAgents)
    $intlBackup = [System.IO.File]::ReadAllText($intlAgents + '.qoderbak')
    $cnUntouchedAfterIntlInstall = -not (Test-Path -LiteralPath $cnAgents)
    $intlStatus = Invoke-DeployProbe -Action "status" -Target "qoder"
    $intlRestore = Invoke-DeployProbe -Action "restore" -Target "qoder"

    $cnInstall = Invoke-DeployProbe -Action "install" -Target "qodercn"
    $cnAfterInstall = [System.IO.File]::ReadAllText($cnAgents)
    $intlUntouchedAfterCnInstall = ([System.IO.File]::ReadAllText($intlAgents)) -ceq $originalIntl
    $cnStatus = Invoke-DeployProbe -Action "status" -Target "qodercn"
    $cnRestore = Invoke-DeployProbe -Action "restore" -Target "qodercn"
} finally {
    $env:USERPROFILE = $savedHome
}

# 目标 qoder（国际版）
Assert-True ($intlInstall -match 'Qoder（国际版）') "install qoder：标题显示国际版"
Assert-True ($intlInstall -match '命中 1 个配置') "install qoder：命中 1 个配置（计数不空）" $intlInstall
Assert-True ($intlAfterInstall -ceq $personaContent) "install qoder：AGENTS.md == 所选人格"
Assert-True ($intlBackup -ceq $originalIntl) "install qoder：备份 == 原文"
Assert-True ($intlStatus -match '已部署') "status qoder：报告已部署" $intlStatus
Assert-True (([System.IO.File]::ReadAllText($intlAgents)) -ceq $originalIntl) "restore qoder：逐字节还原原文"
Assert-True ($intlRestore -match '已从备份恢复') "restore qoder：报告从备份恢复"

# 目标 qodercn（国内版）
Assert-True ($cnInstall -match 'Qoder CN（国内版）') "install qodercn：标题显示国内版"
Assert-True ($cnInstall -match '命中 1 个配置') "install qodercn：命中 1 个配置"
Assert-True ($cnAfterInstall -ceq $personaContent) "install qodercn：AGENTS.md == 所选人格"
Assert-True ($cnInstall -match '恢复时会删除') "install qodercn：提示原文件不存在"
Assert-True ($cnStatus -match '已部署') "status qodercn：报告已部署" $cnStatus
Assert-True (-not (Test-Path -LiteralPath $cnAgents)) "restore qodercn：原不存在则删除"
Assert-True ($cnRestore -match '已删除') "restore qodercn：报告已删除"

# 核心不变量：两个目标严格隔离，谁也不许越界
Assert-True $cnUntouchedAfterIntlInstall "隔离：install qoder 不动国内版"
Assert-True $intlUntouchedAfterCnInstall "隔离：install qodercn 不动国际版"
Assert-True ($intlStatus -match '本次不处理') "status qoder：提示国内版是独立目标"
Assert-True ($cnStatus -match '本次不处理') "status qodercn：提示国际版是独立目标"

# 真机状态必须前后一致（不能因为跑测试而多出/少掉文件）
Assert-True ((Test-Path -LiteralPath $realIntl) -eq $realIntlBefore) "全链路未改动真机 ~/.qoder" $realIntl
Assert-True ((Test-Path -LiteralPath $realCn) -eq $realCnBefore) "全链路未改动真机 ~/.qoder-cn" $realCn

# ---------------------------------------------------------------
# H. 交互菜单：目标目录一致性 / 列宽对齐 / 输入解析 / .bat 单一真源
# ---------------------------------------------------------------
Write-Host ""
Write-Host "=== H. 交互菜单与目标目录一致性 ===" -ForegroundColor Cyan

$catalog = @(Get-TargetCatalog)
Assert-True ($catalog.Count -ge 1) "目标目录非空" ("count=" + $catalog.Count)

$keys = @($catalog | ForEach-Object { $_.Key })
Assert-True (@($keys | Select-Object -Unique).Count -eq $keys.Count) "菜单编号唯一" ($keys -join ',')
$expectedKeys = @(1..$keys.Count | ForEach-Object { [string]$_ })
Assert-True (($keys -join ',') -eq ($expectedKeys -join ',')) "菜单编号从 1 连续编号" ($keys -join ',')
Assert-True (@($catalog | ForEach-Object { $_.Target } | Select-Object -Unique).Count -eq $catalog.Count) "目标 id 唯一"

foreach ($pair in @(
        @{ T = 'workbuddy'; E = '国内版' }, @{ T = 'workbuddyai'; E = '国际版' },
        @{ T = 'qoder'; E = '国际版' }, @{ T = 'qodercn'; E = '国内版' })) {
    $item = $catalog | Where-Object { $_.Target -eq $pair.T } | Select-Object -First 1
    Assert-True ($item -and ($item.Edition -eq $pair.E)) ("菜单标注 " + $pair.T + " = " + $pair.E) $(if ($item) { $item.Edition } else { 'missing' })
}

# 菜单目标集合必须与 deploy.ps1 的 ValidateSet 对齐 —— 漏改任一处都会被这条测出来
$ast = [System.Management.Automation.Language.Parser]::ParseFile($deployScript, [ref]$null, [ref]$null)
$validatedTargets = @()
foreach ($paramAst in $ast.ParamBlock.Parameters) {
    if ($paramAst.Name.VariablePath.UserPath -ne 'Target') { continue }
    foreach ($attr in $paramAst.Attributes) {
        if (($attr -is [System.Management.Automation.Language.AttributeAst]) -and ($attr.TypeName.Name -eq 'ValidateSet')) {
            foreach ($argAst in $attr.PositionalArguments) {
                if ($argAst -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $validatedTargets += $argAst.Value }
            }
        }
    }
}
Assert-True ($validatedTargets.Count -gt 0) "能解析出 deploy.ps1 的 Target ValidateSet" ($validatedTargets -join ',')
Assert-True ($validatedTargets -contains 'menu') "ValidateSet 允许 menu（.bat 入口依赖它）"
foreach ($item in $catalog) {
    Assert-True ($validatedTargets -contains $item.Target) ("菜单目标在 ValidateSet 中: " + $item.Target)
}
$extraTargets = @($validatedTargets | Where-Object { $_ -ne 'menu' -and ($catalog.Target -notcontains $_) })
Assert-True ($extraTargets.Count -eq 0) "ValidateSet 没有菜单未覆盖的目标" ($extraTargets -join ',')

# 列宽按东亚宽度计算，且任何一行都不得超框（超了控制台会折行，比不对齐更难看）
Assert-True ((Get-DisplayWidth -Text 'abc') -eq 3) "ASCII 宽度 = 字符数"
Assert-True ((Get-DisplayWidth -Text '国内版') -eq 6) "汉字按 2 列计"
Assert-True ((Get-DisplayWidth -Text '') -eq 0) "空串宽度为 0"
Assert-True ((Format-DisplayPadRight -Text '国内版' -Width 8).Length -eq 5) "按显示宽度补空格（3 字 + 2 空格）"
Assert-True ((Get-DisplayWidth -Text (Format-DisplayPadRight -Text 'WorkBuddy AI 中文' -Width 20)) -eq 20) "补齐后宽度正好等于目标宽度"

foreach ($menuAction in @('install', 'restore', 'status')) {
    $menuLines = @(Get-TargetMenuLines -Action $menuAction)
    $over = @($menuLines | Where-Object { (Get-DisplayWidth -Text $_) -gt $script:WBMenuWidth })
    Assert-True ($over.Count -eq 0) ("菜单不超框: " + $menuAction) (($over | ForEach-Object { '[' + $_ + ']' }) -join ' ')
    $itemLines = @($menuLines | Where-Object { $_ -match '^\s+\[\d\] ' })
    Assert-True ($itemLines.Count -eq $catalog.Count) ("菜单列出全部目标: " + $menuAction) ("items=" + $itemLines.Count)
    $lineWidths = @($itemLines | ForEach-Object { Get-DisplayWidth -Text $_ } | Select-Object -Unique)
    Assert-True ($lineWidths.Count -eq 1) ("条目列宽完全一致（视觉对齐）: " + $menuAction) ($lineWidths -join ',')
}
Assert-True ((@(Get-TargetMenuLines -Action 'install') -join "`n") -match '部署') "菜单标题随 action 变化（install）"
Assert-True ((@(Get-TargetMenuLines -Action 'status') -join "`n") -match '查看状态') "菜单标题随 action 变化（status）"

# 输入解析。Read-Host 不接受管道输入，所以交互循环只能靠这些纯函数覆盖
foreach ($cancelInput in @('', '  ', 'q', 'Q', '0')) {
    Assert-True (Test-TargetMenuCancel -Answer $cancelInput) ("取消输入: [" + $cancelInput + "]")
}
foreach ($normalInput in @('7', '9', 'x', 'menu', 'workbuddy')) {
    Assert-True (-not (Test-TargetMenuCancel -Answer $normalInput)) ("非取消输入: [" + $normalInput + "]")
}
foreach ($item in $catalog) {
    $resolved = Get-TargetMenuItemByKey -Key $item.Key
    Assert-True ($resolved -and ($resolved.Target -eq $item.Target)) ("编号 " + $item.Key + " 解析为 " + $item.Target) $(if ($resolved) { $resolved.Target } else { 'null' })
}
Assert-True ($null -eq (Get-TargetMenuItemByKey -Key '99')) "无效编号解析为空"
Assert-True ($null -eq (Get-TargetMenuItemByKey -Key '')) "空编号解析为空"

# .bat 只做入口转发，不再重复维护目标列表（单一真源）
$gbk936 = [System.Text.Encoding]::GetEncoding(936)
foreach ($batName in @('部署.bat', '恢复.bat', '查看状态.bat')) {
    $batPath = Join-Path $RepoRoot $batName
    Assert-True (Test-Path -LiteralPath $batPath) ("存在 bat: " + $batName)
    $batText = [System.IO.File]::ReadAllText($batPath, $gbk936)
    $invokeLine = @($batText -split "`r?`n" | Where-Object { $_ -match 'deploy\.ps1' })
    Assert-True ($invokeLine.Count -eq 1) ("bat 只有一条 deploy.ps1 调用: " + $batName) ($invokeLine -join ' | ')
    # 参数必须恰好是 <action> menu —— 一旦有人把目标名内联回 bat，这条立刻失败
    Assert-True ($invokeLine[0] -match 'deploy\.ps1"\s+(install|restore|status)\s+menu\s*$') ("bat 只传 <action> menu，不内联目标名: " + $batName) $invokeLine[0]
    Assert-True (-not ($batText -match '\[[1-9]\]')) ("bat 不再手写编号菜单: " + $batName)
    Assert-True (-not ($batText -match '(?i)\bchoice\b')) ("bat 不再用 choice（菜单交给 PowerShell 渲染）: " + $batName)
    Assert-True (-not ($batText -match '(?i)if errorlevel')) ("bat 不再有 errorlevel 分支: " + $batName)
    Assert-True (-not ($batText -match 'chcp')) ("bat 不含 chcp: " + $batName)
}

# ---------------------------------------------------------------
Write-Host ""
if ($script:Failures.Count -eq 0) {
    # 全绿则清掉临时副本（约 90MB）；失败时保留现场便于排查
    Remove-Item $DryRunRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ("PASS: 干跑验证全部通过（" + $script:PassCount + " 项）") -ForegroundColor Green
    exit 0
} else {
    Write-Host ("FAIL: " + $script:Failures.Count + " 项未通过 / 共 " + ($script:PassCount + $script:Failures.Count) + " 项") -ForegroundColor Red
    Write-Host ("      现场已保留在 " + $DryRunRoot) -ForegroundColor Yellow
    $script:Failures | ForEach-Object { Write-Host ("   - " + $_) -ForegroundColor Red }
    exit 1
}
