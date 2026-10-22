import fs from 'node:fs';
import http from 'node:http';
import { WebSocketServer } from 'ws';
import { ChartLink } from './charts/link.js';
import { type ChartStore, safeIcao } from './charts/store.js';
import { HttpError, readJson, Router, sendJson, setCors } from './http.js';
import type { LVars } from './lvars.js';
import type { Hub } from './hub.js';
import { logger } from './log.js';
import { fetchOfp } from './simbrief.js';
import { metars, metarsInBox, parseIds, sigmets, tafs } from './weather.js';

const log = logger('http');

export function createServer(hub: Hub, store: ChartStore, lvars?: LVars): http.Server {
  const link = new ChartLink(store, hub);
  const router = new Router();

  hub.onMessage((msg) => {
    if (msg.t === 'requestCharts') void requestCharts(msg.icao);
    else if (msg.t === 'lvarWatch' && Array.isArray(msg.names)) {
      lvars?.watch(msg.names);
      const known = lvars?.snapshot(msg.names) ?? {};
      if (Object.keys(known).length) hub.broadcast({ t: 'lvars', values: known });
    } else if (msg.t === 'lvarRun' && typeof msg.code === 'string') void lvars?.run(msg.code, Number(msg.value ?? 0));
  });

  /** Queues a chart download unless the airport is already cached. */
  async function requestCharts(icaoRaw: string): Promise<'cached' | 'queued'> {
    const icao = safeIcao(icaoRaw);
    if (!link.isPending(icao) && (await store.getIndex(icao))) {
      hub.broadcast({ t: 'chartsReady', icao });
      return 'cached';
    }
    link.request(icao);
    return 'queued';
  }

  // ---- app ----
  router
    .add('GET', '/api/status', (_req, res) => sendJson(res, 200, hub.status()))
    .add('GET', '/api/ownship', (_req, res) => sendJson(res, hub.lastOwnship ? 200 : 204, hub.lastOwnship ?? null))
    .add('GET', '/api/charts/:icao', async (_req, res, p) => {
      const icao = safeIcao(p.icao!);
      const index = link.isPending(icao) ? undefined : await store.getIndex(icao);
      if (index) return sendJson(res, 200, index);
      await requestCharts(icao);
      sendJson(res, 202, { queued: true, linkConnected: hub.status().link.connected });
    })
    .add('GET', '/api/charts/:icao/:guid', async (_req, res, p) => {
      const chart = await store.getChart(p.icao!, p.guid!);
      if (!chart) throw new HttpError(404, 'chart not cached');
      sendJson(res, 200, chart);
    })
    .add('GET', '/charts/:icao/:guid/:page.png', (_req, res, p) => {
      const file = store.imagePath(p.icao!, p.guid!, Number(p.page));
      const stream = fs.createReadStream(file);
      stream.on('open', () => {
        // Chart images are immutable for a given GUID.
        res.writeHead(200, { 'content-type': 'image/png', 'cache-control': 'public, max-age=86400' });
        stream.pipe(res);
      });
      stream.on('error', () => sendJson(res, 404, { error: 'image not cached' }));
    })
    .add('GET', '/api/ofp', async (_req, res, _p, url) => sendJson(res, 200, await fetchOfp(url.searchParams.get('user') ?? '')))
    .add('GET', '/api/wx/metar', async (_req, res, _p, url) => {
      const bbox = url.searchParams.get('bbox');
      if (bbox) {
        const [a, b, c, d] = bbox.split(',').map(Number);
        if ([a, b, c, d].some((n) => n === undefined || !Number.isFinite(n))) throw new HttpError(400, 'bbox=minLat,minLon,maxLat,maxLon');
        return sendJson(res, 200, await metarsInBox(a!, b!, c!, d!));
      }
      sendJson(res, 200, await metars(parseIds(url.searchParams.get('ids'))));
    })
    .add('GET', '/api/wx/taf', async (_req, res, _p, url) => sendJson(res, 200, await tafs(parseIds(url.searchParams.get('ids')))))
    .add('GET', '/api/wx/sigmets', async (_req, res) => sendJson(res, 200, await sigmets()));

  // ---- in-sim link ----
  router
    .add('GET', '/link/poll', (_req, res) => sendJson(res, 200, link.poll()))
    .add('POST', '/link/index', async (req, res) => {
      await link.onIndex(await readJson(req));
      sendJson(res, 200, { ok: true });
    })
    .add('POST', '/link/pages', async (req, res) => {
      await link.onPages(await readJson(req));
      sendJson(res, 200, { ok: true });
    })
    .add('POST', '/link/image', async (req, res) => {
      sendJson(res, 200, { ok: true, saved: await link.onImage(await readJson(req)) });
    })
    .add('POST', '/link/done', async (req, res) => {
      link.onDone(await readJson(req));
      sendJson(res, 200, { ok: true });
    })
    .add('POST', '/link/log', async (req, res) => {
      const body = await readJson(req);
      const linkLog = logger('in-sim');
      (body.level === 'error' ? linkLog.error : body.level === 'warn' ? linkLog.warn : linkLog.info)(String(body.msg ?? ''));
      sendJson(res, 200, { ok: true });
    });

  const server = http.createServer(async (req, res) => {
    setCors(res);
    if (req.method === 'OPTIONS') {
      res.writeHead(204).end();
      return;
    }
    const url = new URL(req.url ?? '/', 'http://bridge');
    const m = router.match(req.method ?? 'GET', url.pathname);
    if (!m) return sendJson(res, 404, { error: 'not found' });
    try {
      await m.handler(req, res, m.params, url);
    } catch (err) {
      const status = err instanceof HttpError ? err.status : /^bad (ICAO|id|page)/.test((err as Error).message) ? 400 : 500;
      if (status >= 500) log.error(`${req.method} ${url.pathname} failed`, err);
      if (!res.headersSent) sendJson(res, status, { error: (err as Error).message });
      else res.end();
    }
  });

  const wss = new WebSocketServer({ noServer: true });
  server.on('upgrade', (req, socket, head) => {
    if (new URL(req.url ?? '/', 'http://bridge').pathname !== '/ws') {
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => hub.addClient(ws, req.socket.remoteAddress ?? '?'));
  });

  return server;
}
