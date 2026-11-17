import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { hasValidPairingKey, loadOrCreatePairingKey } from '../src/auth.js';

const dirs: string[] = [];
afterEach(() => { for (const dir of dirs.splice(0)) fs.rmSync(dir, { recursive: true, force: true }); });

describe('bridge pairing key', () => {
  it('creates a random key once and keeps it across restarts', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'simpilot-pairing-'));
    dirs.push(dir);
    const file = path.join(dir, 'config', 'pairing.key');
    const first = loadOrCreatePairingKey(file);
    expect(first).toMatch(/^[a-f0-9]{64}$/);
    expect(loadOrCreatePairingKey(file)).toBe(first);
  });

  it('compares credentials without accepting missing or altered values', () => {
    const key = 'a'.repeat(64);
    expect(hasValidPairingKey(key, key)).toBe(true);
    expect(hasValidPairingKey(undefined, key)).toBe(false);
    expect(hasValidPairingKey('b'.repeat(64), key)).toBe(false);
  });
});
