import { execFile, spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { config, packaged } from './config.js';
import { HttpError } from './http.js';

const win = process.platform === 'win32';
const RUN_KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run';
const RULE = 'SimPilot Bridge';
/** Folder holding the launcher, node.exe and bridge.cjs (the unzipped "SimPilot for PC"). */
const appDir = () => path.dirname(process.execPath);

const run = (file: string, args: string[]) => new Promise<{ ok: boolean; out: string }>((resolve) =>
  execFile(file, args, { windowsHide: true, timeout: 120_000 }, (err, stdout) => resolve({ ok: !err, out: String(stdout) })));

/** Adapters in the order to show them: Wi-Fi/Ethernet first, VPN and virtual ones last. */
export function lanAddresses(port: number): { name: string; address: string }[] {
  const virtual = /vpn|virtual|vethernet|vmware|wsl|tun|docker/i;
  return Object.entries(os.networkInterfaces())
    .flatMap(([name, entries]) => (entries ?? []).filter((i) => i.family === 'IPv4' && !i.internal).map((i) => ({ name, address: `${i.address}:${port}` })))
    .sort((a, b) => Number(virtual.test(a.name)) - Number(virtual.test(b.name)));
}

async function dirBytes(dir: string): Promise<number> {
  let total = 0;
  for (const entry of await fs.readdir(dir, { withFileTypes: true, recursive: true }).catch(() => [])) {
    if (entry.isFile()) total += (await fs.stat(path.join(entry.parentPath, entry.name)).catch(() => undefined))?.size ?? 0;
  }
  return total;
}

/** What the Charts page lists: one row per airport in the cache. */
export async function cacheSummary(root: string) {
  const base = path.join(root, 'charts');
  const airports = [];
  for (const icao of await fs.readdir(base).catch(() => [] as string[])) {
    const index = JSON.parse(await fs.readFile(path.join(base, icao, 'index.json'), 'utf8').catch(() => '{}'));
    const charts = Array.isArray(index.categories) ? index.categories.reduce((n: number, c: { charts?: unknown[] }) => n + (c.charts?.length ?? 0), 0) : 0;
    airports.push({ icao, charts, bytes: await dirBytes(path.join(base, icao)) });
  }
  return { airports, bytes: airports.reduce((sum, a) => sum + a.bytes, 0) };
}

export async function bridgeInfo() {
  const exists = (p: string) => fs.access(p).then(() => true, () => false);
  const autostart = win ? (await run('reg', ['query', RUN_KEY, '/v', RULE])).ok : false;
  return {
    hostname: os.hostname(), addresses: lanAddresses(config.port), cache: await cacheSummary(config.cacheDir),
    autostart, windows: win, panelFolder: packaged && await exists(path.join(appDir(), 'Chart panel (optional)')),
  };
}

/** Elevated netsh through PowerShell: Windows shows its own admin prompt. */
const netsh = (...args: string[]) =>
  run('powershell.exe', ['-NoProfile', '-Command', `Start-Process netsh -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList ${args.map((a) => `'${a}'`).join(',')}`]);
const ruleArgs = ['advfirewall', 'firewall'];
const openFile = (target: string) => spawn('cmd.exe', ['/c', `start "" "${target}"`], { windowsVerbatimArguments: true, detached: true, stdio: 'ignore' }).unref();

async function panelScript(name: string): Promise<string> {
  const file = path.join(appDir(), 'Chart panel (optional)', name);
  if (!(await fs.access(file).then(() => true, () => false))) throw new HttpError(404, 'The chart panel folder is missing. Use the full SimPilot-for-PC.zip.');
  return file;
}

const ACTIONS = ['clear-cache', 'open-cache', 'autostart-on', 'autostart-off', 'firewall', 'panel-install', 'panel-repair', 'uninstall'] as const;

/** Runs one Repair/Settings action from the bridge window. Returns the message to show. */
export async function manage(action: string): Promise<string> {
  if (!(ACTIONS as readonly string[]).includes(action)) throw new HttpError(404, 'unknown action');
  if (action === 'clear-cache') {
    await fs.rm(path.join(config.cacheDir, 'charts'), { recursive: true, force: true });
    return 'Chart cache cleared.';
  }
  if (!win) throw new HttpError(501, 'This only works in SimPilot Bridge on Windows.');
  switch (action) {
    case 'open-cache': await fs.mkdir(config.cacheDir, { recursive: true }); openFile(config.cacheDir); return 'Opened the cache folder.';
    case 'autostart-on':
      if (!(await run('reg', ['add', RUN_KEY, '/v', RULE, '/d', `"${path.join(appDir(), 'SimPilot Bridge.exe')}" --minimized`, '/f'])).ok) throw new HttpError(500, "Couldn't change Start with Windows.");
      return 'SimPilot Bridge will start with Windows.';
    case 'autostart-off': await run('reg', ['delete', RUN_KEY, '/v', RULE, '/f']); return 'Start with Windows is off.';
    case 'firewall':
      await netsh(...ruleArgs, 'delete', 'rule', `name="${RULE}"`);
      await netsh(...ruleArgs, 'add', 'rule', `name="${RULE}"`, 'dir=in', 'action=allow', 'protocol=TCP', `localport=${config.port}`, 'profile=private');
      return (await run('netsh', [...ruleArgs, 'show', 'rule', `name=${RULE}`])).ok ? 'Firewall rule added for private networks.' : 'The firewall rule was not added. Allow the Windows admin prompt and try again.';
    case 'panel-install': openFile(await panelScript('Install SimPilot Link.bat')); return 'Close MSFS 2024, then follow the window that opened.';
    case 'panel-repair': openFile(await panelScript('Repair SimPilot Link.bat')); return 'Follow the window that opened.';
    default: { // uninstall
      await run('reg', ['delete', RUN_KEY, '/v', RULE, '/f']);
      if ((await run('netsh', [...ruleArgs, 'show', 'rule', `name=${RULE}`])).ok) await netsh(...ruleArgs, 'delete', 'rule', `name="${RULE}"`);
      // Only the packaged app owns its parent folder; a dev cache dir may sit inside something else.
      await fs.rm(packaged ? path.dirname(config.cacheDir) : config.cacheDir, { recursive: true, force: true });
      setTimeout(() => process.exit(0), 500);
      return 'Removed autostart, the firewall rule and cached charts. Delete the SimPilot for PC folder to finish.';
    }
  }
}
