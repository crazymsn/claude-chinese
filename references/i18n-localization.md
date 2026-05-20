# 汉化（Mac / Win 共用 4 层策略）

## 1. 为什么是 4 层

Claude Desktop 的中文文案分散在 4 个独立层，少补一层就会出现"日语切换有效、中文切换无效"或"主菜单是中文、对话区是英文"这种夹生状态。

| 层 | 路径（相对 `Contents/Resources` 或 `resources/`）| 平台 |
|---|---|---|
| 1 顶层 locale json | `<locale>.json`（如 `zh-CN.json`） | 两平台共用 |
| 2 macOS lproj | `zh-Hans.lproj/Localizable.strings` | **仅 macOS** |
| 3 ion-dist 词库 | `ion-dist/i18n/zh-CN.json` 等 | 两平台共用，**汉化大头** |
| 4 chunk 硬编码 | `ion-dist/assets/v1/*.js` 里的字符串字面量 | 两平台共用 |

**Iron rule：先补词库（1、3），最后才动 JS chunk（4）。**

## 2. 平台路径对照

绝对路径不同，但相对路径完全相同：

| 层 | macOS 绝对路径 | Windows 绝对路径 |
|---|---|---|
| 1 | `Claude-3p.app/Contents/Resources/zh-CN.json` | `<install>\resources\zh-CN.json` |
| 2 | `Claude-3p.app/Contents/Resources/zh-Hans.lproj/` | （Windows 无对应概念） |
| 3 | `Claude-3p.app/Contents/Resources/ion-dist/i18n/zh-CN.json` | `<install>\resources\ion-dist\i18n\zh-CN.json` |
| 4 | `Claude-3p.app/Contents/Resources/ion-dist/assets/v1/*.js` | `<install>\resources\ion-dist\assets\v1\*.js` |

**层 1、3、4 改的是同一份文件，只是入口路径不同。Mac 上做好的汉化，把 `Contents/Resources/` 整个 diff 应用到 Win 的 `resources\`，95% 都能直接生效。**

## 3. 操作顺序

### 3.1 强制使用中文

无论你的系统语言是什么，先让 Claude Desktop 锁定到 `zh-CN`，否则你的汉化文件根本不会被加载：

```bash
# macOS
python3 -c "
import json, pathlib
p = pathlib.Path.home()/'Library/Application Support/Claude-3p/config.json'
d = json.loads(p.read_text())
d['locale'] = 'zh-CN'
p.write_text(json.dumps(d, indent=2))
"
```

```powershell
# Windows
$cfg = "$env:APPDATA\Claude-3p\config.json"
$d = Get-Content $cfg -Raw | ConvertFrom-Json
$d.locale = "zh-CN"
$d | ConvertTo-Json -Depth 50 | Set-Content $cfg -Encoding utf8
```

### 3.2 补层 1（顶层 locale json）

通常已经存在 `en.json`，复制并翻译关键字段：

```bash
cp resources/en.json resources/zh-CN.json
# 然后手翻 / 用现成中文词库覆盖
```

这一层只覆盖 menu bar、系统通知、错误提示等 native 部分。

### 3.3 补层 3（ion-dist 词库，**最关键**）

这是 Claude Code、Cowork 等 React 部分的所有 UI 文案。如果只补层 1 不补层 3，就会出现"菜单中文 / 主界面英文"。

```bash
# 先看现有中文词库覆盖度
wc -l resources/ion-dist/i18n/zh-CN*.json resources/ion-dist/i18n/en*.json
```

如果 zh-CN 行数明显少于 en，说明中文词库未补全。用现成开源词库（社区 fork 通常有）覆盖。

      注：
      • 这一层是 React i18next 风格的扁平 key-value，可以直接 diff 英中两份找未翻译条目。
      • 千万不要把 en.json 改成中文 — 一旦用户切回英文，整个界面就坏了。

### 3.4 补层 2（仅 macOS）

`zh-Hans.lproj/Localizable.strings` 是 macOS 原生 NSString 资源。多数情况下连 Apple 系统菜单（Edit / Find / Preferences）的中文翻译。如果你的 fork 切到中文后这些菜单还是英文，就补这一层。

```bash
mkdir -p Claude-3p.app/Contents/Resources/zh-Hans.lproj
cp en.lproj/Localizable.strings zh-Hans.lproj/
# 手翻
```

### 3.5 补层 4（chunk 硬编码，**最后才碰**）

只有当层 1、3 都补全后仍然有英文卡死的字符串，才考虑改 chunk：

```bash
# 定位某条英文文案在哪些 chunk 里
rg "Open in new tab" resources/ion-dist/assets/v1/
```

每个 chunk 都是 webpack 输出的高混淆 bundle，改起来：

- 用 `sed` 或 `Edit` 工具按完整字符串字面量替换
- **不要按部分单词替换**，会改坏 React 内部逻辑
- 替换完不要破坏前后的语法结构（中文里有引号、反斜杠的要转义）

### 3.6 重打 asar + 校验

层 1-4 改完后，必须重打 `app.asar`（如果你的汉化文件在 asar 里）：

```bash
npx -y @electron/asar pack <unpacked-dir> resources/app.asar
```

然后按平台流程处理 integrity 和签名：

- macOS：`references/full-process-mac.md` §11、§14
- Windows：`references/full-process-windows.md` §10、§13

## 4. 常见汉化夹生状态

| 现象 | 漏补的层 |
|---|---|
| 系统菜单中文，对话区英文 | 层 3（ion-dist/i18n） |
| 系统菜单英文，对话区中文 | 层 1（顶层 locale） |
| macOS 应用菜单（Edit / View）英文 | 层 2 |
| 某个按钮永远英文 | 层 4（硬编码） |
| 切到日语完全变日语，切到中文不变 | 中文词库没补，但英语词库存在英语 fallback |
| 改完启动后看到 `[object Object]` | 层 3 JSON 里有语法错误（少逗号 / 引号不闭合） |

## 5. 把 Mac 汉化迁移到 Win（或反向）

因为层 1、3、4 是跨平台共用的，从一个平台到另一个平台只要：

```bash
# 假设你 Mac 上已经汉化好了
APP_MAC="$HOME/Applications/Claude-3p.app/Contents/Resources"
WIN_FORK_RESOURCES="/mnt/c/Users/<user>/AppData/Local/Claude-3p/app-<version>/resources"  # WSL 视角

# 复制层 1、3、4 的所有汉化产物
cp "$APP_MAC"/zh-CN.json                    "$WIN_FORK_RESOURCES"/
cp "$APP_MAC"/ion-dist/i18n/zh-CN*.json      "$WIN_FORK_RESOURCES"/ion-dist/i18n/
cp "$APP_MAC"/ion-dist/assets/v1/*.js        "$WIN_FORK_RESOURCES"/ion-dist/assets/v1/  # 只复制改过的那几个
```

层 2（`zh-Hans.lproj/`）不迁移。

## 6. 回滚

只回滚汉化、不动 patch：

```bash
# macOS
APP="$HOME/Applications/Claude-3p.app"
# 从原版 app 把对应文件拷回来
cp /Applications/Claude.app/Contents/Resources/zh-CN.json "$APP/Contents/Resources/" 2>/dev/null
cp -r /Applications/Claude.app/Contents/Resources/ion-dist/i18n/ "$APP/Contents/Resources/ion-dist/"
```

```powershell
# Windows
$SRC = "$env:LOCALAPPDATA\AnthropicClaude\app-<orig-version>\resources"
$DST = "$env:LOCALAPPDATA\Claude-3p\app-<version>\resources"
Copy-Item "$SRC\zh-CN.json" "$DST\" -ErrorAction SilentlyContinue
Copy-Item "$SRC\ion-dist\i18n\*" "$DST\ion-dist\i18n\" -Recurse -Force
```

如果汉化文件在 `app.asar` 内部，回滚后要重打包 + integrity + 签名。
