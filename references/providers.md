# Provider 配置：用一个网关接通 GPT / Gemini / DeepSeek

本文说明 Claude Desktop 3P gateway 怎么配置才能在一个 fork 里同时跑 GPT、Gemini、DeepSeek，以及如何从网关自动识别可用模型。

------

## 1. 架构概念：客户端 patch / 翻译网关 / 上游 API

Claude Desktop 走 3P 时，请求体严格遵循 Anthropic Messages API（`POST /v1/messages`）。这意味着：

```
+--------------------+        +---------------------+        +----------------+
| Claude Desktop fork|  -->   |  Anthropic-compat   |  -->   |  OpenAI API    |
| (patched 客户端)   |        |  中转网关           |  -->   |  Gemini API    |
|                    |        |  (协议翻译)         |  -->   |  DeepSeek API  |
+--------------------+        +---------------------+        +----------------+
   本 skill 改的是这里           本文配置的是这里             这层不归我们管
```

本 skill 只负责客户端 patch。翻译网关是独立组件，**它的存在是因为 OpenAI 和 Gemini 原生不暴露 Anthropic 协议**。DeepSeek 例外，它原生有 `/anthropic` 端点。

本文默认使用 `https://api.meding.site` 作为 Anthropic-compatible 中转。

------

## 2. 配置文件位置

| 平台 | 路径 |
|---|---|
| macOS | `$HOME/Library/Application Support/Claude-3p/configLibrary/<provider-config-id>.json` |
| Windows | `%AppData%\Claude-3p\configLibrary\<provider-config-id>.json` |

`<provider-config-id>` 是 Claude Desktop 首次启动后随机生成的 UUID，每台机器不同。可以用以下命令快速找到当前在用的那个：

```bash
# macOS
ls -1 "$HOME/Library/Application Support/Claude-3p/configLibrary/"
```

```powershell
# Windows
Get-ChildItem "$env:APPDATA\Claude-3p\configLibrary\"
```

------

## 3. 默认配置（Anthropic-compatible 中转）

最小可用配置：

```json
{
  "inferenceProvider": "gateway",
  "inferenceGatewayBaseUrl": "https://api.meding.site",
  "inferenceGatewayApiKey": "<your-api-key>",
  "inferenceModels": [],
  "disableAutoUpdates": true
}
```

`inferenceModels` 先留空，后面用脚本自动填。

> **关于 `disableAutoUpdates`**：这是**最佳努力 (best-effort) 字段**，原 skill 引用过但未端到端验证在所有 Claude Desktop 版本上字段名是否一致。**真正可靠的禁更新机制是平台特定的**：
> - macOS：见 `full-process-mac.md` §第 14 节后续（patch Squirrel.Mac 入口）
> - Windows：见 `full-process-windows.md` §14（删 `Update.exe` + 改坏 `app-update.yml`）
>
> 这里保留 `disableAutoUpdates: true` 不会有害（即使字段被忽略也没副作用），但**不要只靠它**。

      注：
      • 实际请求路径会变成 `<inferenceGatewayBaseUrl>/v1/messages`。
      • 如果你的中转把 Anthropic 端点挂在 `/anthropic` 子路径下（如 `https://api.meding.site/anthropic/v1/messages`），那么 `inferenceGatewayBaseUrl` 要填 `https://api.meding.site/anthropic`。
      • 用 §6 的探针命令实际打一次，确认你的中转用哪种路径布局。

------

## 4. 推荐 inferenceModels（GPT / Gemini / DeepSeek 默认三家）

针对 `https://api.meding.site` 实际探针验证过的清单（**网关品牌：new-api，2026-05 实测**）：

```json
{
  "inferenceModels": [
    { "name": "gpt-5.4",                  "supports1m": false },
    { "name": "gpt-5.4-mini",             "supports1m": false },
    { "name": "gpt-5-mini",               "supports1m": false },
    { "name": "gpt-4o",                   "supports1m": false },
    { "name": "gemini-3-pro-preview",     "supports1m": true  },
    { "name": "gemini-3-flash-preview",   "supports1m": true  },
    { "name": "gemini-3.1-pro-preview",   "supports1m": true  },
    { "name": "gemini-3.1-flash-preview", "supports1m": true  },
    { "name": "deepseek-4-pro",           "supports1m": true  },
    { "name": "deepseek-4-flash",         "supports1m": true  },
    { "name": "deepseek-v3.1",            "supports1m": false },
    { "name": "deepseek-r1",              "supports1m": false }
  ]
}
```

`name` 必须**和 `/v1/models` 返回的 id 完全一致**（已实测）。如果你的中转不是 meding.site，每家可能的命名风格：

| 中转命名风格 | 示例 |
|---|---|
| 直名（meding.site 即此风格） | `gpt-5.4`、`gemini-3-pro-preview`、`deepseek-4-pro` |
| 厂商前缀 | `openai/gpt-5`、`google/gemini-3-pro`、`deepseek/deepseek-v4-pro` |
| 加 anthropic 后缀（兼容包装） | `gpt-5-anthropic`、`gemini-3-pro-anthropic` |

注意 **DeepSeek 在 meding.site 上是 `deepseek-4-*` 不是 `deepseek-v4-*`**（没有 `v` 字母）。

`supports1m` 标记是否声明 1M token 上下文，写错不会致命，但会在 UI 上显示错误的上下文窗口提示。

> **⚠ `response.model` 字段不可信**：实测向 meding.site 请求 `deepseek-4-flash`，返回的 `response.model` 字段是 `gpt-5.3-codex`，但 content 是真实的 DeepSeek 回复。这是 new-api 这类聚合网关的常见做法（内部 routing + 虚拟模型名）。Claude Desktop UI 显示的"模型名"读的就是这个字段，可能和实际跑的模型不一致。功能上不影响使用。

------

## 5. 通过 `/v1/models` 自动识别可用模型（推荐流程）

不要手猜模型名。中转的实际 model id 一定能从它自己的 `/v1/models` 拿到。

跑这条命令：

```bash
bash scripts/list_models.sh "https://api.meding.site" "<your-api-key>"
```

或在 PowerShell 里：

```powershell
.\scripts\list_models.ps1 -BaseUrl "https://api.meding.site" -ApiKey "<your-api-key>"
```

脚本会做三件事：

1. `GET <base>/v1/models`，按 Anthropic 文档的响应结构解析
2. 按关键字 `gpt|gemini|deepseek|claude` 分组
3. 直接打印一段可粘贴的 `inferenceModels` JSON

      注：
      • 如果 `/v1/models` 返回 404，试 `<base>/anthropic/v1/models`，并把 `inferenceGatewayBaseUrl` 改成带 `/anthropic` 的版本。
      • 如果返回 401，先检查 key 头格式。Anthropic 协议用 `x-api-key`，但某些中转兼容 `Authorization: Bearer`，脚本两种都会试。
      • 如果返回的是 OpenAI 风格 `{"data":[{"id":"..."}]}` 而不是 Anthropic 风格的 `{"data":[{"id":"...","type":"model"}]}`，说明这个中转其实是 OpenAI-compatible，不是 Anthropic-compatible，不能直接用。需要换中转或自己架 LiteLLM。

------

## 6. 端点探针（确认中转协议形状）

不知道中转走哪种路径布局时，按这个顺序试：

```bash
# 探针 1：根路径 + /v1/messages
curl -s -o /dev/null -w "%{http_code}\n" \
  -X POST "https://api.meding.site/v1/messages" \
  -H "x-api-key: $KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-3-5-haiku-latest","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}'

# 探针 2：anthropic 子路径
curl -s -o /dev/null -w "%{http_code}\n" \
  -X POST "https://api.meding.site/anthropic/v1/messages" \
  -H "x-api-key: $KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-3-5-haiku-latest","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}'
```

返回 200 的那个就是真正的 base URL（去掉 `/v1/messages` 后缀填到 `inferenceGatewayBaseUrl`）。

返回 401 也算 endpoint 是对的（只是 key 不对），404 / 405 才说明路径错。

------

## 7. 三家模型在中转下的常见坑

| 现象 | 通常原因 | 处理 |
|---|---|---|
| GPT-5 调通了但工具调用乱码 | OpenAI 的 tool_use 协议被中转翻译成 Anthropic 格式时丢字段 | 换中转，或把使用场景限制到不用 tool_use 的对话 |
| Gemini 流式输出经常断 | Gemini 原生 SSE 帧格式和 Anthropic 不一样，中转 keep-alive 没配 | 中转加 `keep-alive` 和 SSE flush；或换中转 |
| DeepSeek "extended thinking" 不工作 | DeepSeek `/anthropic` 端点对 `thinking` 字段的支持是部分的 | 如果非要思考链，直连 `https://api.deepseek.com/anthropic` 而非走中转 |
| 模型选择器里看到了，但发消息瞬间报 400 | 模型名 case-sensitive，`GPT-5` ≠ `gpt-5` | 严格按 `/v1/models` 返回的 id 填 `inferenceModels.name` |
| effort=Max 选项点了没反应 | 中转不识别 Anthropic 的 `thinking` 字段，直接吞了 | 这是上游限制，客户端 patch 解决不了 |

------

## 8. 当你想自建翻译网关（LiteLLM）

如果中转不可靠或你不想信任第三方 key 托管，自己跑一个 LiteLLM 就行。最小 `config.yaml`：

```yaml
model_list:
  - model_name: gpt-5
    litellm_params:
      model: openai/gpt-5
      api_key: os.environ/OPENAI_API_KEY
  - model_name: gemini-3-pro
    litellm_params:
      model: gemini/gemini-3-pro
      api_key: os.environ/GEMINI_API_KEY
  - model_name: deepseek-4-pro
    litellm_params:
      model: deepseek/deepseek-chat
      api_key: os.environ/DEEPSEEK_API_KEY

litellm_settings:
  drop_params: true
```

跑：

```bash
docker run -p 4000:4000 \
  -e OPENAI_API_KEY=... \
  -e GEMINI_API_KEY=... \
  -e DEEPSEEK_API_KEY=... \
  -v $(pwd)/config.yaml:/app/config.yaml \
  ghcr.io/berriai/litellm:main-stable \
  --config /app/config.yaml --port 4000
```

然后把 Claude Desktop 的 `inferenceGatewayBaseUrl` 指向 `http://localhost:4000`，LiteLLM 会原生暴露 Anthropic-compatible 接口。

------

## 9. 回滚

provider 配置直接覆盖回原内容即可，**不需要重签 / 重打 asar**。Claude Desktop 启动时读取这个 JSON。

回滚前记得：

```bash
# macOS
cp "<config>.json" "<config>.json.before-3p-patch.$(date +%Y%m%d%H%M%S)"
```

```powershell
# Windows
Copy-Item "<config>.json" "<config>.json.before-3p-patch.$(Get-Date -Format yyyyMMddHHmmss)"
```
