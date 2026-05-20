# Claude Desktop for macOS 改包全流程

本文记录在 macOS 上 fork Claude Desktop、patch 客户端、配通 `https://api.meding.site` 中转、汉化、禁更新、并完成启动验证的完整流程。

实操环境：

- 原版 App：`/Applications/Claude.app`
- Fork App：`$HOME/Applications/Claude-3p.app`
- Claude Desktop 版本：1.6608.2（**chunk 文件名和混淆函数名随版本变化，按特征字符串定位**）
- 用户数据目录：`$HOME/Library/Application Support/Claude-3p`
- 中转网关：`https://api.meding.site`
- 默认启用的模型：GPT / Gemini / DeepSeek 三家（实际清单由 `/v1/models` 决定）

      注：
      • 本文所有命令默认在 macOS zsh 下执行。
      • 原版 `/Applications/Claude.app` 不做修改，只复制出 fork。
      • 混淆后的函数名和前端 JS 文件名会随 Claude Desktop 版本变化，必须按特征字符串定位。
      • Windows 流程见 `references/full-process-windows.md`。

------

## 1. 修改目标

- 保留 Claude Desktop 原有 3P gateway 请求链路，不新增本地代理、反代或 hosts 映射
- 允许 `inferenceModels` 中配置非 Anthropic catalog 模型
- 让模型选择器同时显示 `gpt-*` / `gemini-*` / `deepseek-*`
- 让 Claude Code 中第三方模型的 effort 菜单显示并允许选择 `Max`
- 通过 Anthropic-compatible 中转 `https://api.meding.site` 接通三家
- 修改后通过 macOS 启动、签名和 Electron asar integrity 校验

------

## 2. 前提条件

- 已安装 Claude Desktop
- 已配置或愿意新建 Claude Desktop 3P gateway
- 已安装 Node.js 和 `npx`
- 当前用户对 `$HOME/Applications` 有写权限
- Claude Desktop 未在运行

检查 Claude 是否仍在运行：

```bash
pgrep -fl 'Claude|claude' || true
```

------

## 3. 配置 3P Gateway

详细配置语义和 `inferenceModels` 自动识别见 `references/providers.md`。最小可工作配置：

```json
{
  "inferenceProvider": "gateway",
  "inferenceGatewayBaseUrl": "https://api.meding.site",
  "inferenceGatewayApiKey": "<redacted>",
  "inferenceModels": [],
  "disableAutoUpdates": true
}
```

> **`disableAutoUpdates` 字段未经实测，仅 best-effort**。真正可靠的 macOS 禁更新机制要走 Squirrel.Mac patch（见 §14 之后处理）；详见 `providers.md` 里的说明。

存放路径：

```text
$HOME/Library/Application Support/Claude-3p/configLibrary/<provider-config-id>.json
```

      注：
      • `gateway` 是 Claude Desktop 自带的 3P provider 类型，不是本次新增的本地网关。
      • `inferenceGatewayApiKey` 不要写入教程、截图或日志。
      • `inferenceModels` 先留空，§15 用 `list_models.sh` 自动填三家模型。

------

## 4. Fork Claude App

```bash
SRC="/Applications/Claude.app"
DEST="$HOME/Applications/Claude-3p.app"
TS="$(date +%Y%m%d%H%M%S)"

if [ -e "$DEST" ]; then
  mv "$DEST" "$DEST.before-3p-patch.$TS"
fi

ditto "$SRC" "$DEST"
```

------

## 5. 修改 Info.plist 显示名

```bash
APP="$HOME/Applications/Claude-3p.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Claude-3P' "$APP/Contents/Info.plist"
```

保留：

```text
CFBundleIdentifier = com.anthropic.claudefordesktop
CFBundleName       = Claude
```

      注：不修改 `CFBundleIdentifier`。Electron Helper、userData 路径和内部逻辑都依赖原有标识。

------

## 6. 解包 app.asar

```bash
APP="$HOME/Applications/Claude-3p.app"
TS="$(date +%Y%m%d%H%M%S)"
WORK="$(mktemp -d /tmp/claude-fork.XXXXXX)"

cp "$APP/Contents/Resources/app.asar" \
   "$APP/Contents/Resources/app.asar.before-3p-patch.$TS"

npx -y @electron/asar extract "$APP/Contents/Resources/app.asar" "$WORK"
echo "$WORK"
```

主要修改文件：

```text
$WORK/.vite/build/index.js
```

------

## 7. Patch 3P Provider 健康检查

### 7.1 定位代码

```bash
rg -n 'inferenceModels: configured model' "$WORK/.vite/build/index.js"
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

### 7.2 修改代码

改为：

```js
function vzt(e,A){return null}
```

作用：

- 不再因为 `gpt-*` / `gemini-*` / `deepseek-*` 不是 Anthropic catalog 模型而判定 3P provider 配置坏掉。
- 避免健康检查阶段直接报 `inferenceModels: configured model ... is not an Anthropic model`。

------

## 8. Patch 模型 Picker 二次过滤

### 8.1 定位代码

```bash
rg -n 'filter\(.\=>YLA\(e,..id\).ok\)' "$WORK/.vite/build/index.js"
```

本次版本中的函数等价于：

```js
function lai(e,A,t){
  let i;
  if(A&&A.length>0){
    const r=new Map((t??[]).map(n=>[n.id,n]));
    i=A.map(n=>r.get(n.name)??{id:n.name,name:Nni(n.name)})
  }else i=t??[];
  return e?i.filter(r=>YLA(e,r.id).ok):i
}
```

### 8.2 修改代码

把末尾：

```js
return e?i.filter(r=>YLA(e,r.id).ok):i
```

改为：

```js
return i
```

作用：

- 即使 provider health 通过，旧逻辑仍会在 UI 模型列表中过滤非 Claude 模型。
- 修改后，`inferenceModels` 中配置的 GPT / Gemini / DeepSeek 模型都可以进入模型选择器。

------

## 9. 重新打包 app.asar

```bash
npx -y @electron/asar pack "$WORK" "$APP/Contents/Resources/app.asar"
```

      注：
      • 重新 pack 后，`app.asar` 文件内容变化，必须更新 `Info.plist` 中的 `ElectronAsarIntegrity`（§11）。
      • 不能用 `shasum -a 256 app.asar` 的结果填入 `ElectronAsarIntegrity`，会导致 Electron 启动时 integrity check 失败。

------

## 10. Patch Code 前端 Effort 限制

### 10.1 定位 effort 文件

```bash
EFFORT_FILE="$(rg -l 'modelSupportsMaxEffort|opus-4-6|opus-4-7' \
  "$APP/Contents/Resources/ion-dist/assets/v1" | head -n1)"
echo "$EFFORT_FILE"
```

本次版本中定位到：

```text
$HOME/Applications/Claude-3p.app/Contents/Resources/ion-dist/assets/v1/c11959232-h_zsw3wI.js
```

### 10.2 备份并修改

```bash
TS="$(date +%Y%m%d%H%M%S)"
cp "$EFFORT_FILE" "$EFFORT_FILE.before-effort-max-patch.$TS"
```

      注：备份文件不要长期放在 `.app` 包内部。重签完成后，应移到包外目录保存，否则会破坏 app bundle 的 sealed resources 校验。

### 10.3 放开 Max 选项过滤

原判断：

```js
r=function(e,t){
  const s=e.toLowerCase();
  return!(!s.includes("opus-4-6")&&!s.includes("opus-4-7"))
    ||!!t&&!(s.includes("haiku")||s.includes("sonnet")||s.includes("opus"))
}(t,n)
```

改为：

```js
r=function(e,t){return!0}(t,n)
```

### 10.4 放开远端 effort 环境门控

定位 envSupportsEffort 文件：

```bash
QUEUE_FILE="$(rg -l 'envSupportsEffort' \
  "$APP/Contents/Resources/ion-dist/assets/v1" | head -n1)"
echo "$QUEUE_FILE"
```

本次版本中定位到：`cda40c939-DeExI1vC.js`。

原逻辑等价于：

```js
fi="local"===Qa||"ssh"===Qa
{section:pi,spawnEffort:hi}=ht({modelId:Tn,envSupportsEffort:fi})
```

改为：

```js
fi="local"===Qa||"ssh"===Qa||"anthropic_cloud"===Qa||"byoc"===Qa||"pool"===Qa
{section:pi,spawnEffort:hi}=ht({modelId:Tn,envSupportsEffort:fi})
```

同时，把远端创建会话时的调用从：

```js
Zi({...,model:e?void 0:Tn,mcpConfig:eo,coordinatorMode:...})
```

改为：

```js
Zi({...,model:e?void 0:Tn,mcpConfig:eo,effort:hi,coordinatorMode:...})
```

作用：

- 让当前 Claude Code 入口在 `anthropic_cloud`、`byoc`、`pool` 这类远端环境也显示 effort 菜单。
- 让用户在该入口中选择的 effort 档位真正随会话创建请求一起传出。

------

## 11. 更新 ElectronAsarIntegrity

Electron 的 asar integrity 不是普通 SHA256。本次踩坑中，普通 `shasum -a 256 app.asar`：

```text
b0fbc8d5f0da5f028aa7cf910864612f2ee5fd35b930ee2b956126979cd87402
```

但 Electron 实际期望的 asar integrity hash 为：

```text
632288785a7cd5d13d5668ad335603cba6acd746498d57da1c1f76ceb35352db
```

修正命令：

```bash
APP="$HOME/Applications/Claude-3p.app"
ASAR_INTEGRITY="632288785a7cd5d13d5668ad335603cba6acd746498d57da1c1f76ceb35352db"

/usr/libexec/PlistBuddy \
  -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $ASAR_INTEGRITY" \
  "$APP/Contents/Info.plist"
```

若不知道正确 hash，让 Electron 自己报：

```bash
env ELECTRON_ENABLE_LOGGING=1 ELECTRON_ENABLE_STACK_DUMPING=1 \
  "$APP/Contents/MacOS/Claude" 2>&1 | sed -n '1,80p'
```

错误日志格式：

```text
Integrity check failed for asar archive (<plist 中的 hash> vs <Electron 实际计算出的 hash>)
```

`vs` 后面的值就是要写回 plist 的新 hash。

      注：
      • `codesign --verify` 通过不代表 asar integrity 正确。
      • asar integrity 错误会导致 Electron 早期 SIGTRAP 崩溃。

------

## 12. 清理 Local Storage Sticky Model

```bash
BASE="$HOME/Library/Application Support/Claude-3p"
TS="$(date +%Y%m%d%H%M%S)"
LEVELDB="$BASE/Local Storage/leveldb"

if [ -e "$LEVELDB" ]; then
  mv "$LEVELDB" "$LEVELDB.before-sticky-reset.$TS"
fi

mkdir -p "$LEVELDB"
```

------

## 13. 清理 Electron 缓存

```bash
BASE="$HOME/Library/Application Support/Claude-3p"

for d in Cache "Code Cache" GPUCache; do
  rm -rf "$BASE/$d"
  mkdir -p "$BASE/$d"
done
```

      注：
      • 这不影响 API key、provider 配置和会话配置。
      • 清理前确保 Claude Desktop 已退出。

------

## 14. 重新签名

### 14.1 签名原则

本机没有可用 Developer ID 签名身份时使用 ad-hoc 签名：

```bash
codesign --sign -
```

关键点：

- 不要直接用 `codesign --deep --entitlements 主 App entitlements` 粗暴签所有内容。
- 主 App 和 Helper App 需要加：

```text
com.apple.security.cs.disable-library-validation = true
```

### 14.2 提取并处理 entitlements

```bash
make_app_entitlements() {
  local src="$1"
  local out="$2"

  codesign -d --entitlements :- "$src" > "$out" 2>/dev/null || true

  if ! plutil -lint "$out" >/dev/null 2>&1; then
    cat > "$out" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict></dict></plist>
EOF
  fi

  /usr/libexec/PlistBuddy -c 'Delete :com.apple.application-identifier' "$out" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.team-identifier' "$out" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$out" >/dev/null 2>&1 || \
    /usr/libexec/PlistBuddy -c 'Set :com.apple.security.cs.disable-library-validation true' "$out"
}
```

### 14.3 签名顺序

必须从内到外签：

- native `.node` 模块
- dylib 和 helper executable
- framework
- Helper `.app`
- 最外层 `Claude-3p.app`

本次涉及（具体路径按你的版本可能略有差异）：

```text
app.asar.unpacked/node_modules/@ant/claude-native/claude-native-binding.node
app.asar.unpacked/node_modules/@ant/claude-swift/build/Release/swift_addon.node
app.asar.unpacked/node_modules/@ant/claude-swift/build/Release/computer_use.node
app.asar.unpacked/node_modules/node-pty/build/Release/pty.node
app.asar.unpacked/node_modules/node-pty/build/Release/spawn-helper
Electron Framework.framework/Versions/A/Libraries/libEGL.dylib
Electron Framework.framework/Versions/A/Libraries/libvk_swiftshader.dylib
Electron Framework.framework/Versions/A/Libraries/libGLESv2.dylib
Electron Framework.framework/Versions/A/Libraries/libffmpeg.dylib
Electron Framework.framework/Versions/A/Helpers/chrome_crashpad_handler
ReactiveObjC.framework/Versions/A
Squirrel.framework/Versions/A/Resources/ShipIt
Squirrel.framework/Versions/A
Mantle.framework/Versions/A
Electron Framework.framework/Versions/A
Contents/Helpers/disclaimer
Contents/Helpers/chrome-native-host
Claude Helper.app
Claude Helper (Renderer).app
Claude Helper (GPU).app
Claude Helper (Plugin).app
Claude-3p.app
```

### 14.4 验证签名

```bash
APP="$HOME/Applications/Claude-3p.app"
codesign --verify --deep --strict --verbose=1 "$APP"
```

期望输出：

```text
$HOME/Applications/Claude-3p.app: valid on disk
$HOME/Applications/Claude-3p.app: satisfies its Designated Requirement
```

------

## 15. 拉一次 /v1/models 把模型清单填回 inferenceModels

```bash
bash scripts/list_models.sh "https://api.meding.site" "<your-key>"
```

脚本会打印一段可直接粘贴的 `inferenceModels` JSON（meding.site 2026-05 实测样例）：

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

把这段粘回 §3 的 provider 配置 JSON。

------

## 16. 移除隔离属性

```bash
APP="$HOME/Applications/Claude-3p.app"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
```

------

## 17. 启动验证

```bash
open -n "$HOME/Applications/Claude-3p.app"
sleep 8
pgrep -fl 'Claude|claude'
```

本次确认主进程和 Helper 进程均已运行。

确认没有新的 crash report：

```bash
ls -1t ~/Library/Logs/DiagnosticReports/Claude-*.ips 2>/dev/null | head -n 5
```

------

## 18. Patch 验证

```bash
bash scripts/verify_claude_fork.sh "$HOME/Applications/Claude-3p.app"
```

期望关键输出：

```text
provider_health_bypass               : true
picker_filter_removed                : true
effort_max_patched                   : true
remote_effort_env_patched            : true
default_locale_zh                    : true
provider                             : gateway
gatewayBaseUrl                       : https://api.meding.site
models                               : gpt-5.4; gpt-5-mini; gemini-3-pro-preview; gemini-3-flash-preview; deepseek-4-pro; deepseek-4-flash
```

UI 实测进入 Claude Code 页面后：

```text
模型按钮显示    : Dee***** 4 Flash · Medium (示例)
打开模型菜单    : 同时出现 gpt-*, gemini-*, deepseek-* 三类
effort 分组    : Low / Medium / High / Max
选择 Max 后    : 按钮变为 ... · Max
```

------

## 19. 本次踩坑记录

### 19.1 codesign 通过但 App 仍无法启动

`codesign --verify --deep --strict` 通过，但 `open -n` 失败或启动后立刻崩溃。

结论：

- `codesign --verify` 只能证明签名结构有效
- 它不能证明 Electron asar integrity 正确
- 它也不能证明 hardened runtime 加载 framework 时不会被 library validation 拦截

### 19.2 Library Validation 拦截 Electron Framework

崩溃报告中出现：

```text
Library not loaded: @rpath/Electron Framework.framework/Electron Framework
Reason: code signature ... not valid for use in process:
mapping process and mapped file (non-platform) have different Team IDs
```

修复：主 App 和 Helper App entitlements 中加入 `com.apple.security.cs.disable-library-validation = true`。

### 19.3 不要把主 App entitlements 粗暴套给所有组件

正确做法：

- 从原版对应组件提取 entitlements
- 删除 `com.apple.application-identifier` 和 `com.apple.developer.team-identifier`
- 对 App bundle 增加 `disable-library-validation`
- 从内到外逐个签名

### 19.4 ElectronAsarIntegrity 不能填普通 SHA256

错误做法：

```bash
shasum -a 256 "$APP/Contents/Resources/app.asar"
```

会得到错误的 hash 值，导致：

```text
Integrity check failed for asar archive
```

正确做法：用 Electron 报出的 asar integrity hash（见 §11）。

### 19.5 Crash Report 比 open 报错更有用

`open` 可能只给出 `Launch failed / Unknown error: 153`。真正原因要看：

```text
~/Library/Logs/DiagnosticReports/Claude-*.ips
```

或：

```bash
env ELECTRON_ENABLE_LOGGING=1 ELECTRON_ENABLE_STACK_DUMPING=1 \
  "$APP/Contents/MacOS/Claude" 2>&1 | sed -n '1,160p'
```

------

## 20. 本次生成的备份

```text
$HOME/Applications/Claude-3p.app/Contents/Resources/app.asar.before-3p-patch.<timestamp>
$HOME/Applications/Claude-3p.app/Contents/Resources/ion-dist/assets/v1/c11959232-h_zsw3wI.js.before-effort-max-patch.<timestamp>
$HOME/Library/Application Support/Claude-3p/Local Storage/leveldb.before-sticky-reset.<timestamp>
```

------

## 21. 回滚

### 21.1 回滚整个 fork

```bash
rm -rf "$HOME/Applications/Claude-3p.app"
```

原版 `/Applications/Claude.app` 未修改。

### 21.2 回滚 app.asar

```bash
APP="$HOME/Applications/Claude-3p.app"
cp "$APP/Contents/Resources/app.asar.before-3p-patch.<timestamp>" \
   "$APP/Contents/Resources/app.asar"
```

回滚后仍需重新更新 `ElectronAsarIntegrity` 并重签名。

### 21.3 回滚 Local Storage

```bash
BASE="$HOME/Library/Application Support/Claude-3p"
rm -rf "$BASE/Local Storage/leveldb"
mv "$BASE/Local Storage/leveldb.before-sticky-reset.<timestamp>" \
   "$BASE/Local Storage/leveldb"
```

------

## 22. 最终状态

当前 fork：

```text
$HOME/Applications/Claude-3p.app
```

关键状态：

```text
CFBundleDisplayName       = Claude-3P
CFBundleIdentifier        = com.anthropic.claudefordesktop
CFBundleName              = Claude
ElectronAsarIntegrity hash= 632288785a7cd5d13d5668ad335603cba6acd746498d57da1c1f76ceb35352db
```

签名状态：

```text
Signature                                       = adhoc
Runtime                                         = enabled
com.apple.security.cs.allow-jit                 = true
com.apple.security.cs.disable-library-validation = true
```

provider 状态：

```text
inferenceGatewayBaseUrl   = https://api.meding.site
inferenceModels           = gpt-5.4 / gpt-5-mini / gemini-3-pro-preview / gemini-3-flash-preview / deepseek-4-pro / deepseek-4-flash
locale                    = zh-CN
disableAutoUpdates        = true   (best-effort，真正的禁更新靠 Squirrel.Mac 处理)
```

验证结果：

```text
codesign --verify --deep --strict : passed
app.asar health patch              : true
app.asar picker filter removed     : true
effort max patch                   : true
remote effort env patch            : true
Claude-3p.app                      : started successfully
```

------

## 23. 关于网关的说明

本次没有创建本地网关。请求路径仍然是 Claude Desktop 3P 配置中的：

```json
{
  "inferenceProvider": "gateway",
  "inferenceGatewayBaseUrl": "https://api.meding.site"
}
```

Claude Desktop 按其内置 custom 3P gateway provider 逻辑请求 `https://api.meding.site/v1/messages`，由网关在服务端做 OpenAI / Gemini / DeepSeek 协议翻译。

本次 patch 只放开客户端限制：

- 不再要求 `inferenceModels` 必须是 Anthropic catalog 中的 `claude-*`
- 不再在模型选择器中过滤非 Claude 模型
- 不再让 Claude Code UI 在当前入口里隐藏第三方模型的 effort 菜单和 `Max` 选项
- 重新签名并修复 macOS / Electron 启动校验

没有新增本地服务，没有改 hosts，没有加反代。

如果你想用自托管 LiteLLM 替代 meding.site，配置见 `references/providers.md` §8。
