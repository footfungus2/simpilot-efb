import { EventEmitter, once } from 'node:events';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import type { AddressInfo } from 'node:net';
import type { WebSocket } from 'ws';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ChartStore } from '../src/charts/store.js';
import { Hub } from '../src/hub.js';
import { logEntries, logger } from '../src/log.js';
import { createServer } from '../src/server.js';

class Socket extends EventEmitter {
  OPEN = 1;
  readyState = 1;
  bufferedAmount = 0;
  sent: any[] = [];
  send(raw: string) { this.sent.push(JSON.parse(raw)); }
  terminate() { this.readyState = 3; this.emit('close'); }
}

beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => vi.restoreAllMocks());

describe('diagnostic retention', () => {
  it('redacts account paths containing spaces without leaving a broken suffix', () => {
    logger('test').info('chart cache: C:\\Users\\First Last\\AppData\\Local\\SimPilot Bridge\\cache');
    expect(logEntries().at(-1)!.message).toBe('chart cache: ~');
  });
  it('redacts quoted JSON credentials and authorization values', () => {
    logger('test').error('{"token":"secret-value","username":"private-name","authorization":"Bearer topsecret"}');
    expect(logEntries().at(-1)!.message).not.toMatch(/secret-value|private-name|topsecret/);
  });

  it('bounds history and redacts secrets, signed URLs and account paths before output', () => {
    const log = logger('test');
    for (let i = 0; i < 205; i++) log.info(`entry ${i}`);
    log.error('token=secret password="hidden value" callsign=ABC123 ' +
      'https://account:password@charts.example/page.png?signature=private#fragment /Users/Someone/cache C:\\Users\\Someone\\cache', new Error('userid=12345'));
    const entries = logEntries();
    expect(entries).toHaveLength(200);
    expect(entries[0]!.message).toBe('entry 6');
    const last = entries.at(-1)!;
    expect(last.time).toMatch(/^\d{4}-\d{2}-\d{2}T/);
    expect(last.message).toContain('https://charts.example/page.png');
    expect(last.message).not.toMatch(/secret|hidden|ABC123|12345|Someone|signature|fragment|account:password/);
    expect(last.message).not.toContain('C:\\Users\\');
    expect(last.message).not.toContain('\\cache');
    expect(console.error).toHaveBeenLastCalledWith(expect.not.stringMatching(/secret|hidden|ABC123|12345|Someone|signature/));
    entries[0]!.message = 'changed by caller';
    expect(logEntries()[0]!.message).toBe('entry 6');
  });
});

describe('app message boundary', () => {
  it('ignores malformed messages without crashing, then accepts the next valid command', () => {
    const hub = new Hub();
    const socket = new Socket();
    const handle = vi.fn();
    hub.onMessage(handle);
    hub.addClient(socket as unknown as WebSocket, 'test');
    for (const raw of ['no JSON', 'null', '[]', '{}', '{"t":"lvarWatch","names":[{}]}', '{"t":"requestCharts","icao":"../../etc"}']) {
      expect(() => socket.emit('message', raw)).not.toThrow();
    }
    socket.emit('message', '{"t":"fenixTune","rmp":1,"khz":121800,"id":"one"}');
    expect(handle).toHaveBeenCalledTimes(1);
    socket.emit('close');
  });

  it('contains handler failures and drops slow clients instead of accumulating telemetry', () => {
    const hub = new Hub();
    const socket = new Socket();
    hub.onMessage(() => { throw new Error('failure'); });
    hub.addClient(socket as unknown as WebSocket, 'test');
    expect(() => socket.emit('message', '{"t":"lvarRun","code":"1 (>L:TEST)","id":"one"}')).not.toThrow();
    expect(socket.sent.at(-1)).toMatchObject({ t: 'commandResult', id: 'one', ok: false });
    socket.bufferedAmount = 2 * 1024 * 1024;
    hub.broadcastStatus();
    expect(socket.readyState).toBe(3);
  });

  it('does not replay old ownship to a newly connected iPad after simulator loss', () => {
    const hub = new Hub();
    hub.ownship({ lat: 51, lon: 0, altFt: 0, gsKt: 0, trkDeg: 0, hdgDeg: 0, vsFpm: 0, onGround: true, magVarDeg: 0, ts: 1 });
    hub.setSim(false);
    const socket = new Socket();
    hub.addClient(socket as unknown as WebSocket, 'test');
    expect(socket.sent.map((m) => m.t)).toEqual(['hello']);
    socket.emit('close');
  });
});

describe('HTTP boundary', () => {
  let dir: string;
  let server: ReturnType<typeof createServer>;
  let base: string;
  beforeEach(async () => {
    dir = await fs.mkdtemp(path.join(os.tmpdir(), 'simpilot-http-'));
    server = createServer(new Hub(), new ChartStore(dir));
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });
  afterEach(async () => {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await fs.rm(dir, { recursive: true, force: true });
  });

  it('returns redacted diagnostics on explicit request without caching them', async () => {
    logger('test').warn('username=private');
    const res = await fetch(`${base}/api/diagnostics`);
    expect(res.status).toBe(200);
    expect(res.headers.get('cache-control')).toBe('no-store');
    const body = await res.json() as { entries: { message: string }[] };
    expect(body.entries.length).toBeLessThanOrEqual(200);
    expect(body.entries.at(-1)!.message).toBe('username=[redacted]');
  });

  it('returns client errors for malformed URLs and JSON objects rather than rejecting the request handler', async () => {
    expect((await fetch(`${base}/api/charts/%ZZ`)).status).toBe(400);
    for (const body of ['null', '[]', '12', '{bad']) {
      const res = await fetch(`${base}/link/log`, { method: 'POST', body });
      expect(res.status).toBe(400);
    }
    expect((await fetch(`${base}/link/log`, { method: 'POST', body: JSON.stringify({ msg: 'a'.repeat(9000) }) })).status).toBe(413);
    expect((await fetch(`${base}/api/status`)).status).toBe(200);
  });

  it('blocks browser websites while retaining native and Coherent panel access', async () => {
    expect((await fetch(`${base}/api/status`, { headers: { origin: 'https://untrusted.example' } })).status).toBe(403);
    expect((await fetch(`${base}/link/poll`, { headers: { origin: 'coui://html_ui' } })).status).toBe(200);
    expect((await fetch(`${base}/link/poll`, { headers: { origin: 'null' } })).status).toBe(403);
    expect((await fetch(`${base}/api/diagnostics`, { headers: { origin: 'null' } })).status).toBe(403);
  });

  it('validates the complete weather box and hides internal cache errors', async () => {
    for (const bbox of ['1,2,3,4,5', '91,2,92,4', '1,,3,4', '3,2,1,4']) {
      expect((await fetch(`${base}/api/wx/metar?bbox=${bbox}`)).status).toBe(400);
    }
    await fs.mkdir(path.join(dir, 'charts', 'EDDF'), { recursive: true });
    await fs.writeFile(path.join(dir, 'charts', 'EDDF', 'index.json'), '{bad');
    const res = await fetch(`${base}/api/charts/EDDF`);
    expect(res.status).toBe(500);
    expect(await res.text()).not.toContain(dir);
  });
});
