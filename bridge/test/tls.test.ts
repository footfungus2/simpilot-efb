import fs from 'node:fs/promises';
import https from 'node:https';
import os from 'node:os';
import path from 'node:path';
import { createSecureContext } from 'node:tls';
import { afterEach, describe, expect, it } from 'vitest';
import { ChartStore } from '../src/charts/store.js';
import { Hub } from '../src/hub.js';
import { createSecureServer, createServer } from '../src/server.js';
import { loadOrCreateTls } from '../src/tls.js';

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map((root) => fs.rm(root, { recursive: true, force: true }))); });

describe('bridge TLS identity', () => {
  it('creates a decryptable certificate and keeps its fingerprint stable', async () => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'simpilot-tls-'));
    roots.push(root);
    const dir = path.join(root, 'tls');
    const pairingKey = 'a'.repeat(64);
    const first = await loadOrCreateTls(dir, pairingKey);
    expect(first.fingerprint).toMatch(/^[a-f0-9]{64}$/);
    expect(() => createSecureContext({ pfx: first.pfx, passphrase: pairingKey })).not.toThrow();
    expect((await fs.readdir(dir)).sort()).toEqual(['bridge.pfx', 'fingerprint.sha256']);

    const second = await loadOrCreateTls(dir, pairingKey);
    expect(second.fingerprint).toBe(first.fingerprint);

    const hub = new Hub();
    const local = createServer(hub, new ChartStore(path.join(root, 'cache')), pairingKey);
    const secure = createSecureServer(local, first, hub, pairingKey);
    expect(secure).toBeInstanceOf(https.Server);
    expect(secure.listeners('request')[0]).toBe(local.listeners('request')[0]);
    hub.close();
  });
});
