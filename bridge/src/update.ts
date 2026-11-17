import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { config, packaged } from './config.js';
import { logger } from './log.js';

const log = logger('update');
const REPO = 'https://github.com/footfungus2/simpilot-efb/releases';

export interface UpdateInfo { current: string; latest: string; available: boolean; canInstall: boolean; notes: string }

/** Same rule as the iPad app: a higher version wins, then a higher build of the same version. */
export function isNewer(remote: { version: string; build: number }, local: { version: string; build: number }): boolean {
  const num = (v: string) => v.split('.').map(Number);
  const [a, b] = [num(remote.version), num(local.version)];
  for (let i = 0; i < Math.max(a.length, b.length); i++) if ((a[i] ?? 0) !== (b[i] ?? 0)) return (a[i] ?? 0) > (b[i] ?? 0);
  return remote.build > local.build;
}

async function latestRelease(): Promise<{ version: string; build: number }> {
  const res = await fetch(`${REPO}/latest/download/update.json`, { signal: AbortSignal.timeout(15_000), headers: { accept: 'application/json' } });
  if (!res.ok) throw new Error(`GitHub answered ${res.status}`);
  const { version, build } = await res.json() as { version?: unknown; build?: unknown };
  if (typeof version !== 'string' || !/^\d+(\.\d+)*$/.test(version) || !Number.isInteger(build) || (build as number) < 1) throw new Error('unreadable update manifest');
  return { version, build: build as number };
}

export async function checkForUpdate(): Promise<UpdateInfo> {
  const latest = await latestRelease();
  const available = isNewer(latest, config.release);
  // Only the Windows download can replace itself; a source checkout updates with git.
  const canInstall = available && packaged && process.platform === 'win32';
  return {
    current: `${config.release.version} (build ${config.release.build})`, latest: `${latest.version} (build ${latest.build})`, available, canInstall,
    notes: !available ? 'SimPilot Bridge is up to date.' : canInstall ? 'An update is available.' : 'An update is available. Download SimPilot-for-PC.zip from the releases page.',
  };
}

/**
 * Downloads the newest SimPilot-for-PC.zip, then hands over to a script that waits for this process to exit (Windows
 * can't overwrite a running node.exe), copies the bridge files over the install folder and starts the bridge again.
 * Resolves once the script is running; the caller should then exit.
 */
export async function installUpdate(): Promise<void> {
  if (!packaged || process.platform !== 'win32') throw new Error('Updating in place only works in the Windows download.');
  const latest = await latestRelease();
  if (!isNewer(latest, config.release)) throw new Error('Already up to date.');
  const url = `${REPO}/download/v${latest.version}-build.${latest.build}/SimPilot-for-PC.zip`;
  log.info(`Downloading ${url}`);
  const res = await fetch(url, { signal: AbortSignal.timeout(300_000) });
  if (!res.ok) throw new Error(`Download failed (GitHub answered ${res.status})`);
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'simpilot-update-'));
  const zip = path.join(work, 'update.zip');
  fs.writeFileSync(zip, Buffer.from(await res.arrayBuffer()));
  const appDir = path.dirname(process.execPath);
  const script = path.join(work, 'update.cmd');
  fs.writeFileSync(script, updateScript(), 'utf8');
  // Keep filesystem paths out of cmd.exe's command text; the batch file reads them from its environment.
  spawn('cmd.exe', ['/d', '/c', 'update.cmd'], {
    cwd: work,
    env: {
      ...process.env,
      SIMPILOT_UPDATE_APP_DIR: appDir,
      SIMPILOT_UPDATE_ZIP: zip,
      SIMPILOT_UPDATE_EXTRACTED: path.join(work, 'x'),
    },
    detached: true, stdio: 'ignore', windowsHide: false,
  }).unref();
}

export function updateScript(): string {
  return [
    '@echo off', 'title Updating SimPilot Bridge',
    'echo Updating SimPilot Bridge...', 'ping -n 4 127.0.0.1 >nul',
    'mkdir "%SIMPILOT_UPDATE_EXTRACTED%" >nul 2>&1',
    'tar -xf "%SIMPILOT_UPDATE_ZIP%" -C "%SIMPILOT_UPDATE_EXTRACTED%" || goto fail',
    'set "SRC=%SIMPILOT_UPDATE_EXTRACTED%\\SimPilot for PC"',
    'if not exist "%SRC%\\node.exe" goto fail', 'if not exist "%SRC%\\bridge.cjs" goto fail',
    'if not exist "%SRC%\\Read me.txt" goto fail',
    'if not exist "%SRC%\\Chart panel (optional)\\PackageSources\\panel-assets.json" goto fail',
    'robocopy "%SRC%\\Chart panel (optional)" "%SIMPILOT_UPDATE_APP_DIR%\\Chart panel (optional)" /E /R:3 /W:1 >nul', 'if errorlevel 8 goto fail',
    'robocopy "%SRC%\\Source and notices" "%SIMPILOT_UPDATE_APP_DIR%\\Source and notices" /E /R:3 /W:1 >nul', 'if errorlevel 8 goto fail',
    // robocopy exit codes below 8 mean success; it retries while the old node.exe / launcher are still closing.
    'robocopy "%SRC%" "%SIMPILOT_UPDATE_APP_DIR%" node.exe bridge.cjs "SimPilot Bridge*" "Read me.txt" /R:30 /W:1 >nul', 'if errorlevel 8 goto fail',
    // The old zip's plain "SimPilot Bridge.cmd" would sit next to the new .exe under the same name when extensions are hidden.
    'if exist "%SIMPILOT_UPDATE_APP_DIR%\\SimPilot Bridge.exe" del "%SIMPILOT_UPDATE_APP_DIR%\\SimPilot Bridge.cmd" >nul 2>&1',
    'call :launch', 'exit /b 0',
    ':fail', 'echo.', 'echo The update did not finish. Try again or extract the complete SimPilot-for-PC.zip from GitHub.',
    'call :launch', 'pause', 'exit /b 1',
    ':launch', 'if exist "%SIMPILOT_UPDATE_APP_DIR%\\SimPilot Bridge.exe" (start "" "%SIMPILOT_UPDATE_APP_DIR%\\SimPilot Bridge.exe") else start "" "%SIMPILOT_UPDATE_APP_DIR%\\SimPilot Bridge.cmd"', 'exit /b 0', '',
  ].join('\r\n');
}
