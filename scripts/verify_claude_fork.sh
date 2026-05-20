#!/bin/bash
set -euo pipefail

# 平台守卫：仅 macOS
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: verify_claude_fork.sh 仅支持 macOS（uname -s = '$(uname -s)'）。" >&2
  echo "Windows 用户请改用：.\\scripts\\verify_claude_fork.ps1 -InstallDir <install-dir>" >&2
  echo "不确定平台时，先跑：node scripts/detect_platform.js" >&2
  exit 1
fi

# 依赖检查：npx 和 python3（脚本里有 PlistBuddy 读 plist、python heredoc 解析 JSON）
missing=()
command -v npx     >/dev/null 2>&1 || missing+=("npx (装 Node.js: brew install node)")
command -v python3 >/dev/null 2>&1 || missing+=("python3 (macOS 12.3+ 默认不带；装：xcode-select --install)")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: 缺少依赖：" >&2
  for m in "${missing[@]}"; do echo "  - $m" >&2; done
  echo >&2
  echo "完整依赖清单见 SKILL.md §0.4。" >&2
  exit 1
fi

# verify_claude_fork.sh — macOS fork 体检脚本
# 用法：scripts/verify_claude_fork.sh /path/to/Claude-3p.app [config.json] [provider-config.json]
#
# 验证策略：检查"原始限制特征字符串"是否还存在。
# 这比硬编码 patch 后的字符串字面量更稳，能跨版本工作。

APP_PATH="${1:-}"
CONFIG_PATH="${2:-$HOME/Library/Application Support/Claude-3p/config.json}"
PROVIDER_CONFIG_PATH="${3:-}"

if [[ -z "$APP_PATH" ]]; then
  echo "usage: $0 /path/to/Claude-3p.app [config.json] [provider-config.json]" >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "app not found: $APP_PATH" >&2
  exit 1
fi

APP_ASAR="$APP_PATH/Contents/Resources/app.asar"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
ION_DIR="$APP_PATH/Contents/Resources/ion-dist/assets/v1"
WORK_DIR="$(mktemp -d /tmp/claude-fork-verify.XXXXXX)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# 自动定位 provider config（取最近修改的那个）
if [[ -z "$PROVIDER_CONFIG_PATH" ]]; then
  CFG_DIR="$HOME/Library/Application Support/Claude-3p/configLibrary"
  if [[ -d "$CFG_DIR" ]]; then
    PROVIDER_CONFIG_PATH="$(ls -1t "$CFG_DIR"/*.json 2>/dev/null | head -n1 || true)"
  fi
fi

pass() { printf "  %-40s : \033[32mpass\033[0m\n" "$1"; }
fail() { printf "  %-40s : \033[31mfail\033[0m   %s\n" "$1" "$2"; }

echo "== codesign =="
if codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
  pass "codesign --verify --deep --strict"
else
  fail "codesign --verify --deep --strict" "(run with -v for details)"
fi

echo
echo "== plist identity =="
plutil -p "$INFO_PLIST" | egrep 'CFBundleDisplayName|CFBundleIdentifier|CFBundleName' || true

echo
echo "== runtime config =="
if [[ -f "$CONFIG_PATH" ]]; then
  python3 - "$CONFIG_PATH" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
print(f"  locale                                   : {data.get('locale')}")
print(f"  deploymentMode                           : {data.get('deploymentMode')}")
PY
else
  echo "  config missing: $CONFIG_PATH"
fi

echo
echo "== provider config =="
if [[ -n "$PROVIDER_CONFIG_PATH" && -f "$PROVIDER_CONFIG_PATH" ]]; then
  python3 - "$PROVIDER_CONFIG_PATH" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
print(f"  inferenceProvider                        : {data.get('inferenceProvider')}")
print(f"  inferenceGatewayBaseUrl                  : {data.get('inferenceGatewayBaseUrl')}")
print(f"  disableAutoUpdates                       : {data.get('disableAutoUpdates')}")
models = [m.get('name') for m in data.get('inferenceModels', [])]
print(f"  inferenceModels ({len(models)})                       : {'; '.join(models) if models else '(empty)'}")

# 三家覆盖度检查
def has(prefix): return any(prefix in (m or '') for m in models)
groups = {
    'gpt-*'      : has('gpt'),
    'gemini-*'   : has('gemini'),
    'deepseek-*' : has('deepseek'),
}
for g, ok in groups.items():
    tag = 'present' if ok else 'MISSING'
    print(f"  group {g:<10}                       : {tag}")
PY
else
  echo "  provider config missing or not specified"
fi

echo
echo "== app.asar patch checks =="
npx -y @electron/asar extract "$APP_ASAR" "$WORK_DIR" >/dev/null 2>&1
INDEX_JS="$WORK_DIR/.vite/build/index.js"

if [[ ! -f "$INDEX_JS" ]]; then
  fail "app.asar: index.js" "未在 .vite/build/index.js 找到（chunk 结构可能变化）"
else
  # patch 生效 = 原始限制特征字符串不再出现
  if grep -q 'inferenceModels: configured model "' "$INDEX_JS"; then
    fail "provider_health_bypass" "原始报错文案仍在 index.js 中，§7 patch 未生效"
  else
    pass "provider_health_bypass"
  fi

  if grep -qE 'filter\(.\=>YLA\(.,..id\)\.ok\)' "$INDEX_JS"; then
    fail "picker_filter_removed" "原始 picker filter 仍在 index.js 中，§8 patch 未生效"
  else
    pass "picker_filter_removed"
  fi
fi

echo
echo "== effort patch checks =="
if [[ -d "$ION_DIR" ]]; then
  # modelSupportsMaxEffort：检查原始限制函数的整体形状是否还在。
  # 不能只看 opus-4-6 / opus-4-7 是否共现 —— 模型列表数组里这两个串本来就会一起出现。
  # 必须匹配 function(...){ ... opus-4-6 ... opus-4-7 ... }(...) 这种 IIFE 形状。
  if grep -rqE 'function\([^)]*\)\{[^}]*opus-4-6[^}]*opus-4-7[^}]*\}\([^)]*\)' "$ION_DIR" 2>/dev/null; then
    fail "effort_max_patched" "Max 限制 IIFE 仍在某个 chunk 中，§10.3 patch 未生效"
  else
    pass "effort_max_patched"
  fi

  # envSupportsEffort 白名单扩展
  if grep -rq '"anthropic_cloud"===' "$ION_DIR" 2>/dev/null; then
    pass "remote_effort_env_patched"
  else
    fail "remote_effort_env_patched" "未在任何 chunk 看到扩展的环境白名单，§10.4 patch 未生效"
  fi

  # 远端 session 传 effort 参数
  if grep -rq 'effort:hi,coordinatorMode' "$ION_DIR" 2>/dev/null; then
    pass "remote_session_passes_effort"
  else
    fail "remote_session_passes_effort" "创建会话调用未带 effort 参数"
  fi
else
  fail "ion-dist directory" "$ION_DIR not found"
fi

echo
echo "== ASAR Integrity =="
ACTUAL_ASAR_SHA="$(shasum -a 256 "$APP_ASAR" | awk '{print $1}')"
PLIST_HASH="$(/usr/libexec/PlistBuddy -c 'Print :ElectronAsarIntegrity:Resources/app.asar:hash' "$INFO_PLIST" 2>/dev/null || echo '(missing)')"
echo "  app.asar shasum                          : $ACTUAL_ASAR_SHA"
echo "  Info.plist ElectronAsarIntegrity hash    : $PLIST_HASH"
echo "  注：ElectronAsarIntegrity 不是普通 SHA256，两者不相等是正常的。"
echo "      只要启动时不报 Integrity check failed 就 OK。"

echo
echo "== quarantine =="
QUARANTINE="$(xattr -l "$APP_PATH" 2>/dev/null | grep -c quarantine || true)"
if [[ "$QUARANTINE" -eq 0 ]]; then
  pass "no com.apple.quarantine attribute"
else
  fail "com.apple.quarantine present" "运行 xattr -dr com.apple.quarantine \"$APP_PATH\""
fi

echo
echo "== done =="
