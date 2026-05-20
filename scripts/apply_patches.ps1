<#
apply_patches.ps1 — Windows 自动 patch

用法：
  .\apply_patches.ps1 -InstallDir "$env:LOCALAPPDATA\Claude-3p\app-1.6608.2"

做四件事：
  1. patch 3P provider 健康检查（清空 vzt 函数体）
  2. patch 模型 picker 二次过滤
  3. patch modelSupportsMaxEffort（永远返回 true）
  4. patch envSupportsEffort 白名单 + 创建会话带 effort 参数

重打 asar、刷 integrity、重签由调用方负责。本脚本只动文件内容。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$InstallDir
)

$ErrorActionPreference = "Stop"

# 平台守卫：仅 Windows
if ($env:OS -ne 'Windows_NT') {
    Write-Error "apply_patches.ps1 仅支持 Windows（OS = '$env:OS'）。"
    Write-Error "macOS 用户请改用：bash scripts/apply_patches.sh <Claude-3p.app 路径>"
    Write-Error "不确定平台时，先跑：node scripts/detect_platform.js"
    exit 1
}

# 依赖检查：node + npx
if (-not (Get-Command npx -ErrorAction SilentlyContinue)) {
    Write-Error "缺少依赖：npx（即 Node.js）。请从 https://nodejs.org/ 安装。"
    Write-Error "完整依赖清单见 SKILL.md §0.4。"
    exit 1
}

if (-not (Test-Path $InstallDir)) {
    Write-Error "install dir not found: $InstallDir"
    exit 1
}

$Asar    = Join-Path $InstallDir "resources\app.asar"
$IonDir  = Join-Path $InstallDir "resources\ion-dist\assets\v1"
$Ts      = Get-Date -Format yyyyMMddHHmmss
$Work    = Join-Path $env:TEMP ("claude-fork-apply-{0}" -f $Ts)

if (-not (Test-Path $Asar))  { Write-Error "app.asar not found: $Asar"; exit 1 }
if (-not (Test-Path $IonDir)){ Write-Error "ion-dist not found: $IonDir"; exit 1 }

# ---------- 1 & 2: app.asar patch ----------

Write-Host "[1/4] backup app.asar"
Copy-Item $Asar "$Asar.before-3p-patch.$Ts"

Write-Host "[2/4] extracting app.asar..."
New-Item -ItemType Directory -Force $Work | Out-Null
& npx -y @electron/asar extract $Asar $Work 2>$null | Out-Null

$IndexJs = Join-Path $Work ".vite\build\index.js"
if (-not (Test-Path $IndexJs)) {
    Write-Error ".vite/build/index.js not found in extracted asar"
    exit 2
}

$src = Get-Content $IndexJs -Raw
$origLen = $src.Length
$changes = @()

# ---- vzt: 3P provider 健康检查 ----
$pattern_vzt = [regex]'function\s+(\w+)\s*\(e,A\)\s*\{[^{}]*?inferenceModels:\s*configured\s+model[^{}]*?return\s+null\s*\}'
$m = $pattern_vzt.Match($src)
if ($m.Success) {
    $funcName = $m.Groups[1].Value
    $newFunc  = "function $funcName(e,A){return null}"
    $src = $pattern_vzt.Replace($src, $newFunc, 1)
    $changes += "vzt($funcName): provider_health_bypass"
} elseif ($src -match 'inferenceModels: configured model') {
    Write-Warning "报错文案存在但函数边界没匹配上，可能 chunk 结构变化，需要手工 patch"
} else {
    $changes += "vzt: already patched (报错文案不在)"
}

# ---- picker filter ----
$pattern_picker = [regex]'return\s+e\?\s*i\.filter\(\s*r\s*=>\s*\w+\(e,\s*r\.id\)\.ok\s*\)\s*:\s*i'
if ($pattern_picker.IsMatch($src)) {
    $src = $pattern_picker.Replace($src, 'return i')
    $changes += "picker_filter_removed"
} elseif ($src -match 'filter\(\s*r\s*=>\s*\w+\(e,\s*r\.id\)\.ok\s*\)') {
    Write-Warning "filter 表达式存在但和预期模式不匹配，可能混淆名变化，需要手工 patch"
} else {
    $changes += "picker_filter: already patched"
}

if ($src.Length -ne $origLen -or $changes.Count -gt 0) {
    Set-Content -Path $IndexJs -Value $src -NoNewline
    foreach ($c in $changes) { Write-Host "  ok  $c" }
} else {
    Write-Host "  no changes needed in index.js"
}

Write-Host "[3/4] repack app.asar"
& npx -y @electron/asar pack $Work $Asar 2>$null | Out-Null

Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue

# ---------- 3 & 4: ion-dist effort patches ----------

Write-Host "[4/4] patching ion-dist effort chunks..."

# 找 modelSupportsMaxEffort 所在 chunk
$effortFile = Get-ChildItem "$IonDir\*.js" -ErrorAction SilentlyContinue |
                Where-Object {
                    $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
                    $c -and ($c -match 'modelSupportsMaxEffort|opus-4-6.*opus-4-7')
                } | Select-Object -First 1

if ($effortFile) {
    Copy-Item $effortFile.FullName "$($effortFile.FullName).before-effort-max-patch.$Ts"
    $s = Get-Content $effortFile.FullName -Raw
    $pat = [regex]'r=function\(e,t\)\{[^}]*?opus-4-6[^}]*?opus-4-7[^}]*?\}\(t,n\)'
    if ($pat.IsMatch($s)) {
        $s = $pat.Replace($s, 'r=function(e,t){return!0}(t,n)')
        Set-Content -Path $effortFile.FullName -Value $s -NoNewline
        Write-Host "  ok  effort_max_patched ($($effortFile.Name))"
    } elseif ($s -match 'opus-4-6' -and $s -match 'opus-4-7') {
        Write-Warning "opus-4-6/4-7 在 $($effortFile.Name) 中，但 r= 函数边界没匹配，需手工 patch"
    } else {
        Write-Host "  ok  effort_max: already patched in $($effortFile.Name)"
    }
} else {
    Write-Warning "没找到含 modelSupportsMaxEffort 的 chunk"
}

# 找 envSupportsEffort 所在 chunk
$queueFile = Get-ChildItem "$IonDir\*.js" -ErrorAction SilentlyContinue |
               Where-Object {
                   $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
                   $c -and ($c -match 'envSupportsEffort')
               } | Select-Object -First 1

if ($queueFile) {
    Copy-Item $queueFile.FullName "$($queueFile.FullName).before-effort-env-patch.$Ts"
    $s = Get-Content $queueFile.FullName -Raw
    $changed = @()

    $patEnv = [regex]'(fi)="local"===Qa\|\|"ssh"===Qa(?!\|\|"anthropic_cloud")'
    if ($patEnv.IsMatch($s)) {
        $s = $patEnv.Replace($s, '$1="local"===Qa||"ssh"===Qa||"anthropic_cloud"===Qa||"byoc"===Qa||"pool"===Qa')
        $changed += "remote_effort_env_patched"
    } elseif ($s -match '"anthropic_cloud"===') {
        $changed += "remote_effort_env: already patched"
    } else {
        Write-Warning "envSupportsEffort 白名单模式没匹配，混淆变量可能变了"
    }

    $patSession = [regex]'(mcpConfig:eo,)(coordinatorMode)'
    if ($patSession.IsMatch($s) -and $s -notmatch 'effort:hi,coordinatorMode') {
        $s = $patSession.Replace($s, '$1effort:hi,$2')
        $changed += "remote_session_passes_effort"
    } elseif ($s -match 'effort:hi,coordinatorMode') {
        $changed += "remote_session_passes_effort: already patched"
    }

    if ($changed.Count -gt 0) {
        Set-Content -Path $queueFile.FullName -Value $s -NoNewline
        foreach ($c in $changed) { Write-Host "  ok  $c ($($queueFile.Name))" }
    }
} else {
    Write-Warning "没找到含 envSupportsEffort 的 chunk"
}

Write-Host ""
Write-Host "=========================================="
Write-Host "patches applied."
Write-Host "next steps:"
Write-Host "  1. handle ASAR integrity (see full-process-windows.md §10)"
Write-Host "  2. disable Update.exe (see §14)"
Write-Host "  3. Get-ChildItem `"$InstallDir`" -Recurse | Unblock-File"
Write-Host "  4. Start-Process `"$(Split-Path $InstallDir -Parent)\Claude.exe`""
Write-Host "  5. .\scripts\verify_claude_fork.ps1 -InstallDir `"$InstallDir`""
Write-Host "=========================================="
