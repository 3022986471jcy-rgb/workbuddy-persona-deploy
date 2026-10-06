# WorkBuddy 一键部署/恢复 v5.2 - 动态 bundle 扫描 + 跨版本锚点 + Qoder 双版本 + 交互式目标菜单
param(
    [Parameter(Position=0)]
    [ValidateSet("install","restore","status")]
    [string]$Action = "status",

    # "menu" = 弹出交互式菜单选择目标（供 .bat 使用）；
    # 显式传具体目标时行为与之前完全一致，脚本化调用不受影响。
    [Parameter(Position=1)]
    [ValidateSet("menu","workbuddy","workbuddyai","qoder","qodercn","hermes","codex","zcode")]
    [string]$Target = "workbuddy",

    [Parameter(Position=2)]
    [string]$Persona = ""
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PersonaDir = Join-Path $ScriptDir "人格"
$PersonaFiles = @(
    if (Test-Path $PersonaDir) {
        Get-ChildItem -LiteralPath $PersonaDir -Filter "*.txt" -File | Sort-Object Name
    }
)

# 载入部署核心库（路径探测 / bundle 扫描 / 注入模板 / 目标目录与菜单）
. (Join-Path $ScriptDir "deploy-lib.ps1")

# 交互式选择目标（放在选人格之前：先定"给谁装"，再定"装哪个人格"）
# 注意：不能把结果直接赋回 $Target —— 取消时是 $null，而 $Target 带 ValidateSet，
# 赋 $null 会触发"值 不是变量 Target 的有效值"的校验报错。
if ($Target -eq "menu") {
    $chosenTarget = Show-TargetMenu -Action $Action
    if (-not $chosenTarget) { exit 0 }
    $Target = $chosenTarget
}

function Select-PersonaFile {
    param([string]$RequestedPersona)

    if ($PersonaFiles.Count -eq 0) {
        throw "No persona files found: $PersonaDir\*.txt"
    }

    if ($RequestedPersona) {
        $requestedLeaf = [System.IO.Path]::GetFileName($RequestedPersona)
        if ($requestedLeaf -cne $RequestedPersona) {
            throw "Persona must be a file name from the persona directory, not a path: $RequestedPersona"
        }
        $match = $PersonaFiles | Where-Object {
            $_.Name -ieq $RequestedPersona -or $_.BaseName -ieq $RequestedPersona
        } | Select-Object -First 1
        if (-not $match) { throw "Persona not found: $RequestedPersona" }
        return $match
    }

    if ($PersonaFiles.Count -eq 1) {
        Write-Host ("已自动选择人格: " + $PersonaFiles[0].Name) -ForegroundColor Green
        return $PersonaFiles[0]
    }

    Write-Host "可用人格：" -ForegroundColor Cyan
    for ($i = 0; $i -lt $PersonaFiles.Count; $i++) {
        Write-Host ("  [" + ($i + 1) + "] " + $PersonaFiles[$i].Name)
    }
    while ($true) {
        $choice = Read-Host ("请选择人格 [1-" + $PersonaFiles.Count + "]")
        $number = 0
        if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $PersonaFiles.Count) {
            return $PersonaFiles[$number - 1]
        }
        Write-Host "选择无效，请重试。" -ForegroundColor Yellow
    }
}

$SelectedPersona = $null
$PromptFile = $null
if ($Action -eq "install") {
    $SelectedPersona = Select-PersonaFile -RequestedPersona $Persona
    $PromptFile = $SelectedPersona.FullName
    $Persona = $SelectedPersona.Name
}

$ErrorActionPreference = "Stop"

# WorkBuddy（国内版）和 WorkBuddyAI（国际版）必须按独立名称探测，避免串版。
# Qoder 同理：国际版（Qoder.exe / ~/.qoder）与国内版（Qoder CN.exe / ~/.qoder-cn）是两个独立目标。
if ($Target -eq "workbuddyai") {
    $DesktopProductName = "WorkBuddyAI"
    $DesktopProductLabel = "WorkBuddyAI（国际版）"
} elseif ($Target -eq "workbuddy") {
    $DesktopProductName = "WorkBuddy"
    $DesktopProductLabel = "WorkBuddy（国内版）"
} elseif ($Target -eq "qodercn") {
    $DesktopProductName = "Qoder CN"
    $DesktopProductLabel = Get-QoderProductLabel -Target "qodercn"
} else {
    $DesktopProductName = "Qoder"
    $DesktopProductLabel = Get-QoderProductLabel -Target "qoder"
}
$DesktopExeName = $DesktopProductName + ".exe"

# ===== 定位安装根目录（v4：不再依赖已消失的 codebuddy.js）=====
$WBRoot = $null
$Bundles = @()
$TplBackupName = if ($Target -eq "workbuddyai") { "templates-backup-workbuddyai" } else { "templates-backup" }
$TplBackup = Join-Path $ScriptDir $TplBackupName
$TplDir = $null
$WBExe = $null
$CliDist = $null
$NodeRuntime = $null

if ($Target -in @("workbuddy", "workbuddyai")) {
    $WBRoot = Resolve-WBRoot -Target $Target
    if ($WBRoot) {
        $CliDist = Get-WBCliDistDir -WBRoot $WBRoot
        # 调用点必须 @()：函数 return 数组时 PowerShell 会展开，单元素会退化成裸对象，
        # 而 PSCustomObject 的 .Count 是 $null（不是 1），计数展示会变空。
        $Bundles = @(Get-WBBundles -WBRoot $WBRoot)
        $TplDir = Join-Path $WBRoot "resources\app.asar.unpacked\resources\templates"
        $WBExe = Join-Path $WBRoot $DesktopExeName
        $NodeRuntime = Resolve-WBNodeRuntime -FallbackExe $WBExe
    }
}

# ===== Qoder：走原生 AGENTS.md，不碰混淆的 worker 包 =====
# 国际版与国内版各自独立：目标 qoder 只动 ~/.qoder，目标 qodercn 只动 ~/.qoder-cn，
# 互不越界（与 workbuddy / workbuddyai 的隔离原则一致）。
$QoderChannel = $null
$QoderOtherChannel = $null
$QoderOtherLabel = $null
$QoderInstallRoots = @()
$QoderTargets = @()
if ($Target -in @("qoder", "qodercn")) {
    $QoderChannel = Get-QoderChannelOfTarget -Target $Target
    $QoderOtherChannel = if ($QoderChannel -eq ".qoder") { ".qoder-cn" } else { ".qoder" }
    $QoderOtherLabel = if ($QoderOtherChannel -eq ".qoder-cn") { "Qoder CN（国内版）" } else { "Qoder（国际版）" }
    $QoderInstallRoots = @(Get-QoderInstallRoots | Where-Object { (Get-QoderChannelOfInstall -Root $_) -ieq $QoderChannel })
    # 调用点必须 @()：函数 return 数组时 PowerShell 会展开，单元素会退化成裸对象，
    # 而 PSCustomObject 的 .Count 是 $null（不是 1），计数展示会变空。
    $QoderTargets = @(Get-QoderTargets -Channel $QoderChannel)
}

# 提权判断：不再只看系统盘 Program Files。改为「能不能真写进去」，
# 这样客户端装在非系统盘的受保护目录时同样会正确触发 UAC。
if (($Action -in @("install", "restore")) -and $Target -in @("workbuddy", "workbuddyai") -and $WBRoot) {
    $requiresAdmin = $false
    $protectedRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\') }
    foreach ($protectedRoot in $protectedRoots) {
        if ($WBRoot.Equals($protectedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or $WBRoot.StartsWith($protectedRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $requiresAdmin = $true
            break
        }
    }
    if (-not $requiresAdmin -and $CliDist) { $requiresAdmin = -not (Test-WBDirWritable -Dir $CliDist) }

    if ($requiresAdmin) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            Write-Host "Administrator permission is required. Opening UAC prompt..." -ForegroundColor Yellow
            $argLine = @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", ('"' + $PSCommandPath + '"'),
                $Action, $Target, ('"' + $Persona + '"')
            ) -join ' '
            # 用 .NET 直接起进程：Start-Process 在宿主环境同时存在 Path / PATH 两个键时
            # 会抛「已添加项。字典中的关键字:“Path”所添加的关键字:“PATH”」，这条路没有该坑。
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "powershell.exe"
                $psi.Arguments = $argLine
                $psi.WorkingDirectory = $ScriptDir
                $psi.UseShellExecute = $true
                $psi.Verb = "runas"
                $elevated = [System.Diagnostics.Process]::Start($psi)
                $elevated.WaitForExit()
                exit $elevated.ExitCode
            } catch {
                Write-Host ("[错误] 提权失败：" + $_.Exception.Message) -ForegroundColor Red
                Write-Host "       请右键『以管理员身份运行』本脚本重试。" -ForegroundColor Yellow
                exit 1
            }
        }
    }
}

# ===== Hermes（逻辑与 v3 一致，未改动）=====
$HermesCandidates = @()
$HermesExeCandidates = @()
if ($env:HERMES_HOME) { $HermesCandidates += $env:HERMES_HOME }
foreach ($process in Get-Process -Name "Hermes" -ErrorAction SilentlyContinue | Where-Object { $_.Path }) {
    $HermesExeCandidates += $process.Path
    $markerIndex = $process.Path.IndexOf("\hermes-agent\", [System.StringComparison]::OrdinalIgnoreCase)
    if ($markerIndex -gt 0) { $HermesCandidates += $process.Path.Substring(0, $markerIndex) }
}
$shortcutPaths = @(
    (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Hermes.lnk"),
    (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Hermes.lnk")
)
foreach ($shortcutPath in $shortcutPaths) {
    if (Test-Path $shortcutPath) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcutTarget = $shell.CreateShortcut($shortcutPath).TargetPath
            if ($shortcutTarget) {
                $HermesExeCandidates += $shortcutTarget
                $markerIndex = $shortcutTarget.IndexOf("\hermes-agent\", [System.StringComparison]::OrdinalIgnoreCase)
                if ($markerIndex -gt 0) { $HermesCandidates += $shortcutTarget.Substring(0, $markerIndex) }
            }
        } catch {}
    }
}
if ($env:LOCALAPPDATA) { $HermesCandidates += Join-Path $env:LOCALAPPDATA "hermes" }
if ($env:USERPROFILE) { $HermesCandidates += Join-Path $env:USERPROFILE ".hermes" }

$HermesHome = $null
foreach ($candidate in $HermesCandidates | Where-Object { $_ } | Select-Object -Unique) {
    if ((Test-Path (Join-Path $candidate "SOUL.md")) -or (Test-Path (Join-Path $candidate "profiles"))) {
        $HermesHome = [System.IO.Path]::GetFullPath($candidate)
        break
    }
}
$HermesProfilesDir = if ($HermesHome) { Join-Path $HermesHome "profiles" } else { $null }
$HermesBackupDir = Join-Path $ScriptDir "hermes-backup"
if ($HermesHome) { $HermesExeCandidates += Join-Path $HermesHome "hermes-agent\apps\desktop\release\win-unpacked\Hermes.exe" }
$HermesExe = $HermesExeCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique -First 1
$HermesTargets = @()
if ($HermesHome) {
    $HermesDefaultSoul = Join-Path $HermesHome "SOUL.md"
    if (Test-Path $HermesDefaultSoul) {
        $HermesTargets += @{ Name = "default"; Path = $HermesDefaultSoul; Backup = (Join-Path $HermesBackupDir "default-SOUL.md") }
    }
}
if ($HermesProfilesDir -and (Test-Path $HermesProfilesDir)) {
    foreach ($profileDir in Get-ChildItem -LiteralPath $HermesProfilesDir -Directory) {
        $profileSoul = Join-Path $profileDir.FullName "SOUL.md"
        if (Test-Path $profileSoul) {
            $safeProfileName = $profileDir.Name -replace '[^a-zA-Z0-9._-]', '_'
            $HermesTargets += @{
                Name = $profileDir.Name
                Path = $profileSoul
                Backup = (Join-Path $HermesBackupDir ("profile-" + $safeProfileName + "-SOUL.md"))
            }
        }
    }
}
# hashtable 单元素时会退化成裸 hashtable，其 .Count 是"键个数"而非"条目个数"，
# 会让"找到 N 个配置"显示错误 —— 统一收成数组。
$HermesTargets = @($HermesTargets)

# ===== Codex（逻辑与 v3 一致，未改动）=====
$CodexCandidates = @()
if ($env:CODEX_HOME) { $CodexCandidates += $env:CODEX_HOME }
if ($env:USERPROFILE) { $CodexCandidates += Join-Path $env:USERPROFILE ".codex" }
if ($env:HOME) { $CodexCandidates += Join-Path $env:HOME ".codex" }

$CodexHome = $null
foreach ($candidate in $CodexCandidates | Where-Object { $_ } | Select-Object -Unique) {
    if (Test-Path $candidate) {
        $CodexHome = [System.IO.Path]::GetFullPath($candidate)
        break
    }
}

$CodexBackupDir = Join-Path $ScriptDir "codex-backup"
$CodexAgentsFile = if ($CodexHome) { Join-Path $CodexHome "AGENTS.md" } else { $null }
$CodexBackupFile = Join-Path $CodexBackupDir "AGENTS.md"
$CodexConfigFile = if ($CodexHome) { Join-Path $CodexHome "config.toml" } else { $null }
$CodexAppUserModelId = "OpenAI.Codex_2p2nqsd0c76g0!App"

function Kill-Codex {
    Get-Process -Name "ChatGPT" -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*OpenAI.Codex*" } | Stop-Process -Force
    Get-Process -Name "codex" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}

function Start-Codex {
    # 优先使用 Windows 应用统一协议 / AUMID 启动桌面端
    try {
        Start-Process "explorer.exe" -ArgumentList "shell:AppsFolder\$CodexAppUserModelId" | Out-Null
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            Start-Sleep -Seconds 1
            $c = (Get-Process -Name "ChatGPT" -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*OpenAI.Codex*" }).Count
            if ($c -gt 0) {
                Write-Host "[OK] Codex (ChatGPT.exe) started ($c processes)" -ForegroundColor Green
                return
            }
        }
    } catch {}
    Write-Host "[!] Codex 自动启动失败，请手动打开桌面端。" -ForegroundColor Yellow
}

# ===== ZCode（CLI 客户端，走原生全局指令文件 ~/.zcode/AGENTS.md，不碰任何程序包）=====
# 与 Codex / Qoder 同一语义的通道：AGENTS.md 在会话启动时读取，新开会话即生效，无需重启。
$ZcodeCandidates = @()
if ($env:ZCODE_HOME) { $ZcodeCandidates += $env:ZCODE_HOME }
if ($env:USERPROFILE) { $ZcodeCandidates += Join-Path $env:USERPROFILE ".zcode" }
if ($env:HOME) { $ZcodeCandidates += Join-Path $env:HOME ".zcode" }

$ZcodeHome = $null
foreach ($candidate in $ZcodeCandidates | Where-Object { $_ } | Select-Object -Unique) {
    if (Test-Path $candidate) {
        $ZcodeHome = [System.IO.Path]::GetFullPath($candidate)
        break
    }
}

$ZcodeBackupDir = Join-Path $ScriptDir "zcode-backup"
$ZcodeAgentsFile = if ($ZcodeHome) { Join-Path $ZcodeHome "AGENTS.md" } else { $null }
$ZcodeBackupFile = Join-Path $ZcodeBackupDir "AGENTS.md"

function Kill-WB { Get-Process -Name $DesktopProductName -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 3 }
function Start-WB {
    $cl = [char]34 + $WBExe + [char]34
    Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine = $cl} | Out-Null
    Start-Sleep -Seconds 8
    $c = (Get-Process -Name $DesktopProductName -ErrorAction SilentlyContinue).Count
    Write-Host ("[OK] " + $DesktopProductName + " started ($c processes)") -ForegroundColor Green
}
function Kill-Hermes { Get-Process -Name "Hermes" -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 2 }
function Start-Hermes {
    if (Test-Path $HermesExe) {
        $hermesWorkDir = Split-Path -Parent $HermesExe
        Start-Process -FilePath $HermesExe -WorkingDirectory $hermesWorkDir | Out-Null
        for ($attempt = 1; $attempt -le 15; $attempt++) {
            Start-Sleep -Seconds 1
            $c = (Get-Process -Name "Hermes" -ErrorAction SilentlyContinue).Count
            if ($c -gt 0) {
                Write-Host "[OK] Hermes started ($c processes)" -ForegroundColor Green
                return
            }
        }
        throw "Hermes did not stay running after restart"
    }
    throw "Hermes.exe not found: $HermesExe"
}

$q = [char]34
$PromptPathForCode = if ($PromptFile) { $PromptFile } else { Join-Path $PersonaDir "__not_selected__.txt" }
$PromptPathJs = ConvertTo-WBJsStringBody -Path $PromptPathForCode

switch ($Action) {

    "status" {
        if ($Target -in @("workbuddy", "workbuddyai")) {
            Write-Host ("=== " + $DesktopProductLabel + " 状态 ===") -ForegroundColor Cyan
            if (-not $WBRoot) {
                Write-Host ("[!] 未找到 " + $DesktopProductLabel + " 安装目录") -ForegroundColor Red
                return
            }
            Write-Host ("检测到的目录: " + $WBRoot) -ForegroundColor Gray
            if ($Bundles.Count -eq 0) {
                Write-Host "[!] 该目录下没有找到任何受支持的注入锚点（可能版本结构又变了）" -ForegroundColor Red
            }
            foreach ($bundle in $Bundles) {
                $content = [System.IO.File]::ReadAllText($bundle.Path)
                $pathMatches = [regex]::Matches($content, (Get-WBPersonaPathRegex))
                $expectedPoints = $pathMatches.Count + $bundle.Anchors
                $deployedPaths = @($pathMatches | ForEach-Object { $_.Groups["path"].Value } | Select-Object -Unique)
                $deployedExists = $deployedPaths.Count -eq 1 -and (Test-Path -LiteralPath $deployedPaths[0])
                $color = if ($pathMatches.Count -eq $expectedPoints -and $deployedPaths.Count -eq 1 -and $deployedExists) { "Green" } else { "Yellow" }
                if ($deployedPaths.Count -eq 1) {
                    $deployedName = [System.IO.Path]::GetFileName($deployedPaths[0])
                    if ($deployedName -ieq "人格.txt") { $deployedName += " (legacy compatibility path)" }
                    if (-not $deployedExists) { $deployedName += " [MISSING]" }
                } else {
                    $deployedName = "mixed/unknown"
                }
                Write-Host ($bundle.RelName + ": 人格注入点 = " + $pathMatches.Count + "，当前人格 = " + $deployedName + "（该程序包预期为 " + $expectedPoints + "）") -ForegroundColor $color
            }
            Write-Host ("可用人格: " + $PersonaFiles.Count + " [" + (($PersonaFiles | ForEach-Object { $_.Name }) -join ", ") + "]")
            Write-Host ("人格目录: " + $PersonaDir) -ForegroundColor Gray
            $tpl0 = (Get-Item "$TplDir\user-context-identity.tpl" -ErrorAction SilentlyContinue).Length
            Write-Host ("身份模板为空: " + $(if ($tpl0 -eq 0) {"是"} else {"否（$tpl0 字节）"}))
        } elseif ($Target -eq "hermes") {
            Write-Host "=== Hermes 状态 ===" -ForegroundColor Cyan
            if ($HermesTargets.Count -eq 0) {
                Write-Host "[!] 未找到 Hermes SOUL.md" -ForegroundColor Yellow
            } elseif ($PersonaFiles.Count -eq 0) {
                Write-Host "[!] 未找到人格文件，无法比对 Hermes" -ForegroundColor Yellow
            } else {
                Write-Host ("检测到的目录: " + $HermesHome) -ForegroundColor Gray
                foreach ($targetItem in $HermesTargets) {
                    $targetContent = [System.IO.File]::ReadAllText($targetItem.Path)
                    $matchedPersona = $PersonaFiles | Where-Object {
                        [System.IO.File]::ReadAllText($_.FullName) -ceq $targetContent
                    } | Select-Object -First 1
                    $color = if ($matchedPersona) { "Green" } else { "Yellow" }
                    $state = if ($matchedPersona) { "已部署（" + $matchedPersona.Name + "）" } else { "自定义/未知" }
                    Write-Host ("配置 " + $targetItem.Name + ": SOUL.md = " + $state) -ForegroundColor $color
                }
                Write-Host ("可用人格: " + $PersonaFiles.Count + " [" + (($PersonaFiles | ForEach-Object { $_.Name }) -join ", ") + "]")
                Write-Host ("人格目录: " + $PersonaDir) -ForegroundColor Gray
            }
        } elseif ($Target -eq "codex") {
            Write-Host "=== Codex 状态 ===" -ForegroundColor Cyan
            if (-not $CodexHome -or -not (Test-Path $CodexAgentsFile)) {
                Write-Host "[!] 未找到 Codex 全局 AGENTS.md (~/.codex/AGENTS.md)" -ForegroundColor Yellow
            } elseif ($PersonaFiles.Count -eq 0) {
                Write-Host "[!] 未找到人格文件，无法比对 Codex" -ForegroundColor Yellow
            } else {
                Write-Host ("检测到的目录: " + $CodexHome) -ForegroundColor Gray
                $targetContent = [System.IO.File]::ReadAllText($CodexAgentsFile)
                $matchedPersona = $PersonaFiles | Where-Object {
                    [System.IO.File]::ReadAllText($_.FullName) -ceq $targetContent
                } | Select-Object -First 1
                $color = if ($matchedPersona) { "Green" } else { "Yellow" }
                $state = if ($matchedPersona) { "已部署（" + $matchedPersona.Name + "）" } else { "自定义/未知" }
                Write-Host ("全局配置 AGENTS.md = " + $state) -ForegroundColor $color
                Write-Host ("可用人格: " + $PersonaFiles.Count + " [" + (($PersonaFiles | ForEach-Object { $_.Name }) -join ", ") + "]")
                Write-Host ("人格目录: " + $PersonaDir) -ForegroundColor Gray
            }
        } elseif ($Target -eq "zcode") {
            Write-Host "=== ZCode 状态 ===" -ForegroundColor Cyan
            if (-not $ZcodeHome) {
                Write-Host "[!] 未找到 ZCode 配置目录 (~/.zcode)" -ForegroundColor Yellow
                Write-Host "    请先安装并运行一次 ZCode 让它生成配置目录。" -ForegroundColor Yellow
            } elseif ($PersonaFiles.Count -eq 0) {
                Write-Host "[!] 未找到人格文件，无法比对 ZCode" -ForegroundColor Yellow
            } else {
                Write-Host ("检测到的目录: " + $ZcodeHome) -ForegroundColor Gray
                if (-not (Test-Path -LiteralPath $ZcodeAgentsFile)) {
                    Write-Host "全局指令文件 AGENTS.md = 不存在（未部署）" -ForegroundColor Yellow
                } else {
                    $targetContent = [System.IO.File]::ReadAllText($ZcodeAgentsFile)
                    $matchedPersona = Get-ZcodeDeployedPersona -FileContent $targetContent -PersonaFiles $PersonaFiles
                    $color = if ($matchedPersona) { "Green" } else { "Yellow" }
                    $state = if ($matchedPersona) {
                        $suffix = ""
                        if ($targetContent.StartsWith((Get-ZcodeLockHeader), [System.StringComparison]::Ordinal)) { $suffix = "，执行版包装" }
                        elseif ($targetContent.StartsWith((Get-ZcodeLockHeaderLegacy), [System.StringComparison]::Ordinal)) { $suffix = "，强化包装(旧版)" }
                        "已部署（" + $matchedPersona.Name + $suffix + "）"
                    } else { "自定义/未知" }
                    Write-Host ("全局指令文件 AGENTS.md = " + $state) -ForegroundColor $color
                }
                if (Test-Path -LiteralPath $ZcodeBackupFile) {
                    Write-Host "备份: 有" -ForegroundColor Gray
                } else {
                    Write-Host "备份: 无（原文件在本工具首次写入前不存在）" -ForegroundColor Gray
                }
                Write-Host ("可用人格: " + $PersonaFiles.Count + " [" + (($PersonaFiles | ForEach-Object { $_.Name }) -join ", ") + "]")
                Write-Host ("人格目录: " + $PersonaDir) -ForegroundColor Gray
            }
        } elseif ($Target -in @("qoder", "qodercn")) {
            Write-Host ("=== " + $DesktopProductLabel + " 状态 ===") -ForegroundColor Cyan
            if ($QoderInstallRoots.Count -eq 0) {
                Write-Host ("[!] 未检测到 " + $DesktopExeName + " 对应的安装目录") -ForegroundColor Yellow
            } else {
                foreach ($root in $QoderInstallRoots) {
                    Write-Host ("客户端目录: " + $root) -ForegroundColor Gray
                }
            }
            if ($QoderTargets.Count -eq 0) {
                Write-Host ("[!] 未找到用户配置目录：" + $QoderChannel) -ForegroundColor Yellow
                Write-Host "    请先启动一次该版本客户端让它生成 profile。" -ForegroundColor Yellow
            } else {
                foreach ($qoderTarget in $QoderTargets) {
                    Write-Host ("配置目录: " + $qoderTarget.Dir) -ForegroundColor Gray
                    if ($qoderTarget.UsingOverride) {
                        Write-Host "  [注意] 存在 AGENTS.override.md（优先级高于 AGENTS.md），注入目标是它" -ForegroundColor Yellow
                    }
                    $relName = Split-Path $qoderTarget.Path -Leaf
                    if (-not (Test-Path -LiteralPath $qoderTarget.Path)) {
                        Write-Host ("  " + $relName + " = 不存在（未部署）") -ForegroundColor Yellow
                    } else {
                        $matchedPersona = Test-WBFileMatchesPersona -Path $qoderTarget.Path -PersonaFiles $PersonaFiles
                        $color = if ($matchedPersona) { "Green" } else { "Yellow" }
                        $state = if ($matchedPersona) { "已部署（" + $matchedPersona.Name + "）" } else { "自定义/未知" }
                        Write-Host ("  " + $relName + " = " + $state) -ForegroundColor $color
                    }
                    if (Test-Path -LiteralPath $qoderTarget.Backup) {
                        Write-Host "  备份: 有" -ForegroundColor Gray
                    } else {
                        Write-Host "  备份: 无（原文件在本工具首次写入前不存在）" -ForegroundColor Gray
                    }
                }
                Write-Host ("可用人格: " + $PersonaFiles.Count + " [" + (($PersonaFiles | ForEach-Object { $_.Name }) -join ", ") + "]")
                Write-Host ("人格目录: " + $PersonaDir) -ForegroundColor Gray
            }
            # 另一套是独立目标，绝不顺手一起改，只提示
            if (@(Get-QoderProfileDirs | Where-Object { $_.Name -ieq $QoderOtherChannel }).Count -gt 0) {
                Write-Host ("[提示] 本机也有 " + $QoderOtherLabel + " 的配置目录；它是独立目标，本次不处理。需要的话单独选对应菜单项。") -ForegroundColor DarkGray
            }
        }
    }

    "install" {
        Write-Host "[1/4] 检查选中的人格..." -ForegroundColor Cyan
        Write-Host ("  [完成] " + $SelectedPersona.Name + "（$($SelectedPersona.Length) 字节）") -ForegroundColor Green

        if ($Target -eq "hermes") {
            Write-Host "[2/4] 定位 Hermes 配置..." -ForegroundColor Cyan
            if ($HermesTargets.Count -eq 0) {
                Write-Host "  [错误] 未安装 Hermes 或未找到 SOUL.md" -ForegroundColor Red
                exit 1
            }
            Write-Host ("  [完成] 找到 " + $HermesTargets.Count + " 个配置") -ForegroundColor Green

            Write-Host "[3/4] 备份并部署 Hermes SOUL.md..." -ForegroundColor Cyan
            $hermesWasRunning = (Get-Process -Name "Hermes" -ErrorAction SilentlyContinue).Count -gt 0
            if (-not (Test-Path $HermesBackupDir)) { New-Item -ItemType Directory -Path $HermesBackupDir | Out-Null }
            $personaContent = [System.IO.File]::ReadAllText($PromptFile)
            foreach ($targetItem in $HermesTargets) {
                if (-not (Test-Path $targetItem.Backup)) {
                    Copy-Item $targetItem.Path $targetItem.Backup -Force
                    Write-Host ("  [完成] 已创建配置 " + $targetItem.Name + " 的备份") -ForegroundColor Green
                }
                [System.IO.File]::WriteAllText($targetItem.Path, $personaContent, [System.Text.UTF8Encoding]::new($false))
                $verified = [System.IO.File]::ReadAllText($targetItem.Path) -ceq $personaContent
                if (-not $verified) { throw "Hermes SOUL.md verification failed: $($targetItem.Path)" }
                Write-Host ("  [完成] 已部署配置 " + $targetItem.Name) -ForegroundColor Green
            }

            Write-Host "[4/4] 如正在运行则重启 Hermes..." -ForegroundColor Cyan
            if ($hermesWasRunning) { Kill-Hermes; Start-Hermes } else { Write-Host "  [完成] Hermes 当前未运行" -ForegroundColor Green }
            Write-Host "=== Hermes 部署完成 ===" -ForegroundColor Green
            return
        }

        if ($Target -eq "codex") {
            Write-Host "[2/4] 定位 Codex 全局配置..." -ForegroundColor Cyan
            if (-not $CodexHome) {
                Write-Host "  [错误] 未找到 Codex 主目录 (~/.codex)" -ForegroundColor Red
                exit 1
            }
            Write-Host ("  [完成] 找到目录: " + $CodexHome) -ForegroundColor Green

            Write-Host "[3/4] 备份并部署 Codex AGENTS.md..." -ForegroundColor Cyan
            $codexWasRunning = (Get-Process -Name "ChatGPT" -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*OpenAI.Codex*" }).Count -gt 0 -or (Get-Process -Name "codex" -ErrorAction SilentlyContinue).Count -gt 0
            if (-not (Test-Path $CodexBackupDir)) { New-Item -ItemType Directory -Path $CodexBackupDir | Out-Null }
            if ((Test-Path $CodexAgentsFile) -and (-not (Test-Path $CodexBackupFile))) {
                Copy-Item $CodexAgentsFile $CodexBackupFile -Force
                Write-Host "  [完成] 已创建原始 AGENTS.md 的备份" -ForegroundColor Green
            }
            $personaContent = [System.IO.File]::ReadAllText($PromptFile)
            [System.IO.File]::WriteAllText($CodexAgentsFile, $personaContent, [System.Text.UTF8Encoding]::new($false))
            $verified = [System.IO.File]::ReadAllText($CodexAgentsFile) -ceq $personaContent
            if (-not $verified) { throw "Codex AGENTS.md verification failed: $CodexAgentsFile" }
            Write-Host "  [完成] 已部署 Codex AGENTS.md" -ForegroundColor Green

            Write-Host "[4/4] 如正在运行则重启 Codex 客户端..." -ForegroundColor Cyan
            if ($codexWasRunning) {
                Kill-Codex
                Start-Codex
            } else {
                Write-Host "  [完成] Codex 当前未运行（开启新会话或启动时自动加载）" -ForegroundColor Green
            }
            Write-Host "=== Codex 部署完成 ===" -ForegroundColor Green
            return
        }

        if ($Target -eq "zcode") {
            Write-Host "[2/4] 定位 ZCode 全局指令文件..." -ForegroundColor Cyan
            if (-not $ZcodeHome) {
                Write-Host "  [错误] 未找到 ZCode 配置目录 (~/.zcode)" -ForegroundColor Red
                Write-Host "         请先安装并运行一次 ZCode 让它生成配置目录后重试。" -ForegroundColor Yellow
                exit 1
            }
            Write-Host ("  [完成] 找到目录: " + $ZcodeHome) -ForegroundColor Green

            Write-Host "[3/4] 备份并部署 ZCode AGENTS.md..." -ForegroundColor Cyan
            if (-not (Test-Path $ZcodeBackupDir)) { New-Item -ItemType Directory -Path $ZcodeBackupDir | Out-Null }
            if (-not (Test-Path -LiteralPath $ZcodeAgentsFile)) {
                Write-Host "  [提示] 原 AGENTS.md 不存在，无需备份（恢复时会删除）" -ForegroundColor Gray
            } elseif (-not (Test-Path -LiteralPath $ZcodeBackupFile)) {
                # 只有非本工具写入的内容才值得备份；旧版部署内容由恢复逻辑直接清理，
                # 备份它只会让 restore 还原出一个已废弃的版本。
                $existing = [System.IO.File]::ReadAllText($ZcodeAgentsFile)
                $isOurs = (Test-ZcodeLockContent -FileContent $existing) -or
                    ($null -ne (Get-ZcodeDeployedPersona -FileContent $existing -PersonaFiles $PersonaFiles))
                if ($isOurs) {
                    Write-Host "  [提示] 现有内容为本工具旧版部署，直接覆盖（无需备份）" -ForegroundColor Gray
                } else {
                    Copy-Item -LiteralPath $ZcodeAgentsFile -Destination $ZcodeBackupFile -Force
                    Write-Host "  [完成] 已创建原 AGENTS.md 的备份" -ForegroundColor Green
                }
            } else {
                Write-Host "  [提示] 备份已存在，保留最早的那一份" -ForegroundColor Gray
            }
            $personaContent = Get-ZcodeStrengthenedContent -PersonaContent ([System.IO.File]::ReadAllText($PromptFile))
            [System.IO.File]::WriteAllText($ZcodeAgentsFile, $personaContent, [System.Text.UTF8Encoding]::new($false))
            if (-not ([System.IO.File]::ReadAllText($ZcodeAgentsFile) -ceq $personaContent)) {
                throw ("ZCode AGENTS.md verification failed: " + $ZcodeAgentsFile)
            }
            Write-Host "  [完成] 已部署 ZCode AGENTS.md（含 ZCODE-LOCK 执行版包装）" -ForegroundColor Green

            Write-Host "[4/4] 生效方式..." -ForegroundColor Cyan
            Write-Host "  [完成] AGENTS.md 在会话启动时读取，无需重启；新开一个会话即为所选人格。" -ForegroundColor Green
            Write-Host "  [提示] 已有会话仍用旧内容，重开该会话即可。" -ForegroundColor Gray
            Write-Host "=== ZCode 部署完成 ===" -ForegroundColor Green
            return
        }

        if ($Target -in @("qoder", "qodercn")) {
            Write-Host ("[2/4] 定位 " + $DesktopProductLabel + " 用户配置...") -ForegroundColor Cyan
            if ($QoderTargets.Count -eq 0) {
                Write-Host ("  [错误] 未找到用户配置目录：" + $QoderChannel) -ForegroundColor Red
                Write-Host ("         请先启动一次 " + $DesktopProductLabel + " 让它生成 profile 后重试。") -ForegroundColor Yellow
                exit 1
            }
            Write-Host ("  [完成] 命中 " + $QoderTargets.Count + " 个配置" + $(if ($QoderInstallRoots.Count -gt 0) { "，客户端：" + $QoderInstallRoots[0] } else { "（未检测到匹配的安装目录）" })) -ForegroundColor Green

            Write-Host "[3/4] 备份并部署 AGENTS.md..." -ForegroundColor Cyan
            $personaContent = [System.IO.File]::ReadAllText($PromptFile)
            foreach ($qoderTarget in $QoderTargets) {
                $leaf = Split-Path $qoderTarget.Path -Leaf
                Write-Host ("  -> " + $qoderTarget.Dir) -ForegroundColor Cyan
                if (-not (Test-Path -LiteralPath $qoderTarget.Backup)) {
                    if (Test-Path -LiteralPath $qoderTarget.Path) {
                        Copy-Item -LiteralPath $qoderTarget.Path -Destination $qoderTarget.Backup -Force
                        Write-Host ("  [完成] 已备份原 " + $leaf) -ForegroundColor Green
                    } else {
                        Write-Host ("  [提示] 原 " + $leaf + " 不存在，无需备份（恢复时会删除）") -ForegroundColor Gray
                    }
                } else {
                    Write-Host "  [提示] 备份已存在，保留最早的那一份" -ForegroundColor Gray
                }
                if ($qoderTarget.UsingOverride) {
                    Write-Host "  [注意] 存在 AGENTS.override.md，写入它（优先级高于 AGENTS.md）" -ForegroundColor Yellow
                }
                [System.IO.File]::WriteAllText($qoderTarget.Path, $personaContent, [System.Text.UTF8Encoding]::new($false))
                if (-not ([System.IO.File]::ReadAllText($qoderTarget.Path) -ceq $personaContent)) {
                    throw ("Qoder AGENTS.md verification failed: " + $qoderTarget.Path)
                }
                Write-Host ("  [完成] 已部署 " + $leaf) -ForegroundColor Green
            }

            Write-Host "[4/4] 生效方式..." -ForegroundColor Cyan
            Write-Host "  [完成] AGENTS.md 在会话启动时读取，无需重启；新开一个会话即为所选人格。" -ForegroundColor Green
            Write-Host "  [提示] 已有会话仍用旧内容，重启单个会话即可（不希望被打断的编辑不受影响）。" -ForegroundColor Gray
            if (@(Get-QoderProfileDirs | Where-Object { $_.Name -ieq $QoderOtherChannel }).Count -gt 0) {
                Write-Host ("  [提示] " + $QoderOtherLabel + " 是独立目标，本次未改动；需要的话单独选对应菜单项。") -ForegroundColor DarkGray
            }
            Write-Host ("=== " + $DesktopProductLabel + " 部署完成 ===") -ForegroundColor Green
            return
        }

        if (-not $WBRoot) {
            Write-Host ("[错误] 未找到 " + $DesktopProductLabel + " 安装目录") -ForegroundColor Red
            exit 1
        }
        if ($Bundles.Count -eq 0) {
            Write-Host ("[错误] " + $WBRoot) -ForegroundColor Red
            Write-Host "       该目录下没有找到任何受支持的注入锚点。若是刚更新过客户端，说明 SDK 结构又变了，需要重新定位 create() 。" -ForegroundColor Red
            exit 1
        }

        Write-Host ("[2/4] 备份并修补 " + $DesktopProductLabel + " 程序包（共 " + $Bundles.Count + " 个）...") -ForegroundColor Cyan

        # 阶段一：全部在内存里算出结果并自检，任何一处不达标就整体不落盘
        $plan = @()
        foreach ($bundle in $Bundles) {
            Write-Host ("  -> " + $bundle.RelName) -ForegroundColor Cyan
            $patch = Get-WBBundlePatchedContent -Content ([System.IO.File]::ReadAllText($bundle.Path)) -PromptJs $PromptPathJs -InjectAnchors

            if ($patch.Expected -eq 0) {
                Write-Host "     [ERROR] No supported injection anchors found; file not written" -ForegroundColor Red
                exit 1
            }
            if ($patch.InjectedAfter -ne $patch.Expected) {
                Write-Host ("     [ERROR] Expected " + $patch.Expected + " injection points, found " + $patch.InjectedAfter + "; file not written") -ForegroundColor Red
                exit 1
            }
            if (-not $patch.Changed) {
                Write-Host ("     [SKIP] Already up to date (" + $patch.Injected + "/" + $patch.Expected + " points)") -ForegroundColor Gray
            }
            $plan += [pscustomobject]@{ Bundle = $bundle; Patch = $patch }
        }

        # 阶段二：统一写盘。任一程序包语法自检失败 -> 回滚本次所有写入，不留半吊子状态
        $written = @()
        try {
            foreach ($item in $plan) {
                if (-not $item.Patch.Changed) { continue }
                $bundle = $item.Bundle
                $patch = $item.Patch

                if (-not (Test-Path $bundle.Backup)) {
                    Copy-Item $bundle.Path $bundle.Backup -Force
                    Write-Host ("     backup created -> " + [System.IO.Path]::GetFileName($bundle.Backup)) -ForegroundColor Gray
                }
                [System.IO.File]::WriteAllText($bundle.Path, $patch.Content, [System.Text.UTF8Encoding]::new($false))
                $written += $bundle

                if ($patch.Injected -gt 0) { Write-Host ("     [OK] persona path -> " + [System.IO.Path]::GetFileName($PromptPathForCode) + " (" + $patch.Injected + " existing points)") -ForegroundColor Green }
                if ($patch.ChatAnchors -ge 1) { Write-Host ("     [OK] chat/completions patched (" + $patch.ChatAnchors + ")") -ForegroundColor Green }
                if ($patch.RespAnchors -ge 1) { Write-Host ("     [OK] responses patched (" + $patch.RespAnchors + ")") -ForegroundColor Green }

                if (-not $NodeRuntime) {
                    Write-Host "     [WARN] 未找到可用的 node 运行时，跳过语法自检" -ForegroundColor Yellow
                    continue
                }
                if (-not (Test-WBJavaScriptSyntax -Path $bundle.Path -NodeExe $NodeRuntime.Exe -UseElectronRunAsNode:$NodeRuntime.UseElectronRunAsNode)) {
                    throw ("syntax check failed: " + $bundle.RelName)
                }
                Write-Host "     [OK] syntax check passed" -ForegroundColor Green
            }
        } catch {
            Write-Host "     [ERROR] 部署失败，正在回滚本次所有写入..." -ForegroundColor Red
            if ($script:WBLastSyntaxDiagnostic) { Write-Host ("     " + $script:WBLastSyntaxDiagnostic) -ForegroundColor DarkGray }
            foreach ($b in $written) {
                if (Test-Path $b.Backup) { Copy-Item $b.Backup $b.Path -Force }
            }
            Write-Host ("     " + $_.Exception.Message) -ForegroundColor Red
            exit 1
        }

        Write-Host ("[3/4] 清空 " + $DesktopProductLabel + " 身份模板...") -ForegroundColor Cyan
        if (-not (Test-Path $TplBackup)) { New-Item -ItemType Directory -Path $TplBackup | Out-Null }
        foreach ($t in @("user-context-identity.tpl","user-context-expert-identity.tpl","ask-mode-reminder.tpl","craft-mode-reminder.tpl")) {
            $src = "$TplDir\$t"
            if (Test-Path $src) {
                if (-not (Test-Path "$TplBackup\$t")) { Copy-Item $src "$TplBackup\$t" -Force }
                if ((Get-Item $src).Length -gt 0) {
                    [System.IO.File]::WriteAllText($src, "", [System.Text.UTF8Encoding]::new($false))
                    Write-Host "  [OK] $t -> empty" -ForegroundColor Green
                }
            }
        }

        Write-Host ("[4/4] 重启 " + $DesktopProductLabel + "...") -ForegroundColor Cyan
        Kill-WB; Start-WB
        Write-Host ""
        Write-Host ("=== " + $DesktopProductLabel + " 部署完成 ===") -ForegroundColor Green
    }

    "restore" {
        if ($Target -eq "hermes") {
            Write-Host "正在恢复 Hermes..." -ForegroundColor Cyan
            $hermesWasRunning = (Get-Process -Name "Hermes" -ErrorAction SilentlyContinue).Count -gt 0
            $restored = 0
            foreach ($targetItem in $HermesTargets) {
                if (Test-Path $targetItem.Backup) {
                    Copy-Item $targetItem.Backup $targetItem.Path -Force
                    $restored++
                    Write-Host ("[完成] 已恢复 Hermes 配置 " + $targetItem.Name) -ForegroundColor Green
                }
            }
            if ($restored -eq 0) { Write-Host "[提示] 未找到 Hermes 备份" -ForegroundColor Yellow }
            if ($hermesWasRunning) { Kill-Hermes; Start-Hermes }
            Write-Host "=== Hermes 恢复完成 ===" -ForegroundColor Green
            return
        }

        if ($Target -eq "codex") {
            Write-Host "正在恢复 Codex..." -ForegroundColor Cyan
            if (-not $CodexHome -or -not (Test-Path $CodexAgentsFile)) {
                Write-Host "  [错误] 未找到 Codex 全局 AGENTS.md" -ForegroundColor Red
                exit 1
            }
            $codexWasRunning = (Get-Process -Name "ChatGPT" -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*OpenAI.Codex*" }).Count -gt 0 -or (Get-Process -Name "codex" -ErrorAction SilentlyContinue).Count -gt 0
            if (Test-Path $CodexBackupFile) {
                Copy-Item $CodexBackupFile $CodexAgentsFile -Force
                Write-Host "  [完成] 已从备份恢复 AGENTS.md" -ForegroundColor Green
            } else {
                Write-Host "  [提示] 未找到 Codex 备份文件 ($CodexBackupFile)" -ForegroundColor Yellow
            }
            if ($codexWasRunning) {
                Kill-Codex
                Start-Codex
            }
            Write-Host "=== Codex 恢复完成 ===" -ForegroundColor Green
            return
        }

        if ($Target -eq "zcode") {
            Write-Host "正在恢复 ZCode..." -ForegroundColor Cyan
            if (-not $ZcodeHome) {
                Write-Host "  [错误] 未找到 ZCode 配置目录 (~/.zcode)" -ForegroundColor Red
                exit 1
            }
            $restored = 0
            if (Test-Path -LiteralPath $ZcodeBackupFile) {
                Copy-Item -LiteralPath $ZcodeBackupFile -Destination $ZcodeAgentsFile -Force
                $restored++
                Write-Host "  [完成] 已从备份恢复 AGENTS.md" -ForegroundColor Green
            } elseif (Test-Path -LiteralPath $ZcodeAgentsFile) {
                # 无备份：文件可能是"原本不存在、由本工具创建"—— 只在内容确认为本工具
                # 注入的人格（裸人格或 ZCODE-LOCK 强化包装整体）时才删除，绝不误删用户自己的内容。
                $fileContent = [System.IO.File]::ReadAllText($ZcodeAgentsFile)
                $matched = Get-ZcodeDeployedPersona -FileContent $fileContent -PersonaFiles $PersonaFiles
                if ($matched) {
                    Remove-Item -LiteralPath $ZcodeAgentsFile -Force
                    $restored++
                    Write-Host "  [完成] AGENTS.md 原不存在且内容确认为本工具注入，已删除" -ForegroundColor Green
                } else {
                    Write-Host "  [跳过] 无备份且内容非本工具注入，保留原文件 AGENTS.md" -ForegroundColor Yellow
                }
            } else {
                Write-Host "  [跳过] AGENTS.md 不存在，无需恢复" -ForegroundColor Gray
            }
            if ($restored -eq 0) { Write-Host "[提示] 没有任何改动被恢复" -ForegroundColor Yellow }
            Write-Host "  [提示] AGENTS.md 在会话启动时读取，新会话即恢复正常。" -ForegroundColor Gray
            Write-Host "=== ZCode 恢复完成 ===" -ForegroundColor Green
            return
        }

        if ($Target -in @("qoder", "qodercn")) {
            Write-Host ("正在恢复 " + $DesktopProductLabel + "...") -ForegroundColor Cyan
            if ($QoderTargets.Count -eq 0) {
                Write-Host ("  [错误] 未找到用户配置目录：" + $QoderChannel) -ForegroundColor Red
                exit 1
            }
            $restored = 0
            foreach ($qoderTarget in $QoderTargets) {
                $leaf = Split-Path $qoderTarget.Path -Leaf
                if (Test-Path -LiteralPath $qoderTarget.Backup) {
                    Copy-Item -LiteralPath $qoderTarget.Backup -Destination $qoderTarget.Path -Force
                    $restored++
                    Write-Host ("  [完成] 已从备份恢复 " + $leaf) -ForegroundColor Green
                    continue
                }
                # 没有备份：可能是"原本不存在、由本工具创建"的文件 —— 只在内容确认为本工具
                # 注入的人格时才删除，绝不误删用户自己的内容。
                if (Test-Path -LiteralPath $qoderTarget.Path) {
                    $matched = Test-WBFileMatchesPersona -Path $qoderTarget.Path -PersonaFiles $PersonaFiles
                    if ($matched) {
                        Remove-Item -LiteralPath $qoderTarget.Path -Force
                        $restored++
                        Write-Host ("  [完成] " + $leaf + " 原不存在且内容确认为本工具注入，已删除") -ForegroundColor Green
                    } else {
                        Write-Host ("  [跳过] 无备份且内容非本工具注入，保留原文件 " + $leaf) -ForegroundColor Yellow
                    }
                } else {
                    Write-Host ("  [跳过] " + $leaf + " 不存在，无需恢复") -ForegroundColor Gray
                }
            }
            if ($restored -eq 0) { Write-Host "[提示] 没有任何改动被恢复" -ForegroundColor Yellow }
            Write-Host "  [提示] AGENTS.md 在会话启动时读取，新会话即恢复正常，无需重启客户端。" -ForegroundColor Gray
            Write-Host ("=== " + $DesktopProductLabel + " 恢复完成 ===") -ForegroundColor Green
            return
        }

        if (-not $WBRoot) {
            Write-Host ("[错误] 未找到 " + $DesktopProductLabel + " 安装目录") -ForegroundColor Red
            exit 1
        }
        Write-Host ("正在恢复 " + $DesktopProductLabel + "...") -ForegroundColor Cyan
        Kill-WB
        $restored = 0
        foreach ($bundle in $Bundles) {
            if (Test-Path $bundle.Backup) {
                Copy-Item $bundle.Backup $bundle.Path -Force
                $restored++
                Write-Host ("[完成] 已恢复 " + $bundle.RelName) -ForegroundColor Green
            } else {
                Write-Host ("[提示] 无备份，跳过 " + $bundle.RelName) -ForegroundColor Yellow
            }
        }
        if ($restored -eq 0) {
            Write-Host "[提示] 未找到任何程序包备份，可能从未部署过。" -ForegroundColor Yellow
        }
        if (Test-Path $TplBackup) {
            Copy-Item "$TplBackup\*" $TplDir -Force -ErrorAction SilentlyContinue
            Write-Host "[完成] 已恢复模板" -ForegroundColor Green
        }
        Start-WB
        Write-Host ("=== " + $DesktopProductLabel + " 恢复完成 ===") -ForegroundColor Green
    }
}
