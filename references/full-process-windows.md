# Claude Desktop for Windows 改包全流程

本文记录在 Windows 10/11 上 fork Claude Desktop、patch 客户端、配通 `https://api.meding.site` 中转、汉化、禁更新、并完成启动验证的完整流程。

实操环境：

- 原版安装：`%LocalAppData%\AnthropicClaude\`（Squirrel.Windows 安装结构）
- Fork 目标：`%LocalAppData%\Claude-3p\`
- Claude Desktop 版本：1.6608.2（**chunk 文件名和混淆函数名随版本变化，按特征字符串定位**）
- 用户数据目录：`%AppData%\Claude-3p\`
- 中转网关：`https://api.meding.site`
- 默认启用的模型：GPT / Gemini / DeepSeek 三家（实际清单由 `/v1/models` 决定）

      注：
      • 所有命令默认在 **PowerShell（管理员）** 下执行。`%VAR%` 在 PowerShell 里写作 `$env:VAR`。
      • 原版 `%LocalAppData%\AnthropicClaude\` 不做修改，只复制出 fork。
      • Windows 上没有 `codesign` / `Info.plist` / `lproj` 这些 macOS 概念，但 Electron ASAR 校验依然存在。
      • Squirrel.Windows 把版本装在 `app-<version>\` 子目录里，wrapper exe 在外层。复制时两个都要带。

------

## 1. 修改目标

- 允许 `inferenceModels` 中配置非 Anthropic catalog 模型
- 让模型选择器同时显示 `gpt-*` / `gemini-*` / `deepseek-*`
- 让 Claude Code 中第三方模型的 effort 菜单显示并允许 `Max`
- 通过 Anthropic-compatible 中转 `https://api.meding.site` 接通三家
- 禁用自动更新
- 中文汉化（参见 `i18n-localization.md`）

------

## 2. 前提条件

- 已安装 Claude Desktop（Squirrel.Windows 安装包）
- 已安装 Node.js（用于 `@electron/asar`）
- PowerShell 5.1+ 或 PowerShell 7+
- 当前用户对 `%LocalAppData%` 有写权限
- Claude Desktop 未在运行

检查进程：

```powershell
Get-Process -Name "Claude" -ErrorAction SilentlyContinue
```

如果有 Claude 进程，先退出客户端。

------

## 3. 确认 3P Gateway 配置

配置目录：

```powershell
$env:APPDATA\Claude-3p\configLibrary\
```

如果是第一次跑 fork，先用原版数据目录的配置文件做模板：

```powershell
$origCfg  = "$env:APPDATA\Claude\configLibrary"
$forkCfg  = "$env:APPDATA\Claude-3p\configLibrary"
New-Item -ItemType Directory -Force $forkCfg | Out-Null
Copy-Item "$origCfg\*.json" $forkCfg -Force
```

核心字段（先填空 inferenceModels，待 §15 自动识别后回填）：

```json
{
  "inferenceProvider": "gateway",
  "inferenceGatewayBaseUrl": "https://api.meding.site",
  "inferenceGatewayApiKey": "<redacted>",
  "inferenceModels": [],
  "disableAutoUpdates": true
}
```

> **`disableAutoUpdates` 字段未经实测，仅 best-effort**。Windows 上真正可靠的禁更新机制是 §14 描述的"删 `Update.exe` + 改坏 `app-update.yml`"。即使这个字段在你的版本里被忽略也没副作用。

`inferenceGatewayApiKey` 不要写入教程、截图或日志。

详细配置语义见 `references/providers.md`。

------

## 4. Fork Claude 安装目录

```powershell
$SRC  = "$env:LOCALAPPDATA\AnthropicClaude"
$DEST = "$env:LOCALAPPDATA\Claude-3p"
$TS   = Get-Date -Format yyyyMMddHHmmss

if (Test-Path $DEST) {
  Rename-Item $DEST "$DEST.before-3p-patch.$TS"
}

Copy-Item $SRC $DEST -Recurse -Force
```

确认目录里同时有 `app-<version>\` 和外层的 `Claude.exe`（wrapper）：

```powershell
Get-ChildItem $DEST
```

预期至少有：

- `app-1.6608.2\`（版本目录，**实际版本号按你的安装版本**）
- `Claude.exe`（启动 wrapper）
- `Update.exe`（Squirrel 自动更新器，**§14 会处理**）
- `packages\` 或 `RELEASES`（更新清单）

------

## 5. 修改快捷方式显示名（可选）

Windows 没有 `CFBundleDisplayName`。要让 Start Menu 显示 "Claude 3P"：

```powershell
$WshShell  = New-Object -ComObject WScript.Shell
$Shortcut  = $WshShell.CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Claude 3P.lnk")
$Shortcut.TargetPath = "$env:LOCALAPPDATA\Claude-3p\Claude.exe"
$Shortcut.WorkingDirectory = "$env:LOCALAPPDATA\Claude-3p"
$Shortcut.IconLocation = "$env:LOCALAPPDATA\Claude-3p\Claude.exe,0"
$Shortcut.Save()
```

**不要**直接改 `Claude.exe` 的 `FileDescription`，会破坏 Authenticode 签名结构。

      注：
      • Windows 内部用 AppUserModelID（注册表 `HKCU\Software\Classes\AppUserModelId\com.anthropic.claudefordesktop`）来识别 app 身份。**不要改这个 ID**，否则任务栏、通知、JumpList 都会坏。

------

## 6. 解包 app.asar

```powershell
$APP  = "$env:LOCALAPPDATA\Claude-3p\app-1.6608.2"
$ASAR = "$APP\resources\app.asar"
$TS   = Get-Date -Format yyyyMMddHHmmss
$WORK = "$env:TEMP\claude-fork-$TS"

Copy-Item $ASAR "$ASAR.before-3p-patch.$TS"

npx -y @electron/asar extract $ASAR $WORK
Write-Output $WORK
```

主要修改文件：

```text
$WORK\.vite\build\index.js
```

------

## 7. Patch 3P Provider 健康检查

### 7.1 定位代码

用 PowerShell `Select-String`（或 ripgrep，如果已装）按特征字符串定位：

```powershell
Select-String -Path "$WORK\.vite\build\index.js" `
  -Pattern 'inferenceModels: configured model' `
  -SimpleMatch
```

本次版本中定位到的函数等价于：

```js
function vzt(e,A){
  if(!FLA||!(A!=null&&A.length))return null;
  for(const t of A){
    const i=YLA(e,t.name);
    if(!i.ok)return`inferenceModels: configured model "${t.name}" is not an Anthropic model. ${WLA[e]} deployments require an Anthropic model from the provider catalog — ${i.reason}`;
    "warn"in i&&S.warn(`[custom-3p] ${i.warn}`)
  }
  return null
}
```

混淆名 `vzt`、`YLA` 会随版本变。**按报错文案定位是稳定方式。**

### 7.2 修改代码

把整个函数改为：

```js
function vzt(e,A){return null}
```

PowerShell 单行替换（注意函数名占位用本次实际识别到的名字）：

```powershell
$IDX = "$WORK\.vite\build\index.js"
$src = Get-Content $IDX -Raw
$src = $src -replace 'function vzt\(e,A\)\{[\s\S]*?return null\s*\}', 'function vzt(e,A){return null}'
Set-Content -Path $IDX -Value $src -NoNewline
```

------

## 8. Patch 模型 Picker 二次过滤

定位代码（同样按特征字符串）：

```powershell
Select-String -Path "$WORK\.vite\build\index.js" `
  -Pattern 'filter\(.\=\>YLA\(e,..id\).ok\)' -CaseSensitive
```

把 `return e?i.filter(r=>YLA(e,r.id).ok):i` 改为 `return i`：

```powershell
$src = Get-Content $IDX -Raw
$src = $src -replace 'return e\?i\.filter\(r=>YLA\(e,r\.id\)\.ok\):i', 'return i'
Set-Content -Path $IDX -Value $src -NoNewline
```

------

## 9. 重新打包 app.asar

```powershell
npx -y @electron/asar pack $WORK $ASAR
```

      注：
      • Windows 上的 Electron ASAR integrity 校验方式见 §10。Electron 22+ 起 Windows 平台也强制校验。

------

## 10. 处理 ASAR Integrity（Windows 方式）

Electron 22+ 在 Windows 上把 asar integrity hash 嵌入主 `Claude.exe`（或 `app-<version>\Claude.exe`）的 PE 资源段，而不是 macOS 的 `Info.plist`。重打 asar 后 hash 不匹配，启动会立刻崩溃，事件查看器里能看到 `Integrity check failed for asar archive`。

### 10.1 取期望 hash

让 Electron 自己告诉你它期望的 hash：

```powershell
$env:ELECTRON_ENABLE_LOGGING = "1"
& "$APP\Claude.exe"
# 等 3 秒，主进程会立即崩溃并把期望 hash 写到 stderr
```

在事件查看器（Windows 日志 → 应用程序）里找 `Claude.exe` 的崩溃记录，错误描述大致是：

```text
Integrity check failed for asar archive (<plist hash> vs <expected hash>)
```

`vs` 后面那个值就是新 hash。

### 10.2 写回 hash

Electron Windows 把 integrity 信息存在 `app-<version>\resources\electron-asar-integrity.json`（部分版本）或者 PE 资源里。先看文件是否存在：

```powershell
$INTEGRITY_JSON = "$APP\resources\electron-asar-integrity.json"
Test-Path $INTEGRITY_JSON
```

**情况 A：存在 `electron-asar-integrity.json`**

```powershell
$NEW_HASH = "<从崩溃日志拿到的 hash>"
$j = Get-Content $INTEGRITY_JSON -Raw | ConvertFrom-Json
$j.'app.asar'.hash = $NEW_HASH
$j | ConvertTo-Json -Depth 50 | Set-Content $INTEGRITY_JSON -Encoding utf8
```

**情况 B：不存在，hash 嵌在 PE 资源里**

需要用 `rcedit`（`npm i -g rcedit`）或 `Resource Hacker` 修改 `Claude.exe` 的 ASAR_INTEGRITY 资源段。这种情况罕见，本 skill 默认 §11 的方式（绕开严格校验）更省心：

```powershell
# 软回避：把 fuse 关掉
# 仅对 Electron 22+ 有效，且需要在 Claude.exe 上跑 electron-fuses
npx -y @electron/fuses --version  # 确认可用
npx -y @electron/fuses write `
  --app-path "$APP\Claude.exe" `
  --fuse "EnableEmbeddedAsarIntegrityValidation" `
  --value false
```

      注：
      • 改 fuse 会让 Windows Defender / SmartScreen 提示文件被改，是预期行为。
      • 改完 fuse 后 `Claude.exe` 的 Authenticode 签名会失效（fuse 修改本质是 patch 二进制），见 §13。

------

## 11. Patch Code 前端 Effort 限制

### 11.1 放开 modelSupportsMaxEffort

```powershell
$EFFORT_FILE = (Get-ChildItem "$APP\resources\ion-dist\assets\v1\c*.js" |
                Where-Object { (Get-Content $_ -Raw) -match 'modelSupportsMaxEffort|opus-4-6|opus-4-7' } |
                Select-Object -First 1).FullName

Copy-Item $EFFORT_FILE "$EFFORT_FILE.before-effort-max-patch.$TS"

$src = Get-Content $EFFORT_FILE -Raw
# 把对 opus-4-6 / opus-4-7 的限制函数改为永远返回 true
$src = $src -replace `
  'r=function\(e,t\)\{const s=e\.toLowerCase\(\);return!\(\!s\.includes\("opus-4-6"\)&&!s\.includes\("opus-4-7"\)\)\|\|!!t&&!\(s\.includes\("haiku"\)\|\|s\.includes\("sonnet"\)\|\|s\.includes\("opus"\)\)\}\(t,n\)', `
  'r=function(e,t){return!0}(t,n)'
Set-Content -Path $EFFORT_FILE -Value $src -NoNewline
```

### 11.2 放开远端 effort 环境门控

定位 envSupportsEffort 文件：

```powershell
$QUEUE_FILE = (Get-ChildItem "$APP\resources\ion-dist\assets\v1\c*.js" |
               Where-Object { (Get-Content $_ -Raw) -match 'envSupportsEffort' } |
               Select-Object -First 1).FullName

$src = Get-Content $QUEUE_FILE -Raw
$src = $src -replace `
  'fi="local"===Qa\|\|"ssh"===Qa', `
  'fi="local"===Qa||"ssh"===Qa||"anthropic_cloud"===Qa||"byoc"===Qa||"pool"===Qa'
# 把 effort 参数补进创建会话调用
$src = $src -replace `
  'mcpConfig:eo,coordinatorMode', `
  'mcpConfig:eo,effort:hi,coordinatorMode'
Set-Content -Path $QUEUE_FILE -Value $src -NoNewline
```

      注：
      • 混淆变量名 `fi`、`Qa`、`hi`、`eo` 在不同版本会变。如果上面的正则匹配不到，先用 `Select-String` 按文案重新定位，再调整正则。
      • `apply_patches.ps1` 帮你做了一遍这种 fallback。

------

## 12. 清理 Local Storage 和缓存

```powershell
$BASE = "$env:APPDATA\Claude-3p"
$TS   = Get-Date -Format yyyyMMddHHmmss
$LDB  = "$BASE\Local Storage\leveldb"

if (Test-Path $LDB) {
  Rename-Item $LDB "$LDB.before-sticky-reset.$TS"
}
New-Item -ItemType Directory -Force $LDB | Out-Null

foreach ($d in @("Cache","Code Cache","GPUCache")) {
  $p = Join-Path $BASE $d
  if (Test-Path $p) { Remove-Item $p -Recurse -Force }
  New-Item -ItemType Directory -Force $p | Out-Null
}
```

------

## 13. Authenticode 签名（可选）

**Windows 上不签名也能跑**，只是 SmartScreen 第一次启动会警告"未识别的应用"，点"更多信息 → 仍要运行"即可。

如果你有 EV cert：

```powershell
$CERT = "C:\path\to\cert.pfx"
$PASS = "<password>"
$EXES = @(
  "$APP\Claude.exe",
  "$env:LOCALAPPDATA\Claude-3p\Claude.exe",
  "$env:LOCALAPPDATA\Claude-3p\Update.exe"  # 如果你不删它的话，见 §14
)
foreach ($e in $EXES) {
  signtool sign /f $CERT /p $PASS /fd SHA256 /tr "http://timestamp.digicert.com" /td SHA256 $e
}
```

没有 EV cert 时：

```powershell
# 移除 Zone.Identifier ADS，避免 SmartScreen 强警告
Get-ChildItem $APP -Recurse | Unblock-File
Get-ChildItem "$env:LOCALAPPDATA\Claude-3p" -Recurse | Unblock-File
```

      注：
      • 千万不要用社区共享 cert 签 fork，会被 Defender 标记为已知滥用证书。
      • 自签 cert 也行，但你得在系统的"受信任的发布者"里装一遍证书，否则 SmartScreen 一样警告。

------

## 14. 禁用自动更新

最稳的双保险：

```powershell
# A. 删除 Squirrel 的 updater（最直接）
$UPDATE = "$env:LOCALAPPDATA\Claude-3p\Update.exe"
if (Test-Path $UPDATE) {
  Rename-Item $UPDATE "$UPDATE.disabled"
}

# B. 把更新清单指向不可达地址
$RELEASES = "$env:LOCALAPPDATA\Claude-3p\packages\RELEASES"
if (Test-Path $RELEASES) {
  Move-Item $RELEASES "$RELEASES.disabled"
}

# C. provider 配置 JSON 里加 disableAutoUpdates: true（§3 已加；best-effort，不依赖它）
```

不要改 hosts。Squirrel 会针对失败的更新尝试反复重试，hosts 拦截让日志非常脏。直接禁 Update.exe 干净得多。

------

## 15. 拉一次 /v1/models 把模型清单填回 inferenceModels

```powershell
.\scripts\list_models.ps1 -BaseUrl "https://api.meding.site" -ApiKey "<your-key>"
```

脚本会按 §provider.md 的规则探针端点路径、解析返回、按 gpt / gemini / deepseek / claude 分组，并打印一段可直接粘贴的 JSON：

```json
"inferenceModels": [
  { "name": "gpt-5.4",                  "supports1m": false },
  { "name": "gpt-5-mini",               "supports1m": false },
  { "name": "gemini-3-pro-preview",     "supports1m": true  },
  { "name": "gemini-3-flash-preview",   "supports1m": true  },
  { "name": "deepseek-4-pro",           "supports1m": true  },
  { "name": "deepseek-4-flash",         "supports1m": true  }
]
```

> 上面是 meding.site 2026-05 实测模型名。**如果换中转一定要跑 `list_models.ps1` 重新拉，不要直接抄。**

把这段贴回 §3 的 provider 配置 JSON。

------

## 16. 启动验证

```powershell
Start-Process "$env:LOCALAPPDATA\Claude-3p\Claude.exe"
Start-Sleep -Seconds 10
Get-Process -Name "Claude" -ErrorAction SilentlyContinue
```

如果 Claude 进程持续运行（不是 1-2 秒就退出），主进程启动成功。

确认没有崩溃记录：

```powershell
Get-EventLog -LogName Application -Source "Application Error" -Newest 5 |
  Where-Object { $_.Message -match "Claude" }
```

------

## 17. Patch 验证

```powershell
.\scripts\verify_claude_fork.ps1 -InstallDir "$env:LOCALAPPDATA\Claude-3p\app-1.6608.2"
```

期望输出（关键几行）：

```text
== app.asar checks ==
provider_health_bypass     : True
picker_filter_removed      : True
== effort patch ==
effort max patch           : True
remote effort env patched  : True
== provider config ==
inferenceProvider          : gateway
gatewayBaseUrl             : https://api.meding.site
models                     : gpt-5.4; gpt-5-mini; gemini-3-pro-preview; gemini-3-flash-preview; deepseek-4-pro; deepseek-4-flash
```

------

## 18. Windows 专属踩坑

### 18.1 Squirrel 自动更新会把你的 fork 覆盖回去

如果 §14 没做或 `Update.exe.disabled` 被还原，下次 Claude Desktop 启动会自动检查更新，把整个 `app-<version>\` 替换成新版本，**你的 patch 全没了**。

防范：

1. §14 双保险都做
2. 把 fork 装在原版**完全不同的目录**（如 `Claude-3p\` 而非 `AnthropicClaude\`），Squirrel 的更新器找不到自己的安装清单，就不会乱搞
3. 定期跑 `verify_claude_fork.ps1`，如果发现 patch 不在了就是被覆盖了

### 18.2 Windows Defender 把改过的 Claude.exe 删了

如果 §10 用了 fuse 关闭 integrity 校验，`Claude.exe` 二进制被改，Defender 可能直接隔离。处理：

```powershell
# 把 fork 目录加入 Defender 排除
Add-MpPreference -ExclusionPath "$env:LOCALAPPDATA\Claude-3p"
```

需要 PowerShell 管理员权限。

### 18.3 SmartScreen 警告反复弹

如果每次启动都被警告，说明 §13 的 Unblock-File 没生效。检查：

```powershell
Get-Item "$env:LOCALAPPDATA\Claude-3p\Claude.exe" -Stream Zone.Identifier -ErrorAction SilentlyContinue
```

如果还有 Zone.Identifier 流就 `Unblock-File` 一遍。

### 18.4 Electron 启动报 "EBUSY: resource busy or locked"

通常是后台还有残留 Claude.exe 进程或 Helper 进程占用文件：

```powershell
Get-Process -Name "Claude*" | Stop-Process -Force
Get-Process -Name "electron*" | Stop-Process -Force
```

### 18.5 路径含空格 / 中文导致 npx 命令失败

Windows 用户名是中文时，`%LocalAppData%` 路径会含中文，`npx @electron/asar` 偶尔解码失败。临时做法：

```powershell
$WORK = "C:\temp\claude-fork-$TS"  # 用纯 ASCII 路径
```

------

## 19. 回滚

### 19.1 整 fork 回滚

```powershell
Remove-Item "$env:LOCALAPPDATA\Claude-3p" -Recurse -Force
Rename-Item "$env:LOCALAPPDATA\Claude-3p.before-3p-patch.<timestamp>" "$env:LOCALAPPDATA\Claude-3p"
```

### 19.2 单 app.asar 回滚

```powershell
$ASAR = "$env:LOCALAPPDATA\Claude-3p\app-1.6608.2\resources\app.asar"
Move-Item "$ASAR.before-3p-patch.<timestamp>" $ASAR -Force
```

回滚后如果 §10 改过 integrity，要把对应的 hash 也回滚。

### 19.3 启用回更新

```powershell
$UPDATE = "$env:LOCALAPPDATA\Claude-3p\Update.exe"
if (Test-Path "$UPDATE.disabled") {
  Move-Item "$UPDATE.disabled" $UPDATE
}
```

------

## 20. 最终状态

当前 fork：

```text
%LocalAppData%\Claude-3p\app-1.6608.2\
```

关键状态：

```text
Display name (shortcut)   : Claude 3P
AppUserModelID            : com.anthropic.claudefordesktop  (未改)
Update.exe                : 已禁用
app.asar                  : 已 patch (health + picker)
ion-dist effort           : 已 patch (max + envSupportsEffort)
provider                  : https://api.meding.site
models                    : gpt-* / gemini-* / deepseek-*
locale                    : zh-CN
```

------

## 21. 关于网关的说明

本次没有创建本地网关，请求路径是：

```
Claude Desktop 3P fork  ─POST /v1/messages─>  https://api.meding.site
                                                       │
                                                       └─ 协议翻译 ─> OpenAI / Gemini / DeepSeek
```

如果你想要自托管翻译网关（LiteLLM）替代 meding.site，见 `references/providers.md` §8。
