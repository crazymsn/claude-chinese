<#
verify_claude_fork.ps1 — Windows fork 体检脚本

用法：
  .\verify_claude_fork.ps1 -InstallDir "$env:LOCALAPPDATA\Claude-3p\app-1.6608.2"

可选参数：
  -ConfigPath          通常自动从 %AppData%\Claude-3p\ 找
  -ProviderConfigPath  通常自动从 %AppData%\Claude-3p\configLibrary\ 找最近的

验证策略：检查"原始限制特征字符串"是否还存在。
这比硬编码 patch 后的字符串字面量更稳，能跨版本工作。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$InstallDir,

    [string]$ConfigPath           = "$env:APPDATA\Claude-3p\config.json",
    [string]$ProviderConfigPath   = ""
)

$ErrorActionPreference = "Stop"

# 平台守卫：仅 Windows
if ($env:OS -ne 'Windows_NT') {
    Write-Error "verify_claude_fork.ps1 仅支持 Windows（OS = '$env:OS'）。"
    Write-Error "macOS 用户请改用：bash scripts/verify_claude_fork.sh <Claude-3p.app 路径>"
    Write-Error "不确定平台时，先跑：node scripts/detect_platform.js"
    exit 1
}

if (-not (Test-Path $InstallDir)) {
    Write-Error "install dir not found: $InstallDir"
    exit 1
}

$AsarPath  = Join-Path $InstallDir "resources\app.asar"
$IonDir    = Join-Path $InstallDir "resources\ion-dist\assets\v1"
$WorkDir   = Join-Path $env:TEMP ("claude-fork-verify-{0}" -f (Get-Date -Format yyyyMMddHHmmss))

# 自动定位 provider config
if (-not $ProviderConfigPath) {
    $cfgDir = "$env:APPDATA\Claude-3p\configLibrary"
    if (Test-Path $cfgDir) {
        $latest = Get-ChildItem "$cfgDir\*.json" -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) { $ProviderConfigPath = $latest.FullName }
    }
}

function Pass([string]$name) {
    Write-Host ("  {0,-42} : " -f $name) -NoNewline
    Write-Host "pass" -ForegroundColor Green
}
function Fail([string]$name, [string]$reason = "") {
    Write-Host ("  {0,-42} : " -f $name) -NoNewline
    Write-Host "fail" -ForegroundColor Red -NoNewline
    if ($reason) { Write-Host "  $reason" -ForegroundColor DarkGray }
    else         { Write-Host "" }
}

try {
    Write-Host ""
    Write-Host "== Authenticode =="
    $clauExe = Join-Path $InstallDir "Claude.exe"
    if (Test-Path $clauExe) {
        $sig = Get-AuthenticodeSignature $clauExe
        Write-Host ("  status                                   : {0}" -f $sig.Status)
        Write-Host ("  signer                                   : {0}" -f $sig.SignerCertificate.Subject)
    } else {
        Fail "Claude.exe" "not found at $clauExe"
    }

    Write-Host ""
    Write-Host "== runtime config =="
    if (Test-Path $ConfigPath) {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        Write-Host ("  locale                                   : {0}" -f $cfg.locale)
        Write-Host ("  deploymentMode                           : {0}" -f $cfg.deploymentMode)
    } else {
        Write-Host "  config missing: $ConfigPath"
    }

    Write-Host ""
    Write-Host "== provider config =="
    if ($ProviderConfigPath -and (Test-Path $ProviderConfigPath)) {
        $p = Get-Content $ProviderConfigPath -Raw | ConvertFrom-Json
        Write-Host ("  inferenceProvider                        : {0}" -f $p.inferenceProvider)
        Write-Host ("  inferenceGatewayBaseUrl                  : {0}" -f $p.inferenceGatewayBaseUrl)
        Write-Host ("  disableAutoUpdates                       : {0}" -f $p.disableAutoUpdates)
        $models = @($p.inferenceModels | ForEach-Object { $_.name })
        Write-Host ("  inferenceModels ({0})                       : {1}" -f $models.Count, ($(if ($models) { $models -join '; ' } else { '(empty)' })))

        foreach ($g in @('gpt','gemini','deepseek')) {
            $hit = ($models | Where-Object { $_ -like "*$g*" }).Count -gt 0
            if ($hit) { Pass ("group $g-*") } else { Fail ("group $g-*") "未在 inferenceModels 找到" }
        }
    } else {
        Write-Host "  provider config missing or not specified"
    }

    Write-Host ""
    Write-Host "== app.asar patch checks =="
    if (-not (Test-Path $AsarPath)) {
        Fail "app.asar" "not found"
    } else {
        New-Item -ItemType Directory -Force $WorkDir | Out-Null
        & npx -y @electron/asar extract $AsarPath $WorkDir 2>$null | Out-Null
        $indexJs = Join-Path $WorkDir ".vite\build\index.js"
        if (-not (Test-Path $indexJs)) {
            Fail "app.asar: index.js" "未在 .vite/build/index.js 找到"
        } else {
            $src = Get-Content $indexJs -Raw

            # provider 健康检查 patch 生效 = 原始报错文案不再出现
            if ($src -match 'inferenceModels: configured model "') {
                Fail "provider_health_bypass" "原始报错文案仍在，§7 patch 未生效"
            } else {
                Pass "provider_health_bypass"
            }

            # picker filter 移除 = 原始 filter 表达式不再出现
            if ($src -match 'filter\(.\=>YLA\(.,..id\)\.ok\)') {
                Fail "picker_filter_removed" "原始 picker filter 仍在，§8 patch 未生效"
            } else {
                Pass "picker_filter_removed"
            }
        }
    }

    Write-Host ""
    Write-Host "== effort patch checks =="
    if (Test-Path $IonDir) {
        $files = Get-ChildItem "$IonDir\*.js" -ErrorAction SilentlyContinue
        $combined = -join ($files | ForEach-Object { Get-Content $_.FullName -Raw })

        # modelSupportsMaxEffort：匹配原始限制函数的 IIFE 整体形状
        # 不能只看 opus-4-6 / opus-4-7 是否共现 —— 模型列表里这两个串本来就会一起出现
        if ($combined -match 'function\([^)]*\)\{[^}]*opus-4-6[^}]*opus-4-7[^}]*\}\([^)]*\)') {
            Fail "effort_max_patched" "Max 限制 IIFE 仍在，§10.3 patch 未生效"
        } else {
            Pass "effort_max_patched"
        }

        # envSupportsEffort 白名单扩展
        if ($combined -match '"anthropic_cloud"===') {
            Pass "remote_effort_env_patched"
        } else {
            Fail "remote_effort_env_patched" "未看到扩展的环境白名单"
        }

        # 远端 session 传 effort 参数
        if ($combined -match 'effort:hi,coordinatorMode') {
            Pass "remote_session_passes_effort"
        } else {
            Fail "remote_session_passes_effort" "创建会话调用未带 effort 参数"
        }
    } else {
        Fail "ion-dist directory" "$IonDir not found"
    }

    Write-Host ""
    Write-Host "== updater =="
    $updateExe = Join-Path (Split-Path $InstallDir -Parent) "Update.exe"
    if (Test-Path $updateExe) {
        Fail "updater disabled" "Update.exe still present at $updateExe"
    } else {
        Pass "updater disabled"
    }

    Write-Host ""
    Write-Host "== Zone.Identifier =="
    $blocked = Get-ChildItem $InstallDir -Recurse -ErrorAction SilentlyContinue |
                 Where-Object { Get-Item $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue }
    if ($blocked.Count -eq 0) {
        Pass "no Zone.Identifier ADS"
    } else {
        Fail "Zone.Identifier present on $($blocked.Count) files" "Get-ChildItem -Recurse | Unblock-File"
    }

    Write-Host ""
    Write-Host "== done =="

} finally {
    if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
}
