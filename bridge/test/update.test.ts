import { afterEach, describe, expect, it, vi } from 'vitest';
import { checkForUpdate, isNewer, updateScript } from '../src/update.js';

afterEach(() => vi.unstubAllGlobals());

describe('bridge updater', () => {
  it('orders versions, then builds', () => {
    expect(isNewer({ version: '0.2.0', build: 1 }, { version: '0.1.9', build: 99 })).toBe(true);
    expect(isNewer({ version: '0.1.0', build: 5 }, { version: '0.1.0', build: 4 })).toBe(true);
    expect(isNewer({ version: '0.1.0', build: 4 }, { version: '0.1.0', build: 4 })).toBe(false);
    expect(isNewer({ version: '0.1', build: 3 }, { version: '0.1.0', build: 3 })).toBe(false);
  });

  it('reports a newer release but cannot install outside the Windows download', async () => {
    vi.stubGlobal('fetch', async () => new Response(JSON.stringify({ version: '9.0.0', build: 7 })));
    const info = await checkForUpdate();
    expect(info).toMatchObject({ available: true, canInstall: false, latest: '9.0.0 (build 7)' });
  });

  it('rejects an unreadable manifest', async () => {
    vi.stubGlobal('fetch', async () => new Response(JSON.stringify({ version: '<script>', build: 1 })));
    await expect(checkForUpdate()).rejects.toThrow('unreadable');
  });

  it('keeps filesystem paths out of cmd arguments and checks files before copying', () => {
    const s = updateScript();
    expect(s).toContain('"%SIMPILOT_UPDATE_APP_DIR%"');
    expect(s).toContain('"%SIMPILOT_UPDATE_ZIP%"');
    expect(s).not.toContain('%~1');
    expect(s.indexOf('if not exist "%SRC%\\bridge.cjs"')).toBeLessThan(s.indexOf('robocopy "%SRC%" '));
  });

  it('installs the matching panel and setup guide with the new bridge', () => {
    const s = updateScript();
    const panelCheck = 'if not exist "%SRC%\\Chart panel (optional)\\PackageSources\\panel-assets.json" goto fail';
    const panelCopy = 'robocopy "%SRC%\\Chart panel (optional)" "%SIMPILOT_UPDATE_APP_DIR%\\Chart panel (optional)" /E';
    expect(s).toContain(panelCheck);
    expect(s).toContain(panelCopy);
    expect(s.indexOf(panelCheck)).toBeLessThan(s.indexOf(panelCopy));
    expect(s).toMatch(/node\.exe bridge\.cjs "SimPilot Bridge\*" "Read me\.txt"/);
  });
});
