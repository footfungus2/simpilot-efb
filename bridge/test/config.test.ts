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
