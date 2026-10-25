import fs from 'node:fs';
import http from 'node:http';
import { WebSocketServer } from 'ws';
import { ChartLink } from './charts/link.js';
import { type ChartStore, safeIcao } from './charts/store.js';
import { HttpError, readJson, Router, sendJson, setCors } from './http.js';
import type { FenixProcedures } from './fenix.js';
import type { LVars } from './lvars.js';
import type { Hub } from './hub.js';
import { logEntries, logger } from './log.js';
import { fetchOfp } from './simbrief.js';
import { metars, metarsInBox, parseIds, sigmets, tafs } from './weather.js';

const log = logger('http');

export function createServer(hub: Hub, store: ChartStore, lvars?: LVars, fenix?: FenixProcedures): http.Server {
  const link = new ChartLink(store, hub);
  const router = new Router();

  hub.onMessage((msg) => {
    if (msg.t === 'requestCharts') void requestCharts(msg.icao).catch((err) => {
      log.error('chart request failed', err);
      hub.broadcast({ t: 'chartsError', icao: msg.icao, message: 'Unable to load chart cache; check bridge diagnostics' });
    });
    else if (msg.t === 'lvarWatch' && Array.isArray(msg.names)) {
      lvars?.watch(msg.names);
      const known = lvars?.snapshot(msg.names) ?? {};
      if (Object.keys(known).length) hub.broadcast({ t: 'lvars', values: known });
    } else if (msg.t === 'lvarRun' && typeof msg.code === 'string') {
      reply(msg.id, lvars ? lvars.run(msg.code, Number(msg.value ?? 0)).then(() => undefined) : undefined);
    } else if (msg.t === 'fenixSquawk') {
      reply(msg.id, fenix?.setSquawk(String(msg.code)));
    } else if (msg.t === 'fenixTune') {
      reply(msg.id, fenix?.tuneStandby(Number(msg.rmp), Number(msg.khz)));
    }
  });

  /** Reports how a command went to the app (only when it sent an id). */
  function reply(id: string | undefined, work: Promise<string | undefined> | undefined): void {
    if (!work) {
      if (id) hub.broadcast({ t: 'commandResult', id, ok: false, message: 'sim not connected' });
      return;
    }
    work.then(
      (message) => id && hub.broadcast({ t: 'commandResult', id, ok: true, message }),
      (err: Error) => id && hub.broadcast({ t: 'commandResult', id, ok: false, message: err.message }),
    );
  }

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
    .add('GET', '/api/diagnostics', (_req, res) => {
      res.setHeader('cache-control', 'no-store');
      sendJson(res, 200, { entries: logEntries() });
    })
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
      stream.on('error', () => {
        if (!res.headersSent) sendJson(res, 404, { error: 'image not cached' });
        else res.destroy();
      });
      res.on('close', () => stream.destroy());
    })
    .add('GET', '/api/ofp', async (_req, res, _p, url) => sendJson(res, 200, await fetchOfp(url.searchParams.get('user') ?? '')))
    .add('GET', '/api/wx/metar', async (_req, res, _p, url) => {
      const bbox = url.searchParams.get('bbox');
      if (bbox) {
        const coords = bbox.split(',');
        const [a, b, c, d] = coords.map(Number);
        if (coords.length !== 4 || coords.some((n) => !n.trim()) || [a, b, c, d].some((n) => !Number.isFinite(n)) ||
          Math.abs(a!) > 90 || Math.abs(c!) > 90 || Math.abs(b!) > 180 || Math.abs(d!) > 180 || a! > c!) {
          throw new HttpError(400, 'bbox=minLat,minLon,maxLat,maxLon within valid latitude/longitude ranges');
        }
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
    .add('POST', '/link/capture', async (req, res) => {
      sendJson(res, 200, { ok: true, saved: await link.onCapture(await readJson(req)) });
    })
    .add('POST', '/link/done', async (req, res) => {
      await link.onDone(await readJson(req));
      sendJson(res, 200, { ok: true });
    })
    .add('POST', '/link/log', async (req, res) => {
      const body = await readJson(req, 8192);
      if (typeof body.msg !== 'string') throw new HttpError(400, 'log message required');
      const linkLog = logger('in-sim');
      (body.level === 'error' ? linkLog.error : body.level === 'warn' ? linkLog.warn : linkLog.info)(body.msg);
      sendJson(res, 200, { ok: true });
    });

  const server = http.createServer(async (req, res) => {
    setCors(res);
    try {
      // Native clients send no Origin; the in-sim Coherent panel uses coui://.
      const origin = req.headers.origin;
      if (origin && !origin.startsWith('coui://')) throw new HttpError(403, 'unsupported Origin; use the native app or coui:// in-sim panel');
      const url = new URL(req.url ?? '/', 'http://bridge');
      if (url.pathname.startsWith('/link/') && !['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(req.socket.remoteAddress ?? '')) {
        throw new HttpError(403, 'in-sim link must run on the bridge PC');
      }
      if (req.method === 'OPTIONS') {
        res.writeHead(204).end();
        return;
      }
      const m = router.match(req.method ?? 'GET', url.pathname);
      if (!m) return sendJson(res, 404, { error: 'not found' });
      await m.handler(req, res, m.params, url);
    } catch (err) {
      const message = err instanceof Error ? err.message : 'bridge request failed';
      const status = err instanceof HttpError ? err.status : /^bad (ICAO|id|page)/.test(message) ? 400 : 500;
      if (status >= 500) log.error(`${req.method} request failed`, err);
      else if (status === 403) log.warn(`Rejected HTTP request: ${message}`);
      if (!res.headersSent) sendJson(res, status, { error: status >= 500 ? 'bridge request failed; check diagnostics' : message });
      else res.end();
    }
  });

  const wss = new WebSocketServer({ noServer: true, maxPayload: 64 * 1024 });
  server.on('upgrade', (req, socket, head) => {
    if (req.headers.origin || req.url !== '/ws') {
      if (req.headers.origin) log.warn('Rejected WebSocket Origin; use the native app');
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => hub.addClient(ws, req.socket.remoteAddress ?? '?'));
  });

  return server;
}
