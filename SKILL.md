---
name: claude-desktop-deepseek-3p
description: Use when modifying Claude Desktop (macOS or Windows) to support GPT / Gemini / DeepSeek or any Anthropic-compatible 3P gateway, especially for model-not-shown bugs, picker filter bypass, effort-Max greyed-out, update blocking, ad-hoc signing, ASAR integrity errors, startup repair, or Chinese localization across both platforms.
---

# Claude Desktop 3P 改包（跨平台 / 多 provider）

## 0. 第一件事：自动识别平台

macOS 和 Windows 在这件事上几乎没有共享步骤 —— 命令、路径、签名机制、ASAR Integrity 写回位置、禁更新方式都不同。**任何动手步骤之前，先识别平台。**

### 0.1 单条命令搞定

```
node scripts/detect_platform.js
```

这是一个跨平台 Node 脚本，在 macOS 的 zsh / bash 里和 Windows 的 PowerShell / cmd 里跑同一条命令，输出完全一致的格式。它一次报出：

- 当前 OS（macOS / Windows / 其它）和架构
- 已安装的 Claude Desktop 原版路径和版本
- 已存在的 fork（如果有）
- userData / configLibrary / 当前最近修改的 provider 配置
- **你应该读哪份 reference doc**
- **你应该用哪几个 scripts**
- 三条可直接粘贴的下一步命令

加 `--json` 切换为脚本可解析的输出：

```
node scripts/detect_platform.js --json
```

退出码：`0` 正常，`2` 平台不支持，`3` 没找到 Claude Desktop。

### 0.2 没装 Node 时的手动识别

| 现象 | 平台 | 对应 reference doc |
|---|---|---|
| 命令 `uname -s` 返回 `Darwin`，或存在 `/Applications/Claude.app` | macOS | `references/full-process-mac.md` |
| PowerShell `$IsWindows` 是 `True`，或存在 `%LocalAppData%\AnthropicClaude\` | Windows | `references/full-process-windows.md` |
| 两者都不是 | 不支持。本 skill 不覆盖 Linux / iOS / Android | — |

### 0.3 调用本 skill 的 Claude（助手）必须遵守

如果你是被通过本 skill 触发的 Claude 实例，**第一个动作必须是平台识别**：

1. 先用最便宜的方式判断：
   - Bash / zsh 里：`uname -s`（Mac 返回 `Darwin`）
   - PowerShell 里：`$env:OS`（Windows 返回 `Windows_NT`）—— 这个在 PowerShell **5.1**（Win 10/11 默认）和 **7+** 上都可靠。不要用 `$IsWindows` / `$IsMacOS` / `$PSVersionTable.OS`，这些只在 PowerShell 6+ 上存在
2. 不确定时跑 `node scripts/detect_platform.js`
3. **只读对应平台的 `full-process-*.md`**，不要混着读
4. **只用对应平台的 scripts**，看到 Bash 流程里要求 PowerShell 命令、或反过来，视为错误信号 —— 通常意味着平台识别错了

平台守卫已经内置在 `apply_patches.sh|ps1` 和 `verify_claude_fork.sh|ps1` 的开头（用 `uname -s` 和 `$env:OS`），跑错平台会立即退出并给出正确命令。

### 0.4 前提依赖（两平台共用）

本 skill 的脚本依赖以下工具，**跑 `apply_patches` 之前先确认装好**：

| 工具 | 用途 | macOS 安装 | Windows 安装 |
|---|---|---|---|
| Node.js + npm | 跑 `@electron/asar`、`detect_platform.js`、`list_models.{sh,ps1}` 的 JSON 解析 | `brew install node` | https://nodejs.org/ |
| `@electron/asar` | 解包/重打 `app.asar` | `npx -y @electron/asar` 首次自动下载 | 同左 |
| Python 3 | `apply_patches.sh` 用 here-doc 跑正则 patch | `xcode-select --install`（macOS 12.3+ 默认不带） | （Windows 流程用 PowerShell，不需要 Python） |
| `curl` | 探测中转 endpoint | macOS 自带 | Win 10+ 自带 |

> **不依赖 `jq`**：早期版本的 `list_models.sh` 用过 `jq`，已重写为 `bash + node -e`，因为 Node 反正是强依赖，没必要再要求一个独立的 JSON 工具。

首次跑 `npx -y @electron/asar` 时会从 npm registry 下载 `@electron/asar`，需要网络。如果你在受限网络下，先在能联网的机器上 `npm install -g @electron/asar`，再把全局 `node_modules` 拷到目标机。

### 0.5 已知限制（必读）

**本 skill 的命令清单和正则没有在真机 fork 上端到端验证过。** 设计基于：

- Claude Desktop 1.6608.2 的实测样本（来自原始 DeepSeek 改包流程，部分字符串值如 ASAR Integrity hash 是真实值）
- 上游版本变化后，混淆函数名（`vzt`、`YLA`、`lai` 等）和 chunk 文件名几乎必然变化

所以：

- `apply_patches.sh|ps1` 用的是按**特征字符串**定位的正则，不依赖混淆名 —— 大概率跨版本兼容，但**会有某次版本升级后正则不匹配**。脚本会打印 `WARN ... 没匹配上`，需要人工对照实际 chunk 调整。
- `verify_claude_fork.sh|ps1` 用的是反向断言（"原始限制字符串是否还在"），同样靠特征字符串。
- `https://api.meding.site` 上的 `/v1/models` 端点和 `/v1/messages` 端点已经实测可用（详见 conversation 历史或 `providers.md` §4 的实测样本）。但 fork 装上后的 UI 端到端流程**仍需在你的机器上验证一次**。

如果哪一步报 `WARN` 或失败，把对应的报错文案 / chunk 片段贴出来，调整正则比从零定位要快。

------

## 核心判断

这个 skill 的重点不是背具体 chunk 文件名，而是掌握一套稳定思路：

1. **永远 fork 原版，不直接改官方包**
2. **永远优先保住 app 身份稳定**（CFBundleIdentifier / Windows AppUserModelID 不动）
3. **按特征字符串定位，不迷信混淆函数名**
4. **每改一轮，都重新签名（或处理 SmartScreen）并验证启动**

如果只记住一句话，就是：

**Claude Desktop 这种 Electron 客户端，最怕"改得多"，真正有效的是"边界清楚地改"。**

## 适用场景

在这些情况使用本 skill：

- Claude Desktop 已支持 3P gateway，但拒绝 GPT / Gemini / DeepSeek 这类非 Anthropic catalog 模型
- `inferenceModels` 配好了，模型选择器里却不显示
- Claude Code 对第三方模型隐藏了 effort 菜单或 Max 档位
- 用 Anthropic-compatible 中转（如 `https://api.meding.site`）做 GPT / Gemini / DeepSeek 一站式接入
- 需要在 macOS **或** Windows 上禁用更新检查
- 需要做中文汉化（两平台共用渲染层资源）
- 改过几轮之后，app 开始闪退、签名坏掉、功能丢失，需要修复

## 绝对不要碰的点

跨平台通用：

1. 不要直接改原版包（`/Applications/Claude.app` 或 `%LocalAppData%\AnthropicClaude\`）
2. 不要改 `CFBundleIdentifier` / Windows AppUserModelID
3. 不要把备份文件（`*.before-*`、`*.bak`）放进 `.app` 或 install 目录里面
4. 不要看到签名/integrity 校验通过就以为万事大吉，必须看实际启动

macOS 专属：

5. 不要改 `CFBundleName`，只改 `CFBundleDisplayName`
6. 不要反复改 `.app` 包路径
7. 不要把主 App entitlements 用 `--deep` 粗暴套给 Helper / Framework

Windows 专属：

8. 不要直接改 Squirrel 的 `app-<version>\` 版本号目录名（更新逻辑依赖它）
9. 不要为了关更新去改 hosts、改 DNS、改防火墙，先用配置项或删 `Update.exe`
10. 不要给已经被改的 `.exe` 重签社区 cert，伪官方签名会被 Defender 标记

最稳的身份配置（两平台对照）：

| 字段 | macOS | Windows |
|---|---|---|
| 内部标识 | `CFBundleIdentifier = com.anthropic.claudefordesktop` | `AppUserModelID = com.anthropic.claudefordesktop`（注册表里） |
| 内部名 | `CFBundleName = Claude` | exe 名保持 `Claude.exe` |
| 显示名 | 改 `CFBundleDisplayName` | 改快捷方式 / Start Menu 显示名（不要改 exe 自身） |

## 标准思路

### 1. 先确认 3P 配置没问题

先看：

- `inferenceProvider`
- `inferenceGatewayBaseUrl`
- `inferenceModels`

如果配置本身不对，先别改包。

如果你的目标是接 GPT / Gemini / DeepSeek 三家，**用一个 Anthropic-compatible 中转网关把三家统一暴露**，比给每家分别配 provider 实际得多。本 skill 默认示例使用 `https://api.meding.site`，模型清单通过 `/v1/models` 自动发现，详见 `references/providers.md`。

### 2. 先 fork，再改 fork

推荐路径：

- **macOS**：原版 `/Applications/Claude.app` → fork `~/Applications/Claude-3p.app`
- **Windows**：原版 `%LocalAppData%\AnthropicClaude\app-<version>\` → fork `%LocalAppData%\Claude-3p\app-<version>\`（建议同时复制外层的 wrapper exe，否则更新逻辑会找不到入口）

后续所有 patch 都只打在 fork 上。

### 3. 主进程 patch 只改必要限制

核心通常是两类（**两平台共用同一份 `app.asar`，patch 相同**）：

- 绕过 3P provider 对非 Anthropic 模型的健康检查
- 去掉模型 picker 对自定义模型的二次过滤

定位方式：

- 搜报错文案（"inferenceModels: configured model"）
- 搜配置字段名
- 搜模型校验相关特征字符串

不要依赖旧版本里某个混淆函数名（每次升级都会变）。

### 4. Claude Code 相关 patch 要分层看

不要把这些混成一件事：

- 模型能不能显示
- effort 控件会不会出现
- `Max` / `Extra high` 会不会被过滤
- 当前页面链路到底会不会把参数传下去

也就是说，**"看见一个 selector"** 和 **"后端真的吃这个参数"** 是两回事。

### 5. 禁用更新优先走轻方案

跨平台优先级：

1. 优先使用官方配置项（如 `disableAutoUpdates`，写入 provider 配置 JSON）
2. macOS：patch 主进程里 Squirrel.Mac 的检查入口
3. Windows：在 fork 内删除或破坏 `Update.exe`（Squirrel.Windows），或把外层 `app-update.yml` 的 URL 指到不可达地址
4. 最后才考虑改更新源、改 hosts、搞全局网络封锁（**不推荐**）

### 6. 汉化优先走官方 locale 机制

跨平台优先级（详见 `references/i18n-localization.md`）：

1. `resources/*.json` 顶层语言资源（两平台路径相同，只是绝对路径不同）
2. `resources/zh-Hans.lproj/`（**仅 macOS**，Windows 不存在 lproj 概念）
3. `resources/ion-dist/i18n/*.json`（两平台共用，**这是大头**）
4. `resources/ion-dist/assets/v1/*.js` 的硬编码补丁（两平台共用）

也就是说：

**先词库，后 chunk。两平台改的是同一份 `resources/`，差异只是入口路径。**

如果某些页面切换到日语能变、切换到中文不变，通常不是"中文切换坏了"，而是中文那层资源没补齐。

### 7. 闪退修复的正确思路

如果改到最后 app 闪退，不要本能地继续在坏包上堆 patch。

优先做：

1. 先确认是不是签名 / Authenticode / integrity 问题
2. 再确认是不是运行时问题（看 crash log：macOS `~/Library/Logs/DiagnosticReports/`、Windows 事件查看器 + `%LocalAppData%\Claude-3p\Logs\`）
3. 如果包已经被改脏，直接用原版 app 重建一个干净底包
4. 然后**有意识地迁移真正需要的 patch**

注意：

**从干净底包重建时，最容易丢的是 renderer chunk 里的点对点汉化补丁。**

## 最小可用流程

如果你只是要做一个"可用的 3P 多模型修改包"，最小流程就是：

1. fork 原版 app（按平台选 macOS / Windows 分支）
2. 改显示名（不改内部标识）
3. 解包 `app.asar`
4. patch 3P provider 检查
5. patch 模型 picker 过滤
6. 如需汉化，补 locale 文件 + ion-dist 词库
7. 如有残余硬编码，再 patch renderer chunk
8. 重新打包 `app.asar`
9. 必要时刷新 ASAR Integrity（macOS：Info.plist；Windows：Electron 22+ 起也会校验，方式见 Win 流程）
10. 配置 provider（指向 `https://api.meding.site` 或你自己的 Anthropic-compatible 网关）
11. 用 `scripts/list_models.sh`（或 `.ps1`）拉一次 `/v1/models`，填入 `inferenceModels`
12. 重新签名（macOS 必做；Windows 可选）
13. 启动验证

平台具体命令分别看：

- `references/full-process-mac.md`
- `references/full-process-windows.md`

## 验证标准

至少做这几件事：

1. 签名 / Authenticode 校验通过（macOS：`codesign --verify --deep --strict`；Windows：`Get-AuthenticodeSignature`）
2. 实际启动 app
3. 确认进程不会秒退
4. 确认目标模型能显示（GPT / Gemini / DeepSeek 至少各点一个）
5. 确认关键 patch 真的生效（`scripts/verify_claude_fork.sh` 或 `.ps1`）
6. 确认 effort 菜单可用、Max 档可选、参数能传到后端

"合格的个人使用修改包"至少满足：

- 能启动
- 能签名 / Authenticode 通过
- 能走目标 3P gateway
- 关键功能正常
- 没有明显的更新 / 模型 / 启动回归

## 实战经验

### 经验 1：身份比名字重要

名字看起来像不像官方，不值得用 `CFBundleIdentifier` 或 AppUserModelID 去换。

### 经验 2：签名通过不代表运行时健康

`codesign --verify` / `Get-AuthenticodeSignature` 通过以后，仍然必须看启动是否稳定。macOS 还要单独看 ASAR Integrity；Windows 看 Electron 启动日志。

### 经验 3：备份不要进包

任何 `*.before-*`、`*.bak`、临时文件，放进 `.app` 或 install 目录里都可能把包搞脏。

### 经验 4：不要过度依赖旧版本文件名

chunk 文件名和函数名会变，特征字符串更可靠。

### 经验 5：汉化主战场不是顶层 300 多条小词库

真正的大头通常在：

- `ion-dist/i18n/*.json`
- `ion-dist/assets/v1/*.js`

### 经验 6：多 provider 用统一 gateway，不要给每家写一份 inferenceProvider

Claude Desktop 的 3P 配置允许多模型挂在同一个 `inferenceGatewayBaseUrl` 下。把 GPT / Gemini / DeepSeek 都挂到一个 Anthropic-compatible 中转上，是最简单的做法。

### 经验 7：Windows 没有 quarantine，但有 SmartScreen 和 Defender

Win 上改包后第一次启动会被 SmartScreen 拦一下，点"仍要运行"即可。如果 Defender 直接删文件，把 fork 目录加入排除列表。

## 推荐附带资源

入口（**必须先跑**）：

- `node scripts/detect_platform.js` — 平台识别 + 安装探测 + 推荐下一步

按场景查阅：

- macOS 完整命令清单：`references/full-process-mac.md`
- Windows 完整命令清单：`references/full-process-windows.md`
- 汉化（两平台共用）：`references/i18n-localization.md`
- Provider 配置 + meding.site + 模型自动识别：`references/providers.md`
- 踩坑总结（两平台）：`references/troubleshooting.md`

体检脚本：

- macOS：`scripts/verify_claude_fork.sh <app>`
- Windows：`scripts/verify_claude_fork.ps1 <install-dir>`

自动 patch 脚本（半自动，仍需人工确认特征匹配）：

- macOS：`scripts/apply_patches.sh <app>`
- Windows：`scripts/apply_patches.ps1 <install-dir>`

模型清单探测：

- macOS：`scripts/list_models.sh <base-url> <api-key>`
- Windows：`scripts/list_models.ps1 -BaseUrl <base-url> -ApiKey <api-key>`
