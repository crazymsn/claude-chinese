#!/bin/bash
set -euo pipefail

# 平台守卫：仅 macOS
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: apply_patches.sh 仅支持 macOS（uname -s = '$(uname -s)'）。" >&2
  echo "Windows 用户请改用：.\\scripts\\apply_patches.ps1 -InstallDir <install-dir>" >&2
  echo "不确定平台时，先跑：node scripts/detect_platform.js" >&2
  exit 1
fi

# 依赖检查：npx 和 python3
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

# apply_patches.sh — macOS 自动 patch
# 用法：scripts/apply_patches.sh /path/to/Claude-3p.app
#
# 做四件事：
#   1. patch 3P provider 健康检查（清空 vzt 函数体）
#   2. patch 模型 picker 二次过滤
#   3. patch modelSupportsMaxEffort（永远返回 true）
#   4. patch envSupportsEffort 白名单 + 创建会话带 effort 参数
#
# 重打 asar、刷 integrity、重签由调用方负责。本脚本只动文件内容。

APP_PATH="${1:-}"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "usage: $0 /path/to/Claude-3p.app" >&2
  exit 1
fi

ASAR="$APP_PATH/Contents/Resources/app.asar"
ION_DIR="$APP_PATH/Contents/Resources/ion-dist/assets/v1"
TS="$(date +%Y%m%d%H%M%S)"
WORK="$(mktemp -d /tmp/claude-fork-apply.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------- 1 & 2: app.asar patch ----------

echo "[1/4] backup app.asar"
cp "$ASAR" "$ASAR.before-3p-patch.$TS"

echo "[2/4] extracting app.asar..."
npx -y @electron/asar extract "$ASAR" "$WORK" >/dev/null

INDEX_JS="$WORK/.vite/build/index.js"
if [[ ! -f "$INDEX_JS" ]]; then
  echo "FATAL: .vite/build/index.js not found in extracted asar" >&2
  exit 2
fi

python3 - "$INDEX_JS" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1])
src  = path.read_text()
orig_len = len(src)
changes = []

# ---- vzt: 3P provider 健康检查 ----
# 找形如 function XXX(e,A){... inferenceModels: configured model ... return null} 的函数
pattern_vzt = re.compile(
    r'function\s+(\w+)\s*\(e,A\)\s*\{[^{}]*?inferenceModels:\s*configured\s+model[^{}]*?return\s+null\s*\}',
    re.DOTALL,
)
m = pattern_vzt.search(src)
if m:
    func_name = m.group(1)
    new_func  = f"function {func_name}(e,A){{return null}}"
    src = pattern_vzt.sub(new_func, src, count=1)
    changes.append(f"vzt({func_name}): provider_health_bypass")
elif 'inferenceModels: configured model' in src:
    print("WARN: 报错文案存在但函数边界没匹配上，可能 chunk 结构变化，需要手工 patch")
else:
    changes.append("vzt: already patched (报错文案不在)")

# ---- picker filter: lai 函数末尾 return e?i.filter(...):i ----
pattern_picker = re.compile(
    r'return\s+e\?\s*i\.filter\(\s*r\s*=>\s*\w+\(e,\s*r\.id\)\.ok\s*\)\s*:\s*i'
)
if pattern_picker.search(src):
    src = pattern_picker.sub('return i', src)
    changes.append("picker_filter_removed")
elif re.search(r'filter\(\s*r\s*=>\s*\w+\(e,\s*r\.id\)\.ok\s*\)', src):
    print("WARN: filter 表达式存在但和预期模式不匹配，可能混淆名变化，需要手工 patch")
else:
    changes.append("picker_filter: already patched")

if len(src) != orig_len or changes:
    path.write_text(src)
    for c in changes:
        print(f"  ok  {c}")
else:
    print("  no changes needed in index.js")
PY

echo "[3/4] repack app.asar"
npx -y @electron/asar pack "$WORK" "$ASAR" >/dev/null

# ---------- 3 & 4: ion-dist effort patches ----------

echo "[4/4] patching ion-dist effort chunks..."

# 找 modelSupportsMaxEffort 所在 chunk
EFFORT_FILE="$(grep -rl 'modelSupportsMaxEffort\|opus-4-6.*opus-4-7' "$ION_DIR" 2>/dev/null | head -n1 || true)"
if [[ -n "$EFFORT_FILE" ]]; then
  cp "$EFFORT_FILE" "$EFFORT_FILE.before-effort-max-patch.$TS"
  python3 - "$EFFORT_FILE" <<'PY'
import re, sys
from pathlib import Path
p = Path(sys.argv[1])
src = p.read_text()
# 匹配形如：r=function(e,t){...opus-4-6...opus-4-7...}(t,n)
pattern = re.compile(
    r'r=function\(e,t\)\{[^}]*?opus-4-6[^}]*?opus-4-7[^}]*?\}\(t,n\)',
    re.DOTALL,
)
if pattern.search(src):
    src = pattern.sub('r=function(e,t){return!0}(t,n)', src)
    p.write_text(src)
    print(f"  ok  effort_max_patched ({p.name})")
elif 'opus-4-6' in src and 'opus-4-7' in src:
    print(f"  WARN  opus-4-6/4-7 在 {p.name} 中，但 r= 函数边界没匹配，需手工 patch")
else:
    print(f"  ok  effort_max: already patched in {p.name}")
PY
else
  echo "  WARN  没找到含 modelSupportsMaxEffort 的 chunk"
fi

# 找 envSupportsEffort 所在 chunk
QUEUE_FILE="$(grep -rl 'envSupportsEffort' "$ION_DIR" 2>/dev/null | head -n1 || true)"
if [[ -n "$QUEUE_FILE" ]]; then
  cp "$QUEUE_FILE" "$QUEUE_FILE.before-effort-env-patch.$TS"
  python3 - "$QUEUE_FILE" <<'PY'
import re, sys
from pathlib import Path
p = Path(sys.argv[1])
src = p.read_text()
changes = []

# 扩展环境白名单
pat_env = re.compile(r'(fi)="local"===Qa\|\|"ssh"===Qa(?!\|\|"anthropic_cloud")')
new_env = r'\1="local"===Qa||"ssh"===Qa||"anthropic_cloud"===Qa||"byoc"===Qa||"pool"===Qa'
if pat_env.search(src):
    src = pat_env.sub(new_env, src)
    changes.append("remote_effort_env_patched")
elif 'anthropic_cloud"===' in src:
    changes.append("remote_effort_env: already patched")
else:
    print(f"  WARN  envSupportsEffort 白名单模式没匹配，混淆变量可能变了")

# 创建会话调用补 effort 参数
pat_session = re.compile(r'(mcpConfig:eo,)(coordinatorMode)')
if pat_session.search(src) and 'effort:hi,coordinatorMode' not in src:
    src = pat_session.sub(r'\1effort:hi,\2', src)
    changes.append("remote_session_passes_effort")
elif 'effort:hi,coordinatorMode' in src:
    changes.append("remote_session_passes_effort: already patched")

if changes:
    p.write_text(src)
    for c in changes:
        print(f"  ok  {c} ({p.name})")
PY
else
  echo "  WARN  没找到含 envSupportsEffort 的 chunk"
fi

echo
echo "=========================================="
echo "patches applied."
echo "next steps:"
echo "  1. let Electron tell you the new asar integrity hash:"
echo "       env ELECTRON_ENABLE_LOGGING=1 \"$APP_PATH/Contents/MacOS/Claude\" 2>&1 | head -n 40"
echo "  2. write hash back into Info.plist (see full-process-mac.md §11)"
echo "  3. re-sign per §14"
echo "  4. xattr -dr com.apple.quarantine \"$APP_PATH\""
echo "  5. open -n \"$APP_PATH\""
echo "  6. bash scripts/verify_claude_fork.sh \"$APP_PATH\""
echo "=========================================="
