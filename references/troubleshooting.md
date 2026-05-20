# 实战排坑记录（Mac / Win 两平台）

## 跨平台通用

### 1. 身份相关改动最危险

最稳的 fork 身份配置：

| 平台 | 内部标识 | 内部名 | 显示名（**唯一建议改的**） |
|---|---|---|---|
| macOS | `CFBundleIdentifier = com.anthropic.claudefordesktop` | `CFBundleName = Claude` | `CFBundleDisplayName` |
| Windows | `AppUserModelID = com.anthropic.claudefordesktop` | `Claude.exe` | Start Menu / 快捷方式名 |

Helper 进程、userData 路径、内部 IPC 都默认依赖官方身份。  
反复改 bundle identity 或安装路径，最容易把本来可用的包改成启动不稳定的包。

### 2. 签名/校验通过 ≠ 真的没问题

至少要做两步验证：

- macOS：`codesign --verify --deep --strict <app>` + 实际启动
- Windows：`Get-AuthenticodeSignature <exe>` + 实际启动 + 看事件查看器

如果 app 打开后很快闪退，按运行时回归处理，不要因为校验通过就误判成"已经修好"。

### 3. 备份文件绝不能留在 fork 内

不要把下面这类文件放进包/install 目录内部：

- `*.before-*`
- `*.bak`
- 临时 JS 备份
- 临时 plist 备份

这些文件会把签名（Mac）/ Authenticode（Win）和包结构一起弄脏。  
正确做法：统一放到 fork 外部的备份目录。

### 4. ASAR Integrity 不是普通文件 SHA256

- **macOS**：`Info.plist:ElectronAsarIntegrity:Resources/app.asar:hash`
- **Windows**：`resources\electron-asar-integrity.json` 或嵌入 `Claude.exe` 的 PE 资源

不要把它理解成"改完 `app.asar` 以后顺手跑个 `shasum` 写回去"。

更稳的做法：

1. 重新打包 `app.asar`
2. 启动 app 二进制
3. 如果 Electron 真报 integrity mismatch，再从日志/事件查看器里拿它期望的 hash
4. 把那个值写回正确位置

如果没有报 mismatch，就不要为了"看起来完整"去强改这个值。

### 5. 汉化是分层的，不是一份 json 就够

详见 `i18n-localization.md`。简记：

- 先补层 1（顶层 locale json）
- 再补层 3（ion-dist/i18n，**大头**）
- macOS 才有的层 2（lproj）按需补
- 最后才碰层 4（chunk 硬编码）

### 6. 用干净底包重建是可行的，但迁移必须完整

如果 fork 已经被改脏、改乱、改到闪退，用原版 app 重做一个干净底包，通常比抢救坏包更省时间。

重建时必须有意识地迁回：

- patch 过的 `app.asar`
- 顶层语言资源
- `ion-dist/i18n/zh-CN*.json`
- 之前已经做好的 renderer chunk 定点补丁（最容易丢的就是这一类）

### 7. effort 支持不是一个开关

实操里要分清两层：

1. effort 控件本身会不会显示（envSupportsEffort）
2. `Max` / `Extra high` 这些档位会不会被前端过滤（modelSupportsMaxEffort）

所以不要轻易把某次 patch 描述成"恢复了最大思考模式"或"所有页面都支持 Max 了"，除非已经确认：

- 当前页面链路真的显示 effort 控件
- 当前创建流程真的把对应参数传了下去

并且：**上游中转/原生 API 不识别这个字段时，客户端再 patch 也没用**（典型例子：GPT-5 走 Anthropic 协议中转时，OpenAI 不吃 `thinking` 字段）。

### 8. "合格的修改包"标准应该现实一点

对个人使用来说，一个 fork 满足下面这些就算合格：

- 能稳定启动
- 签名 / Authenticode 校验通过
- 3P gateway 能正常走到目标模型
- 三家（GPT / Gemini / DeepSeek）至少各点通一个
- 更新行为符合预期
- 汉化达到自己的可接受程度

这不等于"可以大规模分发"的正式成品。

### 9. 版本漂移是常态，不是例外

Claude Desktop 每次升级后，最不稳定的通常是：

- chunk 文件名
- 混淆函数名（`vzt`、`YLA`、`lai` 等）
- 某些前端局部实现

稳定的定位方式是搜：

- 可见报错文案（"inferenceModels: configured model"）
- 配置字段名（`inferenceGatewayBaseUrl`）
- UI 文案
- 相关特征字符串

不要把旧版本里的某个函数名当成长期真理。

------

## macOS 专属

### M1. Library Validation 拦 Electron Framework

ad-hoc 签名没有 Team ID，hardened runtime 会拦：

```text
Library not loaded: @rpath/Electron Framework.framework/Electron Framework
Reason: code signature ... not valid for use in process:
mapping process and mapped file (non-platform) have different Team IDs
```

修复：主 App 和 Helper App 都加 `com.apple.security.cs.disable-library-validation = true`。

### M2. 不要 `codesign --deep --entitlements 主App.plist`

会把主 App entitlements 传染到 Helper / Framework。  
正确做法：每个组件单独提 entitlements、删 team-identifier、按内到外顺序签。  
详见 `full-process-mac.md` §14。

### M3. quarantine 隔离属性

```bash
xattr -dr com.apple.quarantine "$APP"
```

复制或修改后的 app 几乎一定会有这个属性，必须清。

### M4. Crash report 比 `open` 报错有用得多

`open` 通常只给 `Launch failed / Unknown error: 153`。真正原因看：

```text
~/Library/Logs/DiagnosticReports/Claude-*.ips
```

或：

```bash
env ELECTRON_ENABLE_LOGGING=1 ELECTRON_ENABLE_STACK_DUMPING=1 \
  "$APP/Contents/MacOS/Claude"
```

------

## Windows 专属

### W1. Squirrel 会自动把 fork 覆盖掉

如果不禁用 `Update.exe`，下次 Claude Desktop 启动会自动检查更新并替换整个 `app-<version>\` 目录，patch 全没。  
**真正可靠的是删 `Update.exe` + 改坏 `app-update.yml`**。provider 配置里的 `disableAutoUpdates: true` 是 best-effort（字段名未经全版本实测），可以加但别只依赖它。  
详见 `full-process-windows.md` §14。

### W2. Defender 误删 patch 过的 Claude.exe

如果 §10 用 `@electron/fuses` 关掉 integrity 校验，二进制被改，Defender 可能直接隔离。  
处理：

```powershell
Add-MpPreference -ExclusionPath "$env:LOCALAPPDATA\Claude-3p"
```

### W3. SmartScreen 反复警告

`Unblock-File` 没把 fork 内所有文件的 Zone.Identifier 流清掉。处理：

```powershell
Get-ChildItem "$env:LOCALAPPDATA\Claude-3p" -Recurse | Unblock-File
```

### W4. 中文用户名路径导致 `npx @electron/asar` 解码失败

Windows 用户名是中文时，`%LocalAppData%` 路径有中文字符，`@electron/asar` 在极少数情况下会因路径编码出错。临时做法：

```powershell
$WORK = "C:\temp\claude-fork-$TS"  # 用纯 ASCII 临时目录
```

完成后再把结果 pack 回 fork。

### W5. EBUSY: resource busy or locked

通常是残留 Claude / Helper / electron 进程没杀干净：

```powershell
Get-Process -Name "Claude*","electron*" | Stop-Process -Force
```

### W6. 改了 AppUserModelID 后任务栏图标坏了

千万不要改注册表里的 AppUserModelID。如果不小心改了：

```powershell
Remove-Item "HKCU:\Software\Classes\AppUserModelId\<你改的那个>" -Recurse -Force
# 然后重新启动 Claude.exe 让它自己注册回原始 ID
```

### W7. Windows 上签名 / 不签名的取舍

- **不签**：Windows 允许跑，第一次 SmartScreen 警告（点"仍要运行"），之后正常
- **自签证书**：需要装到"受信任的发布者"，否则 SmartScreen 一样警告
- **EV cert**：唯一能完全免警告的方式，但个人用户基本拿不到

**绝对不要**用社区共享 cert 签 fork，会被 Defender 标记为 known-abuse cert。

------

## 网关 / Provider 相关

### G1. 配好了 inferenceModels 但模型列表只有 Claude

`app.asar` 的 picker 过滤 patch 没生效。重跑 `verify_claude_fork.sh` / `.ps1` 看 `picker_filter_removed`。

### G2. 模型列表显示了但发消息瞬间报 400

模型名 case-sensitive 错误，或中转网关返回的 model id 和你填的 `inferenceModels.name` 不一致。  
用 `scripts/list_models.sh` 重新拉一遍 `/v1/models` 校对。

### G3. effort=Max 选了没反应

客户端 patch 只放开了 UI，**实际效果依赖上游 API 是否吃 `thinking` 字段**。

- DeepSeek `/anthropic` 端点：部分支持
- 中转包装 GPT/Gemini：通常被吞
- 直连 Anthropic：完整支持

这不是 patch 能修的，是协议层的限制。

### G4. 流式输出经常卡住或断

通常是中转 keep-alive 配置不当。可以临时关流式：

```json
{ "inferenceForceNonStreaming": true }
```

或换中转 / 自建 LiteLLM。

### G5. /v1/models 返回 OpenAI 风格而不是 Anthropic 风格

返回是 `{"data":[{"id":"...","object":"model"}]}` 而不是 Anthropic 风格的 `{"data":[{"id":"...","type":"model","display_name":"..."}]}` —— 说明这是个 OpenAI-compatible 网关，**不能直接给 Claude Desktop 用**。换中转，或者自建 LiteLLM 把它再包一层。

### G6. 模型按钮显示的名字和实际跑的模型对不上

现象：选 `deepseek-4-flash`，发完消息按钮瞬间变成 `gpt-5.3-codex` 或别的；但 content 里说话风格明显是 DeepSeek。

原因：中转网关（如 `new-api`、meding.site 这类聚合网关）的内部 routing 把 `response.model` 字段填成了**它内部的虚拟模型名**，不是你请求的那个。Claude Desktop UI 上的"模型名按钮"读的就是这个字段，所以会和你点选的模型不一致。

不是 client patch 能修的，是网关行为。处理方式：

- **可以接受**：模型路由由中转决定。功能上没有问题，只是显示名怪。
- **不能接受**：换中转（找承诺 "response.model 透传" 的）；或者自建 LiteLLM（默认透传 model id）。

实测验证方法：直接发一个明显的身份问题（"你是哪家的模型"），看 content 里的回答是否符合你点选的家族。这比看 UI 按钮可靠。
