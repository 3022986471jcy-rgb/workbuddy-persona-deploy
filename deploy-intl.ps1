# WorkBuddyAI（国际版）兼容入口。
# 实际逻辑统一由 deploy.ps1 维护，目标固定为 workbuddyai，避免误操作国内版 WorkBuddy。
param(
    [Parameter(Position=0)]
    [ValidateSet("install", "restore", "status")]
    [string]$Action = "status",

    [Parameter(Position=1)]
    [string]$Persona = ""
)

$mainScript = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "deploy.ps1"
& $mainScript $Action "workbuddyai" $Persona
exit $LASTEXITCODE
