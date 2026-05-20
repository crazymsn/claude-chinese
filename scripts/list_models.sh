#!/bin/bash
set -euo pipefail

# list_models.sh — 探测 Anthropic-compatible 中转的可用模型清单
# 用法：scripts/list_models.sh <base-url> <api-key>
# 例：  scripts/list_models.sh https://api.meding.site sk-xxxxx
#
# 行为：
#   1. 试 <base>/v1/models 和 <base>/anthropic/v1/models 两种路径
#   2. 头部试 x-api-key 和 Authorization: Bearer 两种鉴权
#   3. 把返回的 model id 按 gpt / gemini / deepseek / claude / other 分组
#   4. 打印一段可粘贴的 inferenceModels JSON
#
# 依赖：curl + node（不再需要 jq —— 解析用 node -e）

BASE="${1:-}"
KEY="${2:-}"

if [[ -z "$BASE" || -z "$KEY" ]]; then
  echo "usage: $0 <base-url> <api-key>" >&2
  echo "example: $0 https://api.meding.site sk-xxxxx" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "FATAL: curl not installed." >&2
  exit 2
fi
if ! command -v node >/dev/null 2>&1; then
  echo "FATAL: node not installed. brew install node 或 https://nodejs.org/" >&2
  exit 2
fi

TMP_RESP="$(mktemp /tmp/claude-models-XXXXXX.json)"
cleanup() { rm -f "$TMP_RESP"; }
trap cleanup EXIT

probe() {
  local url="$1"
  local auth_header="$2"
  curl -s -m 15 -o "$TMP_RESP" -w "%{http_code}" \
    -H "$auth_header" \
    -H "anthropic-version: 2023-06-01" \
    "$url"
}

URLS=("$BASE/v1/models" "$BASE/anthropic/v1/models")
HEADERS=("x-api-key: $KEY" "Authorization: Bearer $KEY")

FOUND_URL=""
FOUND_HEADER=""
for url in "${URLS[@]}"; do
  for h in "${HEADERS[@]}"; do
    code=$(probe "$url" "$h" || echo "000")
    if [[ "$code" == "200" ]]; then
      FOUND_URL="$url"
      FOUND_HEADER="$h"
      break 2
    fi
  done
done

if [[ -z "$FOUND_URL" ]]; then
  echo "FATAL: 没有任何 endpoint / header 组合返回 200" >&2
  echo "tried:" >&2
  for url in "${URLS[@]}"; do
    for h in "${HEADERS[@]}"; do
      echo "  $url   (${h%%:*})" >&2
    done
  done
  echo "" >&2
  echo "last response body (first 500 chars):" >&2
  head -c 500 "$TMP_RESP" >&2 2>/dev/null || true
  exit 3
fi

echo "==> using endpoint: $FOUND_URL"
echo "==> using auth:     ${FOUND_HEADER%%:*}"
echo

# 用 node -e 解析响应、判断风格、分组、生成 JSON 片段
# 这样脚本不再依赖 jq —— Node 反正已经是 @electron/asar 的强依赖
node -e '
const fs = require("fs");
const raw = fs.readFileSync(process.argv[1], "utf8");
let r;
try { r = JSON.parse(raw); }
catch (e) { console.error("FATAL: response not valid JSON\n" + raw.slice(0, 500)); process.exit(4); }

const list = Array.isArray(r.data) ? r.data : [];
if (!list.length) {
  console.error("FATAL: response.data is empty or missing");
  console.error("raw:", raw.slice(0, 500));
  process.exit(4);
}

// 响应风格判断
let style = "unknown / minimal";
const first = list[0] || {};
if (first.type === "model")        style = "Anthropic-compatible (.data[].type==model) ✓";
else if (first.object === "model") style = "OpenAI-compatible (.data[].object==model)  -- 警告：这个端点可能不能直接给 Claude Desktop 用";
console.log("==> response style: " + style);
console.log();

// 取 id（兼容 model_id 字段名）
const ids = [...new Set(list.map(m => m.id || m.model_id).filter(Boolean))].sort();

// 分组
const groups = { "gpt-*": [], "gemini-*": [], "deepseek-*": [], "claude-*": [], "other": [] };
for (const id of ids) {
  const lo = id.toLowerCase();
  if      (/gpt|openai|^o[1-4]/.test(lo))                       groups["gpt-*"].push(id);
  else if (/gemini|google/.test(lo))                            groups["gemini-*"].push(id);
  else if (/deepseek/.test(lo))                                 groups["deepseek-*"].push(id);
  else if (/claude|anthropic|haiku|sonnet|opus/.test(lo))       groups["claude-*"].push(id);
  else                                                          groups["other"].push(id);
}

console.log("==> 发现的模型：");
for (const [k, v] of Object.entries(groups)) {
  if (!v.length) continue;
  console.log("  [" + k + "]  (" + v.length + ")");
  for (const id of v) console.log("    - " + id);
}
console.log();

// 生成 inferenceModels 片段（默认 GPT/Gemini/DeepSeek 三家）
const picked = [...groups["gpt-*"], ...groups["gemini-*"], ...groups["deepseek-*"]];
console.log("==> 推荐 inferenceModels 片段（粘贴到 provider 配置 JSON）：");
console.log();
if (!picked.length) {
  console.log("  (没有发现 gpt / gemini / deepseek 任何一家模型 —— 检查中转是否支持这些供应商)");
} else {
  console.log("  \"inferenceModels\": [");
  const rows = picked.map(name => {
    const s1m = /gemini|deepseek/i.test(name) ? "true" : "false";
    return "    { \"name\": \"" + name + "\", \"supports1m\": " + s1m + " }";
  });
  console.log(rows.join(",\n"));
  console.log("  ]");
}
console.log();
console.log("如果你也想保留 Claude 系列作为对照，把 claude-* 组手动加进去。");
' "$TMP_RESP"
