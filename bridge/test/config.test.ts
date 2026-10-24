import path from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';

afterEach(() => {
  vi.unstubAllEnvs();
  vi.resetModules();
});

describe('runtime configuration', () => {
  it('accepts a supported port, update rate and remote SimConnect endpoint', async () => {
    vi.stubEnv('SIMPILOT_PORT', '8381');
    vi.stubEnv('SIMPILOT_OWNSHIP_HZ', '20');
    vi.stubEnv('SIMPILOT_SIMCONNECT', '192.168.1.20:5111');
    vi.resetModules();
    const { config } = await import('../src/config.js');
    expect(config).toMatchObject({ port: 8381, ownshipHz: 20, simconnect: { host: '192.168.1.20', port: 5111 } });
  });

  it('keeps the packaged app\'s chart cache in local app data, wherever the exe was unzipped', async () => {
    vi.stubEnv('SIMPILOT_PACKAGED', '1');
    vi.stubEnv('LOCALAPPDATA', '/tmp/LocalAppData');
    vi.stubEnv('SIMPILOT_CACHE_DIR', undefined);
    vi.resetModules();
    const { config, packaged } = await import('../src/config.js');
    expect(packaged).toBe(true);
    expect(config.cacheDir).toBe(path.join('/tmp/LocalAppData', 'SimPilot Bridge', 'cache'));
  });

  it('caches next to the source checkout when run with npm start', async () => {
    vi.stubEnv('SIMPILOT_PACKAGED', undefined);
    vi.stubEnv('SIMPILOT_CACHE_DIR', undefined);
    vi.resetModules();
    const { config, packaged } = await import('../src/config.js');
    expect(packaged).toBe(false);
    expect(config.cacheDir).toBe(path.resolve(__dirname, '..', 'cache'));
  });

  it.each([
    ['SIMPILOT_PORT', '0'],
    ['SIMPILOT_PORT', '70000'],
    ['SIMPILOT_PORT', '8380garbage'],
    ['SIMPILOT_OWNSHIP_HZ', '-10'],
    ['SIMPILOT_OWNSHIP_HZ', '100000'],
    ['SIMPILOT_SIMCONNECT', 'host:5111extra'],
    ['SIMPILOT_SIMCONNECT', 'host:0'],
  ])('rejects invalid %s configuration instead of starting with misleading values', async (name, value) => {
    vi.stubEnv(name, value);
    vi.resetModules();
    await expect(import('../src/config.js')).rejects.toThrow(name);
  });
});
