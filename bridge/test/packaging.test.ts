import { spawnSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';
import { stripCertificate } from '../scripts/pe.mjs';

describe('Windows executable packaging', () => {
  function executable(magic = 0x20b) {
    const data = Buffer.alloc(1024, 0x42);
    data.write('MZ'); data.writeUInt32LE(64, 0x3c); data.writeUInt32LE(0x4550, 64);
    data.writeUInt16LE(240, 84); data.writeUInt16LE(magic, 88);
    const directories = magic === 0x20b ? 112 : 96;
    data.writeUInt32LE(16, 88 + directories - 4);
    const entry = 88 + directories + 32;
    data.writeUInt32LE(960, entry); data.writeUInt32LE(64, entry + 4);
    return { data, entry };
  }

  it('removes only the certificate, retaining the executable payload for both PE formats', () => {
    for (const magic of [0x10b, 0x20b]) {
      const { data, entry } = executable(magic);
      const stripped = stripCertificate(data);
      expect(stripped.length).toBe(960);
      expect(stripped.subarray(entry, entry + 8)).toEqual(Buffer.alloc(8));
      expect(stripped.subarray(400, 960)).toEqual(data.subarray(400, 960));
      expect(data.readUInt32LE(entry)).toBe(960);
      expect(stripCertificate(stripped)).toEqual(stripped);
    }
  });

  it('rejects truncated executables and certificate tables outside the file', () => {
    expect(() => stripCertificate(Buffer.alloc(10))).toThrow();
    const { data, entry } = executable();
    data.writeUInt32LE(2000, entry);
    expect(() => stripCertificate(data)).toThrow('certificate');
  });

  it('reports invalid configuration cleanly even in packaged mode', () => {
    const result = spawnSync(process.execPath, ['--import', 'tsx', 'src/index.ts'], {
      cwd: process.cwd(), env: { ...process.env, SIMPILOT_PACKAGED: '1', SIMPILOT_PORT: 'invalid' }, encoding: 'utf8', timeout: 15000,
    });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("SimPilot Bridge couldn't start: SIMPILOT_PORT must be an integer");
    expect(result.stderr).not.toContain('at envInt');
  });
});
