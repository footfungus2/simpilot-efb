import fs from 'node:fs/promises';
import type { IncomingMessage, ServerResponse } from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { afterEach, describe, expect, it } from 'vitest';
import { ChartStore } from '../src/charts/store.js';
import { Hub } from '../src/hub.js';
import { cacheSummary, manage } from '../src/manage.js';
import { createServer } from '../src/server.js';

const hubs: Hub[] = [];
afterEach(() => { hubs.forEach((hub) => hub.close()); hubs.length = 0; });

function call(method: string, url: string, headers: Record<string, string> = {}, remoteAddress = '127.0.0.1') {
  const hub = new Hub();
  hubs.push(hub);
  const server = createServer(hub, new ChartStore('/unused'));
  return new Promise<{ status: number; body: string }>((resolve) => {
    const res = { status: 200, setHeader() {}, writeHead(status: number) { this.status = status; return this; }, end(body = '') { resolve({ status: this.status, body }); } };
    const req = Object.assign(Readable.from([]), { method, url, headers: { host: 'localhost:8386', ...headers }, socket: { remoteAddress } });
    server.emit('request', req as unknown as IncomingMessage, res as unknown as ServerResponse);
  });
}

describe('bridge window endpoints', () => {
  it('only lets the window on this PC run repairs', async () => {
    const post = (headers: Record<string, string>, remote?: string) => call('POST', '/bridge/manage/uninstall-nothing', headers, remote);
    expect((await post({})).status).toBe(403); // no header: a web page could send this
    expect((await post({ 'x-simpilot-ui': '1' }, '192.168.1.57')).status).toBe(403); // the iPad or anything else on the Wi-Fi
    expect((await post({ 'x-simpilot-ui': '1', host: 'evil.example' })).status).toBe(403); // DNS rebinding
    expect((await post({ 'x-simpilot-ui': '1' })).status).toBe(404); // allowed, but not an action
    await expect(manage('format-disk')).rejects.toThrow('unknown action');
  });

  it('lists cached airports with chart counts and size', async () => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'simpilot-cache-'));
    try {
      await fs.mkdir(path.join(root, 'charts', 'EGSS'), { recursive: true });
      await fs.writeFile(path.join(root, 'charts', 'EGSS', 'index.json'), JSON.stringify({ categories: [{ name: 'SID', charts: [{}, {}] }, { name: 'STAR', charts: [{}] }] }));
      const summary = await cacheSummary(root);
      expect(summary.airports).toMatchObject([{ icao: 'EGSS', charts: 3 }]);
      expect(summary.bytes).toBeGreaterThan(0);
      expect((await cacheSummary(path.join(root, 'missing'))).airports).toEqual([]);
    } finally { await fs.rm(root, { recursive: true, force: true }); }
  });
});
