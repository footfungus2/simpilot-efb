import { randomBytes, timingSafeEqual } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

export function loadOrCreatePairingKey(file: string): string {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  try {
    const saved = fs.readFileSync(file, 'utf8').trim();
    if (/^[a-f0-9]{64}$/.test(saved)) return saved;
    throw new Error(`Invalid bridge pairing key at ${file}`);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
  }

  const key = randomBytes(32).toString('hex');
  try {
    fs.writeFileSync(file, key, { flag: 'wx', mode: 0o600 });
    return key;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;
    return loadOrCreatePairingKey(file);
  }
}

export function hasValidPairingKey(header: string | string[] | undefined, key: string): boolean {
  if (typeof header !== 'string') return false;
  const received = Buffer.from(header);
  const expected = Buffer.from(key);
  return received.length === expected.length && timingSafeEqual(received, expected);
}
