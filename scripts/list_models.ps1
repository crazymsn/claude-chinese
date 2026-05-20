<#
list_models.ps1 — 探测 Anthropic-compatible 中转的可用模型清单

用法：
  .\list_models.ps1 -BaseUrl "https://api.meding.site" -ApiKey "sk-xxxxx"

行为：
  1. 试 <base>/v1/models 和 <base>/anthropic/v1/models 两种路径
  2. 头部试 x-api-key 和 Authorization: Bearer 两种鉴权
  3. 把返回的 model id 按 gpt / gemini / deepseek / claude / other 分组
  4. 打印一段可粘贴的 inferenceModels JSON
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$BaseUrl,

    [Parameter(Mandatory=$true)]
    [string]$ApiKey
)

$ErrorActionPreference = "Stop"
$BaseUrl = $BaseUrl.TrimEnd('/')

function Probe([string]$url, [hashtable]$headers) {
    try {
        $resp = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 15 -ErrorAction Stop
        return @{ ok = $true; data = $resp }
    } catch {
        return @{ ok = $false; err = $_.Exception.Message }
    }
}

$urls = @("$BaseUrl/v1/models", "$BaseUrl/anthropic/v1/models")
$headerSets = @(
    @{ "x-api-key" = $ApiKey;  "anthropic-version" = "2023-06-01" },
    @{ "Authorization" = "Bearer $ApiKey"; "anthropic-version" = "2023-06-01" }
)

$found = $null
foreach ($u in $urls) {
    foreach ($h in $headerSets) {
        $r = Probe $u $h
        if ($r.ok) {
            $found = @{ url = $u; headers = $h; data = $r.data }
            break
        }
    }
    if ($found) { break }
}

if (-not $found) {
    Write-Error "没有任何 endpoint / header 组合返回 200。请检查 BaseUrl 和 ApiKey 是否正确。"
    exit 3
}

$authName = if ($found.headers.ContainsKey("x-api-key")) { "x-api-key" } else { "Authorization: Bearer" }
Write-Host "==> using endpoint: $($found.url)"
Write-Host "==> using auth:     $authName"
Write-Host ""

$models = $found.data.data
if (-not $models -or $models.Count -eq 0) {
    Write-Error "响应里没有 .data[]"
    $found.data | ConvertTo-Json -Depth 10
    exit 4
}

# 风格判断
$first = $models[0]
$style = "unknown"
if ($first.PSObject.Properties.Name -contains "type" -and $first.type -eq "model") {
    $style = "Anthropic-compatible (.data[].type=='model')"
} elseif ($first.PSObject.Properties.Name -contains "object" -and $first.object -eq "model") {
    $style = "OpenAI-compatible (.data[].object=='model')  -- 警告：这个端点可能不能直接给 Claude Desktop 用"
}
Write-Host "==> response style: $style"
Write-Host ""

# 取 id（兼容 model_id 字段名）
$modelIds = $models | ForEach-Object {
    if ($_.PSObject.Properties.Name -contains "id")        { $_.id }
    elseif ($_.PSObject.Properties.Name -contains "model_id") { $_.model_id }
} | Sort-Object -Unique

# 分组
$groups = @{
    "gpt-*"      = @()
    "gemini-*"   = @()
    "deepseek-*" = @()
    "claude-*"   = @()
    "other"      = @()
}

foreach ($id in $modelIds) {
    $lower = $id.ToLower()
    if     ($lower -match 'gpt|openai|^o[1-4]')   { $groups["gpt-*"]      += $id }
    elseif ($lower -match 'gemini|google')        { $groups["gemini-*"]   += $id }
    elseif ($lower -match 'deepseek')             { $groups["deepseek-*"] += $id }
    elseif ($lower -match 'claude|anthropic|haiku|sonnet|opus') { $groups["claude-*"] += $id }
    else                                          { $groups["other"]      += $id }
}

Write-Host "==> 发现的模型："
foreach ($g in $groups.Keys) {
    if ($groups[$g].Count -gt 0) {
        Write-Host "  [$g]"
        foreach ($m in $groups[$g]) { Write-Host "    - $m" }
    }
}

# 生成默认三家的 inferenceModels 片段
# 不用 ConvertTo-Json，避免 PS 5.1 / 7 之间在单元素数组 unwrap 和 [bool] 序列化上的差异
$lines = @()
foreach ($g in @("gpt-*","gemini-*","deepseek-*")) {
    foreach ($m in $groups[$g]) {
        $supports1m = if ($m -match 'gemini|deepseek') { 'true' } else { 'false' }
        $lines += "    { `"name`": `"$m`", `"supports1m`": $supports1m }"
    }
}

Write-Host ""
Write-Host "==> 推荐 inferenceModels 片段（粘贴到 provider 配置 JSON）："
Write-Host ""
if ($lines.Count -eq 0) {
    Write-Host "  (没有发现 gpt / gemini / deepseek 任何一家模型 —— 检查中转是否支持这些供应商)"
} else {
    Write-Host "  `"inferenceModels`": ["
    Write-Host (($lines -join ",`n"))
    Write-Host "  ]"
}
Write-Host ""
Write-Host "如果你也想保留 Claude 系列作为对照，把 claude-* 组手动加进去。"
