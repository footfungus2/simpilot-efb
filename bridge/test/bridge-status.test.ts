import fs from 'node:fs/promises';
import type { IncomingMessage, ServerResponse } from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import vm from 'node:vm';
import { transformSync } from 'esbuild';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { ChartStore } from '../src/charts/store.js';
import { config } from '../src/config.js';
import { Hub } from '../src/hub.js';
import { createServer } from '../src/server.js';

const hubs: Hub[] = [];
afterEach(() => { hubs.forEach((hub) => hub.close()); hubs.length = 0; vi.restoreAllMocks(); });

function bridge(store = new ChartStore('/unused')) {
  const hub = new Hub();
  hubs.push(hub);
  const server = createServer(hub, store, 'test-pairing-key', undefined, undefined, { tile: async () => {}, finish: async () => Buffer.alloc(0) });
  function request(url: string, origin = 'coui://html_ui', method = 'GET', body?: string, token = 'test-pairing-key', remoteAddress = '127.0.0.1') {
    return new Promise<{ status: number; headers: Record<string, string>; body: any }>((resolve) => {
      const headers: Record<string, string> = {};
      const response = {
        status: 200,
        setHeader(name: string, value: string) { headers[name] = value; },
        writeHead(status: number, values?: Record<string, string>) { this.status = status; Object.assign(headers, values); return this; },
        end(data?: string) { resolve({ status: this.status, headers, body: data ? JSON.parse(data) : undefined }); },
      };
      const requestHeaders: Record<string, string> = { origin, host: '127.0.0.1:8386' };
      if (token) requestHeaders['x-simpilot-token'] = token;
      const incoming = Object.assign(Readable.from(body ? [body] : []), { method, url, headers: requestHeaders, socket: { remoteAddress } });
      server.emit('request', incoming as unknown as IncomingMessage, response as unknown as ServerResponse);
    });
  }
  return { hub, server, get: request, request };
}

describe('read-only bridge identity', () => {
  it('reports the running build and bound port without marking the panel connected', async () => {
    const { hub, server, get } = bridge();
    const seen = vi.spyOn(hub, 'linkSeen');
    vi.spyOn(server, 'address').mockReturnValue({ address: '127.0.0.1', family: 'IPv4', port: 48386 });
    hub.setSim(true, 'Fenix A320');
    const status = await get('/api/status');
    expect(status.status).toBe(200);
    expect(status.headers['cache-control']).toBe('no-store');
    expect(status.body).toMatchObject({
      bridge: { name: 'SimPilot Bridge', version: config.bridgeVersion, buildId: config.buildId, linkProtocol: 3, port: 48386 },
      sim: { connected: true, aircraftTitle: 'Fenix A320' }, link: { connected: false },
    });
    expect(status.body.bridge.buildId).toMatch(/^sha256:[a-f0-9]{64}$/);
    await get('/api/status');
    expect(seen).not.toHaveBeenCalled();
  });

  it('keeps status public but requires pairing for flight data and rejects other localhost origins', async () => {
    const { get } = bridge();
    expect((await get('/api/status', 'http://127.0.0.1:8386', 'GET', undefined, '')).status).toBe(200);
    expect((await get('/api/ownship', 'http://127.0.0.1:8386', 'GET', undefined, '')).status).toBe(401);
    expect((await get('/api/ownship')).status).toBe(204);
    expect((await get('/api/status', 'http://localhost:3000', 'GET', undefined, '')).status).toBe(403);
  });

  it('rejects bridge data over unencrypted LAN HTTP', async () => {
    const { get } = bridge();
    const response = await get('/api/status', undefined, 'GET', undefined, '', '192.168.1.57');
    expect(response.status).toBe(403);
    expect(response.body.error).toContain('requires HTTPS');
  });

  it('rejects an incompatible protocol without reporting a usable chart link', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const { hub, get } = bridge();
    const response = await get('/link/poll?proto=1');
    expect(response.status).toBe(409);
    expect(response.body.error).toMatch(/protocol 1.*expected 3/);
    expect(hub.status().link.connected).toBe(false);
  });

  it('preserves the bridge Origin rejection instead of disguising it as a missing server', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const { get } = bridge();
    const response = await get('/api/status', 'https://untrusted.example');
    expect(response.status).toBe(403);
    expect(response.body.error).toContain('unsupported Origin');
  });

  it('connects the real panel through the read-only identity check before its first work poll', async () => {
    vi.spyOn(console, 'log').mockImplementation(() => {});
    const { hub, request } = bridge();
    const status = { textContent: 'searching…', className: '' };
    const requests: string[] = [];
    const source = await fs.readFile(path.resolve(import.meta.dirname, '../../sim-package/src/link.ts'), 'utf8');
    vm.runInNewContext(transformSync(source, { loader: 'ts', format: 'cjs', target: 'es2017' }).code, {
      module: { exports: {} }, require: () => ({}), setTimeout, clearTimeout, setInterval() {},
      document: { getElementById: (id: string) => id === 'spl-bridge' ? status : null },
      TemplateElement: class {}, window: { customElements: { define() {} } }, checkAutoload() {},
      XMLHttpRequest: class {
        private url = '';
        private method = '';
        status = 0;
        responseText = '';
        onload?: () => void;
        open(method: string, url: string) { this.method = method; this.url = new URL(url).pathname + new URL(url).search; }
        setRequestHeader() {}
        send(body?: string) {
          requests.push(this.url);
          void request(this.url, 'coui://html_ui', this.method, body).then((response) => {
            this.status = response.status;
            this.responseText = JSON.stringify(response.body);
            this.onload?.();
          });
        }
      },
    });
    for (let i = 0; i < 20 && status.textContent !== 'connected'; i++) await new Promise(setImmediate);
    await new Promise(setImmediate);
    expect(requests.slice(0, 2)).toEqual(['/api/status', '/link/poll?proto=3']);
    expect(status.textContent).toBe('connected');
    expect(hub.status().link.connected).toBe(true);
  });

  it('continues serving a cached chart after a refresh is refused with the panel closed', async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'simpilot-refresh-'));
    try {
      const store = new ChartStore(dir);
      const chart = { guid: 'chart-1', type: 'IAC', name: 'Test approach', runways: [], procedures: [], geoReferenced: false };
      await store.saveIndex({ icao: 'EDDF', provider: 'LIDO', fetchedAt: Date.now(), categories: [{ name: 'IAC', charts: [chart] }] });
      await store.savePages('EDDF', chart.guid, [{ index: 0, width: 10, height: 10, areas: [], geoReferenced: false }]);
      await store.saveImage('EDDF', chart.guid, 0, Buffer.from('89504e470d0a1a0a00', 'hex'));
      const { get } = bridge(store);
      const path = '/api/charts/EDDF/chart-1';
      const cached = await get(path);
      expect(cached.status).toBe(200);
      expect((await get(path + '?refresh=1')).status).toBe(409);
      expect(await get(path)).toEqual(cached);
    } finally {
      await fs.rm(dir, { recursive: true, force: true });
    }
  });
});
