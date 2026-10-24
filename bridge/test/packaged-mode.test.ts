import { spawnSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';

describe('packaged bridge startup', () => {
  it('reports invalid configuration cleanly in packaged mode', () => {
    const result = spawnSync(process.execPath, ['--import', 'tsx', 'src/index.ts'], {
      cwd: process.cwd(), env: { ...process.env, SIMPILOT_PACKAGED: '1', SIMPILOT_PORT: 'invalid' }, encoding: 'utf8', timeout: 15000,
    });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("SimPilot Bridge couldn't start: SIMPILOT_PORT must be an integer");
    expect(result.stderr).not.toContain('at envInt');
  });
});
