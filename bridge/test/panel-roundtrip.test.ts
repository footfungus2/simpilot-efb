import { once } from 'node:events';
import fs from 'node:fs/promises';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { transformSync } from 'esbuild';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Capturer } from '../src/charts/capture.js';
import { ChartStore } from '../src/charts/store.js';
import { Hub } from '../src/hub.js';
import { createServer } from '../src/server.js';

// Runs the real SimPilot Link panel script (sim-package/src/link.ts) against the real bridge server, with the sim's
// chart calls and the screen capture faked, so the two halves of the protocol are checked against each other.

const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(16)]);
const panelSource = path.resolve(import.meta.dirname, '../../sim-package/src/link.ts');

const simCharts = {
  getIndexForAirport: async (icao: string) => ({
    airportIcao: { ident: icao },
    charts: [{ name: 'SID', charts: [{ guid: '{sid-1}', type: 'SID', name: 'TEST 1A', procedures: [{ type: 0, ident: 'TEST1A' }], runways: [] }] }],
  }),
  getChartPages: async () => ({
    pages: [1, 2].map((n) => ({ width: 1000, height: 1400, geoReferenced: false, areas: [], urls: [{ name: 'PNG', url: `https://charts.invalid/${n}.png` }] })),
  }),
  loadChartLiveView: async () => ({ imageUrl: 'live-view', release() {} }),
};

describe('SimPilot Link panel and bridge together', () => {
  let dir: string;
  let hub: Hub;
  let server: http.Server;
  let base: string;
  let tick: () => void;
  let tiles = 0;

  /** The panel polls on a timer in the sim; here the test pokes it until what it waits for has happened. */
  async function until(done: () => boolean) {
    for (let i = 0; i < 400 && !done(); i++) {
      tick();
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    expect(done()).toBe(true);
  }
  const sent = (t: string) => (hub.broadcast as ReturnType<typeof vi.fn>).mock.calls.filter(([m]) => m.t === t);

  beforeEach(async () => {
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    dir = await fs.mkdtemp(path.join(os.tmpdir(), 'simpilot-roundtrip-'));
    hub = new Hub();
    vi.spyOn(hub, 'broadcast');
    const capturer: Capturer = { tile: async () => void tiles++, finish: async () => png };
    server = createServer(hub, new ChartStore(dir), undefined, undefined, capturer);
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

    class XHR {
      timeout = 0;
      status = 0;
      responseText = '';
      onload?: () => void;
      onerror?: () => void;
      private method = '';
      private url = '';
      open(method: string, url: string) { this.method = method; this.url = url; }
      setRequestHeader() {}
      send(body: string | null) {
        const req = http.request(this.url, { method: this.method, headers: body ? { 'content-type': 'application/json' } : {} }, (res) => {
          const chunks: Buffer[] = [];
          res.on('data', (c: Buffer) => chunks.push(c));
          res.on('end', () => {
            this.status = res.statusCode ?? 0;
            this.responseText = Buffer.concat(chunks).toString();
            this.onload?.();
          });
        });
        req.on('error', () => this.onerror?.());
        req.end(body);
      }
    }
    const image = { style: {}, naturalWidth: 1000, naturalHeight: 1400, setAttribute() {}, _src: '', onload: undefined as undefined | (() => void),
      get src() { return this._src; }, set src(v: string) { this._src = v; if (v) queueMicrotask(() => this.onload?.()); } };
    const element = () => ({ style: {}, setAttribute() {}, appendChild() {}, clientWidth: 600, clientHeight: 400 });
    const code = transformSync(await fs.readFile(panelSource, 'utf8'), { loader: 'ts', format: 'cjs', target: 'es2017' }).code
      .replace('PORT = 8386', `PORT = ${new URL(base).port}`);
    vm.runInNewContext(code, {
      module: { exports: {} },
      require: () => simCharts,
      setTimeout: (fn: () => void, ms: number) => setTimeout(fn, Math.min(ms, 20)),
      clearTimeout,
      queueMicrotask,
      setInterval: (fn: () => void) => { tick = fn; return 0; },
      XMLHttpRequest: XHR,
      document: { getElementById: () => null, body: { appendChild() {} }, createElement: (tag: string) => (tag === 'img' ? image : element()) },
      TemplateElement: class {},
      window: { customElements: { define() {} } },
      checkAutoload() {},
    });
  });
  afterEach(async () => {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    hub.close();
    vi.restoreAllMocks();
    await fs.rm(dir, { recursive: true, force: true });
  });

  it('lists an airport, exports a chart when it is opened and exports it again on request', async () => {
    const get = (p: string) => fetch(`${base}${p}`);
    expect((await get('/api/charts/EGSS')).status).toBe(202);
    await until(() => sent('chartsReady').length === 1);
    const index = await (await get('/api/charts/EGSS')).json() as { categories: { charts: { guid: string; procedures: string[] }[] }[] };
    expect(index.categories[0]!.charts[0]).toMatchObject({ guid: '{sid-1}', procedures: ['TEST1A'] });
    expect(tiles).toBe(0); // listing needs no screen capture

    expect((await get('/api/charts/EGSS/%7Bsid-1%7D')).status).toBe(202);
    await until(() => sent('chartReady').length === 1);
    expect(sent('chartProgress').map(([m]) => m.done)).toEqual([0, 1, 2]);
    const chart = await (await get('/api/charts/EGSS/%7Bsid-1%7D')).json() as { pages: { image: string }[] };
    expect(chart.pages).toHaveLength(2);
    for (const page of chart.pages) expect(Buffer.from(await (await get(page.image)).arrayBuffer()).subarray(1, 4).toString()).toBe('PNG');
    expect(tiles).toBeGreaterThan(2);

    const before = tiles;
    expect((await get('/api/charts/EGSS/%7Bsid-1%7D?refresh=1')).status).toBe(202);
    await until(() => sent('chartReady').length === 2);
    expect(tiles).toBeGreaterThan(before);
    expect((await get('/api/charts/EGSS/%7Bsid-1%7D')).status).toBe(200);
    expect(sent('chartError')).toEqual([]);
    expect((await get('/api/status').then((r) => r.json())) as { link: { connected: boolean } }).toMatchObject({ link: { connected: true } });
  }, 20_000);
});
