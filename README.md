欢迎关注B站及YouTube频道：深度云创科技，感兴趣的朋友欢迎加入新时代智能体交流社群

客服微信：16773345788

# claude-chinese Claude 客户端汉化工具+解锁第三方模型接入

> 一个 [Claude Skill](https://docs.anthropic.com/en/docs/build-with-claude/claude-code/skills)，让 Claude Desktop 在 **macOS** 和 **Windows** 上直接调用 **GPT / Gemini / DeepSeek** 等任何 Anthropic-compatible 3P 网关模型，附带中文汉化、禁更新、签名修复、模型自动发现。

## 这个项目能解决什么

如果你装了 Claude Desktop 并配好了 3P gateway，但遇到下面任何一条，这个 skill 就是给你的：

- `inferenceModels` 配好了，**模型选择器里看不到** GPT / Gemini / DeepSeek
- Claude Code 里第三方模型的 **effort 菜单灰掉**，或者 `Max` 档位过滤了
- 想用一个统一的 Anthropic-compatible 中转（如 `https://api.meding.site`）**一站式接通三家**
- 想在 Mac 或 Win 上**禁掉 Claude Desktop 自动更新**
- 想做**中文汉化**（顶层 locale + ion-dist 词库 + chunk 硬编码补丁）
- 改包之后 app **闪退**、签名坏掉、ASAR Integrity 校验失败，需要修复

## 为什么是个 skill 不是脚本工具

Claude Desktop 每次升级，混淆函数名（`vzt`、`YLA`、`lai` 等）和 chunk 文件名几乎一定变。**死命令清单跨版本就废了**。所以这个项目主体不是"按 1-2-3 执行"，而是：

- **方法论**（SKILL.md）：先 fork 不动原版、按特征字符串而不是混淆名定位、改完每次都重签 + 启动验证
- **可执行脚本**（scripts/）：自动 patch、自动验证、自动模型发现，所有正则都基于跨版本稳定的特征字符串
- **平台分支文档**（references/）：Mac 和 Win 各一份完整命令清单，**带 22 章实战踩坑**

被 Claude Code 加载后，Claude 会先跑平台探针，再读对应平台的文档，最后跑对应平台的脚本。

## 30 秒上手

```bash
# 1. 装为 Claude Code 的 skill 或直接 clone
git clone https://github.com/crazymsn/claude-chinese.git
cd claude-chinese

# 2. 跑平台探针（Mac / Win 跑同一条）
node scripts/detect_platform.js

# 3. 探针会告诉你下一步读哪份 reference + 跑哪几个 scripts
```

## 项目结构

```
claude-chinese/
├── SKILL.md                          ← Claude 入口（方法论 + 平台识别 + 依赖）
├── agents/openai.yaml                ← skill interface 元数据
├── references/
│   ├── full-process-mac.md           ← macOS 23 章完整流程
│   ├── full-process-windows.md       ← Windows 21 章完整流程
│   ├── i18n-localization.md          ← 跨平台 4 层汉化策略
│   ├── providers.md                  ← 网关配置 + 模型自动识别
│   └── troubleshooting.md            ← 9 条通用 + 7 条 macOS + 7 条 Windows + 6 条网关坑
└── scripts/
    ├── detect_platform.js            ← 跨平台 Node 入口
    ├── apply_patches.{sh,ps1}        ← 自动 patch
    ├── verify_claude_fork.{sh,ps1}   ← 体检（反向断言，跨版本稳定）
    └── list_models.{sh,ps1}          ← 从网关 /v1/models 自动发现模型
```

## 核心 patch 做了什么

整个改包只动 4 个地方（**两平台共用同一份 `app.asar`**）：

1. **绕过 3P provider 健康检查**：让非 Anthropic catalog 模型（gpt-*、gemini-*、deepseek-*）通过校验
2. **去掉模型 picker 二次过滤**：让自定义模型真正出现在选择器里
3. **放开 `modelSupportsMaxEffort`**：让第三方模型也支持 Max 思考档
4. **扩展 `envSupportsEffort` 白名单**：让远端环境（anthropic_cloud / byoc / pool）也显示 effort 菜单，且实际把参数传到后端

没有改 hosts、没有加本地代理、没有伪装成 Claude 模型再转回 DeepSeek。请求路径就是 Claude Desktop 自带的 3P gateway → 你配的 base URL（默认示例 `https://api.meding.site`）。

## 平台对比

| 项 | macOS | Windows |
|---|---|---|
| Fork 路径 | `~/Applications/Claude-3p.app` | `%LocalAppData%\Claude-3p\app-<version>\` |
| 解包/重打 asar | `npx -y @electron/asar` | 同左 |
| ASAR Integrity 写回 | `Info.plist:ElectronAsarIntegrity` | PE 资源 / `electron-asar-integrity.json` / 关 fuse |
| 签名 | `codesign --sign -` (ad-hoc) + entitlements | Authenticode 可选，不签也能跑 |
| 禁更新 | patch Squirrel.Mac 入口 | 删 `Update.exe` + 改坏 `app-update.yml` |
| 验证启动 | `codesign --verify --deep --strict` + 实跑 | `Get-AuthenticodeSignature` + 事件查看器 |

## 多 provider 接入

客户端 patch 本身**已经 model-agnostic**。换 provider 只需要改 `inferenceGatewayBaseUrl` 一行。

GPT 和 Gemini 原生不暴露 Anthropic 协议，所以需要中间网关做协议翻译。三种选择：

- **第三方中转**（最简单）：`https://api.meding.site` 这类已经实测可用
- **自建 LiteLLM**：见 [references/providers.md §8](references/providers.md)，docker-compose 一条命令

`scripts/list_models.{sh,ps1}` 会自动探针 `/v1/models` 端点，按 gpt/gemini/deepseek/claude 分组，**生成可直接粘贴的 `inferenceModels` JSON 片段**。

## 依赖

| 工具 | 用途 | macOS | Windows |
|---|---|---|---|
| Node.js | `@electron/asar`、`detect_platform.js`、模型清单 JSON 解析 | `brew install node` | https://nodejs.org/ |
| Python 3 | `apply_patches.sh` 用 here-doc 跑正则 patch | `xcode-select --install` | （不需要） |
| `curl` | 探测中转 endpoint | 自带 | Win 10+ 自带 |

**不需要 jq**（早期版本要，已改用 `node -e` 替代）。

## 已知限制

- 本 skill 的命令清单和正则**没有在真实 fork 上端到端验证过**。设计基于：Claude Desktop 1.6608.2 的实测样本 + 跨版本稳定的特征字符串定位。如果上游升级后正则不匹配，脚本会打印 `WARN ... 没匹配上`，需要根据实际 chunk 内容调整。
- `disableAutoUpdates` 字段是 best-effort（字段名未经全版本实测）；可靠的禁更新机制是平台特定的 Update.exe / Squirrel 处理。
- 网关 `response.model` 字段可能不可信 —— meding.site 这类 new-api 网关会把内部 routing 的虚拟模型名填到响应里，UI 显示的模型名可能和实际跑的不一致。**功能上不影响使用**，但显示会怪。详见 [troubleshooting.md G6](references/troubleshooting.md)。

## 安全性 / 合规

- 这个 skill 修改的是**你本机上的 fork**，不影响 `/Applications/Claude.app` 原版
- ad-hoc 签名只对你本机有效，**不是分发级签名**
- 不要用社区共享证书重签，会被 Defender / Gatekeeper 标记
- 个人可用 ≠ 分发级质量

## 验证过的网关

| 网关 | base URL | 实测时间 | 备注 |
|---|---|---|---|
| meding.site (new-api) | `https://api.meding.site` | 2026-05 | 47 模型，覆盖 gpt-4o/5.x、gemini-3/3.1、deepseek-4/v3、claude-opus-4-6/7 等 |

## 贡献

如果你 fork 了一台真实的 Claude Desktop 跑通了流程，欢迎提 issue 把你的 Claude Desktop 版本号 + 任何需要调整的正则贴出来。这是这个 skill 长期保持有效的最重要的输入。

## License

未指定。如果你 fork 这个项目自用、改造、分发，请注意：

- 不要把任何 Claude Desktop 二进制 / app.asar 内容传播进 git（只传 patch 脚本）
- 不要在 README / 公开内容里暴露任何 API key 或 PAT

## 关键文件入口

| 我想做什么 | 看哪里 |
|---|---|
| 理解整套思路 | [SKILL.md](SKILL.md) |
| Mac 命令清单 | [references/full-process-mac.md](references/full-process-mac.md) |
| Win 命令清单 | [references/full-process-windows.md](references/full-process-windows.md) |
| 配 GPT / Gemini / DeepSeek | [references/providers.md](references/providers.md) |
| 做中文汉化 | [references/i18n-localization.md](references/i18n-localization.md) |
| 改完闪退 / 模型不显示 / effort 灰掉 | [references/troubleshooting.md](references/troubleshooting.md) |
