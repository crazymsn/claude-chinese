#!/usr/bin/env node
/*
 * detect_platform.js — 跨平台探针
 *
 * 用法：
 *   node scripts/detect_platform.js           人类可读输出
 *   node scripts/detect_platform.js --json    JSON 输出（脚本管道用）
 *
 * 检测：
 *   - OS (macOS / Windows / Linux)
 *   - 架构
 *   - 已安装的 Claude Desktop 原版 + 任何 fork
 *   - Claude Desktop 版本
 *   - userData 目录、configLibrary、当前最近修改的 provider 配置
 *
 * 然后打印：
 *   - 应该读哪份 reference doc
 *   - 应该用哪几个 scripts
 *   - 具体可粘贴的下一步命令
 *
 * 这是本 skill 所有动手步骤的入口。Mac / Win 用户跑同一个命令。
 */

const os   = require('os');
const fs   = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

function safeReadDir(p) {
  try { return fs.readdirSync(p); } catch (_) { return []; }
}

function safeStat(p) {
  try { return fs.statSync(p); } catch (_) { return null; }
}

function findMacInstall() {
  const orig  = [
    '/Applications/Claude.app',
    path.join(os.homedir(), 'Applications/Claude.app'),
  ];
  const forks = [
    path.join(os.homedir(), 'Applications/Claude-3p.app'),
    path.join(os.homedir(), 'Applications/Claude-Deepseek.app'),
  ];
  const result = { original: null, forks: [] };
  for (const p of orig)  if (safeStat(p)) { result.original = p; break; }
  for (const p of forks) if (safeStat(p)) result.forks.push(p);
  return result;
}

function findWinInstall() {
  const localAppData = process.env.LOCALAPPDATA || '';
  const origRoots = [
    path.join(localAppData, 'AnthropicClaude'),
    path.join(localAppData, 'Programs', 'Claude'),
  ];
  const forkRoots = [
    path.join(localAppData, 'Claude-3p'),
  ];
  const result = { original: null, forks: [] };

  function latestVersionedSubdir(root) {
    if (!safeStat(root)) return null;
    const versions = safeReadDir(root).filter(n => /^app-\d/.test(n)).sort();
    if (!versions.length) return null;
    return path.join(root, versions[versions.length - 1]);
  }

  for (const r of origRoots) {
    const p = latestVersionedSubdir(r);
    if (p) { result.original = p; break; }
  }
  for (const r of forkRoots) {
    const p = latestVersionedSubdir(r);
    if (p) result.forks.push(p);
  }
  return result;
}

function readMacVersion(appPath) {
  // 用 execFile 而不是 exec，避免任何 shell 解析
  try {
    const plist = path.join(appPath, 'Contents', 'Info.plist');
    return execFileSync(
      '/usr/libexec/PlistBuddy',
      ['-c', 'Print :CFBundleShortVersionString', plist],
      { stdio: ['ignore', 'pipe', 'ignore'] }
    ).toString().trim();
  } catch (_) { return null; }
}

function readWinVersion(appPath) {
  // 路径形如 .../app-1.6608.2
  const base = path.basename(appPath);
  const m = /^app-(.+)$/.exec(base);
  return m ? m[1] : null;
}

function findProviderConfig(userDataDir) {
  if (!userDataDir || !safeStat(userDataDir)) return { dir: null, active: null };
  const cfgDir = path.join(userDataDir, 'configLibrary');
  if (!safeStat(cfgDir)) return { dir: null, active: null };
  const jsonFiles = safeReadDir(cfgDir).filter(n => n.endsWith('.json'));
  if (!jsonFiles.length) return { dir: cfgDir, active: null };
  let latest = null;
  let latestMtime = -1;
  for (const f of jsonFiles) {
    const full = path.join(cfgDir, f);
    const st = safeStat(full);
    if (st && st.mtimeMs > latestMtime) { latest = full; latestMtime = st.mtimeMs; }
  }
  return { dir: cfgDir, active: latest };
}

function detect() {
  const platform = os.platform();
  const platformName = ({ darwin: 'macOS', win32: 'Windows', linux: 'Linux' })[platform] || platform;

  const result = {
    platform,
    platformName,
    arch          : os.arch(),
    nodeVersion   : process.version,
    homedir       : os.homedir(),

    install       : { original: null, forks: [] },
    version       : null,
    userDataDir   : null,
    forkUserDataDir: null,
    providerConfig: { dir: null, active: null },

    recommendedDoc    : null,
    recommendedScripts: [],
    nextCommands      : [],
    warnings          : [],
  };

  if (platform === 'darwin') {
    result.install         = findMacInstall();
    result.userDataDir     = path.join(os.homedir(), 'Library', 'Application Support', 'Claude');
    result.forkUserDataDir = path.join(os.homedir(), 'Library', 'Application Support', 'Claude-3p');
    if (result.install.original) result.version = readMacVersion(result.install.original);
    result.recommendedDoc     = 'references/full-process-mac.md';
    result.recommendedScripts = [
      'scripts/apply_patches.sh',
      'scripts/verify_claude_fork.sh',
      'scripts/list_models.sh',
    ];

    const forkPath = path.join(os.homedir(), 'Applications', 'Claude-3p.app');
    result.nextCommands = [
      `bash scripts/list_models.sh https://api.meding.site <api-key>`,
      `bash scripts/apply_patches.sh "${forkPath}"`,
      `bash scripts/verify_claude_fork.sh "${forkPath}"`,
    ];
  } else if (platform === 'win32') {
    result.install         = findWinInstall();
    result.userDataDir     = path.join(process.env.APPDATA || '', 'Claude');
    result.forkUserDataDir = path.join(process.env.APPDATA || '', 'Claude-3p');
    if (result.install.original) result.version = readWinVersion(result.install.original);
    result.recommendedDoc     = 'references/full-process-windows.md';
    result.recommendedScripts = [
      'scripts\\apply_patches.ps1',
      'scripts\\verify_claude_fork.ps1',
      'scripts\\list_models.ps1',
    ];

    const forkPath = result.install.forks[0] ||
                     path.join(process.env.LOCALAPPDATA || '', 'Claude-3p',
                               result.install.original ? `app-${result.version}` : 'app-<version>');
    result.nextCommands = [
      `.\\scripts\\list_models.ps1 -BaseUrl https://api.meding.site -ApiKey <api-key>`,
      `.\\scripts\\apply_patches.ps1 -InstallDir "${forkPath}"`,
      `.\\scripts\\verify_claude_fork.ps1 -InstallDir "${forkPath}"`,
    ];
  } else {
    result.recommendedDoc = '(unsupported platform — this skill targets macOS and Windows)';
    result.warnings.push(`Platform "${platform}" not supported by this skill.`);
  }

  // 优先用 fork 的 userData 找 provider config，找不到再用原版
  const cfgRoot = safeStat(result.forkUserDataDir) ? result.forkUserDataDir : result.userDataDir;
  result.providerConfig = findProviderConfig(cfgRoot);

  if (!result.install.original && !result.install.forks.length) {
    result.warnings.push('Claude Desktop not detected in any standard install location. Download from https://claude.ai/download');
  }

  return result;
}

function formatHuman(d) {
  const bar = '='.repeat(64);
  const out = [];

  out.push(bar);
  out.push('  Claude Desktop 3P fork — platform detection');
  out.push(bar);
  out.push('');
  out.push(`  Platform            : ${d.platformName}  (${d.platform})`);
  out.push(`  Architecture        : ${d.arch}`);
  out.push(`  Node.js             : ${d.nodeVersion}`);
  out.push(`  Home                : ${d.homedir}`);
  out.push('');
  out.push('  --- Claude Desktop installs --------------------------------');
  out.push(`  Original            : ${d.install.original || '(not found)'}`);
  if (d.version) out.push(`  Version             : ${d.version}`);
  if (d.install.forks.length) {
    out.push(`  Forks detected      :`);
    for (const f of d.install.forks) out.push(`    - ${f}`);
  } else {
    out.push(`  Forks detected      : (none yet)`);
  }
  out.push('');
  out.push('  --- User data ----------------------------------------------');
  out.push(`  Original userData   : ${d.userDataDir}${safeStat(d.userDataDir) ? '' : '  (does not exist)'}`);
  out.push(`  Fork userData       : ${d.forkUserDataDir}${safeStat(d.forkUserDataDir) ? '' : '  (does not exist)'}`);
  out.push(`  configLibrary       : ${d.providerConfig.dir || '(none)'}`);
  out.push(`  Active provider cfg : ${d.providerConfig.active || '(none — needs to be created)'}`);
  out.push('');

  if (d.warnings.length) {
    out.push('  --- Warnings -----------------------------------------------');
    for (const w of d.warnings) out.push(`  !  ${w}`);
    out.push('');
  }

  out.push(bar);
  out.push('  Next steps for THIS platform');
  out.push(bar);
  out.push('');
  out.push(`  Read this doc       : ${d.recommendedDoc}`);
  if (d.recommendedScripts.length) {
    out.push(`  Use these scripts   :`);
    for (const s of d.recommendedScripts) out.push(`    - ${s}`);
  }
  out.push('');
  if (d.nextCommands.length) {
    out.push('  Suggested commands  :');
    for (const c of d.nextCommands) out.push(`    $ ${c}`);
    out.push('');
  }
  out.push(bar);
  return out.join('\n');
}

const args = process.argv.slice(2);
const result = detect();

if (args.includes('--json')) {
  process.stdout.write(JSON.stringify(result, null, 2) + '\n');
} else {
  process.stdout.write(formatHuman(result) + '\n');
}

// 退出码：0 正常；2 平台不支持；3 没找到 Claude Desktop
if (result.platform !== 'darwin' && result.platform !== 'win32') process.exit(2);
if (!result.install.original && !result.install.forks.length)    process.exit(3);
process.exit(0);
