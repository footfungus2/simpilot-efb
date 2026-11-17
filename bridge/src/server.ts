import fs from 'node:fs';
import https from 'node:https';
import http from 'node:http';
import { TLSSocket } from 'node:tls';
import { WebSocketServer } from 'ws';
import { hasValidPairingKey } from './auth.js';
import type { Capturer } from './charts/capture.js';
import { ChartLink, LINK_PROTOCOL } from './charts/link.js';
import { type ChartStore, safeIcao } from './charts/store.js';
import { config } from './config.js';
import type { BridgeTls } from './tls.js';
import { HttpError, readJson, Router, sendJson, setCors } from './http.js';
import type { FenixProcedures } from './fenix.js';
import type { LVars } from './lvars.js';
import type { Traffic } from './traffic.js';
import type { Hub } from './hub.js';
import { logEntries, logger } from './log.js';
import { fetchOfp } from './simbrief.js';
import { bridgeInfo, manage } from './manage.js';
import { checkForUpdate, installUpdate } from './update.js';
import type { ChartIndex } from './types.js';
import { metars, metarsInBox, parseIds, sigmets, tafs } from './weather.js';

const log = logger('http');

/** A cached chart list older than this is fetched again (in the background) when the link panel is there. */
const INDEX_MAX_AGE_MS = 24 * 60 * 60_000;

export function createServer(hub: Hub, store: ChartStore, pairingKey: string, lvars?: LVars, fenix?: FenixProcedures, capturer?: Capturer, traffic?: Traffic, tlsFingerprint = ''): http.Server {
  const link = new ChartLink(store, hub, capturer);
  const router = new Router();

  hub.onMessage((msg) => {
    if (msg.t === 'requestCharts') void requestIndex(msg.icao).then(async (index) => {
      if (index) hub.broadcast({ t: 'chartsReady', icao: safeIcao(msg.icao) });
      if (msg.role === 'origin' || msg.role === 'destination') {
        await link.wantFlightCharts(msg.icao, { role: msg.role, procedures: msg.procedures ?? [], runway: msg.runway });
      }
    }).catch((err) => {
      log.error('chart request failed', err);
      hub.broadcast({ t: 'chartsError', icao: msg.icao, message: 'Unable to load chart cache; check bridge diagnostics' });
    });
    else if (msg.t === 'trafficWatch') traffic?.updateSubscriptions();
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

  /** The cached chart list of an airport, if any. Without one the list is queued; an old one is refreshed in the background. */
  async function requestIndex(icaoRaw: string): Promise<ChartIndex | undefined> {
    const icao = safeIcao(icaoRaw);
    const index = await store.getIndex(icao);
    if (!index || (Date.now() - index.fetchedAt > INDEX_MAX_AGE_MS && hub.status().link.connected)) link.requestIndex(icao);
    return index;
  }

  // ---- the bridge window at / (this PC only): status, update, repair ----
  router
    .add('GET', '/', (_req, res) => { res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }).end('<!doctype html><meta charset="utf-8"><title>SimPilot Bridge</title><body style="font:16px system-ui;margin:3rem">SimPilot Bridge is running. Use the SimPilot Bridge program on this PC.'); })
    .add('GET', '/bridge/update', async (_req, res) => { res.setHeader('cache-control', 'no-store'); sendJson(res, 200, await checkForUpdate()); })
    .add('GET', '/bridge/info', async (_req, res) => { res.setHeader('cache-control', 'no-store'); sendJson(res, 200, await bridgeInfo(pairingKey, tlsFingerprint)); })
    .add('POST', '/bridge/manage/:action', async (req, res, p) => {
      // A custom header can't be sent cross-site without a CORS preflight, which this server never answers.
      if (req.headers['x-simpilot-ui'] !== '1') throw new HttpError(403, 'use the SimPilot Bridge window');
      sendJson(res, 200, { ok: true, message: await manage(p.action!) });
    })
    .add('POST', '/bridge/update', async (req, res) => {
      if (req.headers['x-simpilot-ui'] !== '1') throw new HttpError(403, 'use the SimPilot Bridge window');
      await installUpdate();
      sendJson(res, 200, { ok: true });
      res.on('finish', () => setTimeout(() => process.exit(0), 300));
    });

  // ---- app ----
  router
    .add('GET', '/api/status', (req, res) => {
      res.setHeader('cache-control', 'no-store');
      const address = server.address();
      sendJson(res, 200, { ...hub.status(), bridge: {
        name: 'SimPilot Bridge', version: config.bridgeVersion, buildId: config.buildId,
        linkProtocol: LINK_PROTOCOL, apps: hub.appCount, port: req.socket.localPort ?? (address && typeof address !== 'string' ? address.port : config.port),
      } });
    })
    .add('GET', '/api/diagnostics', (_req, res) => {
      res.setHeader('cache-control', 'no-store');
      sendJson(res, 200, { entries: logEntries() });
    })
    .add('GET', '/api/ownship', (_req, res) => sendJson(res, hub.lastOwnship ? 200 : 204, hub.lastOwnship ?? null))
    .add('GET', '/api/charts/:icao', async (_req, res, p) => {
      const index = await requestIndex(p.icao!);
      if (index) return sendJson(res, 200, index);
      sendJson(res, 202, { queued: true, linkConnected: hub.status().link.connected });
    })
    // A chart is exported from the sim when it is first asked for: 202 until every page is cached (then chartReady).
    // ?refresh=1 queues a replacement while ordinary reads can still open the last complete export.
    .add('GET', '/api/charts/:icao/:guid', async (_req, res, p, url) => {
      const icao = safeIcao(p.icao!);
      const refresh = url.searchParams.get('refresh') === '1';
      if (refresh && !hub.status().link.connected) throw new HttpError(409, 'Open SimPilot Link in MSFS before exporting again');
      const chart = refresh ? undefined : await store.getChart(icao, p.guid!);
      if (chart?.pages.length && chart.pages.every((page) => page.image)) return sendJson(res, 200, chart);
      const job = await link.requestChart(icao, p.guid!, undefined, refresh);
      sendJson(res, 202, { queued: true, linkConnected: hub.status().link.connected, done: job.saved.size, total: job.total });
    })
    .add('GET', '/charts/:icao/:guid/:page.png', (_req, res, p, url) => {
      const file = store.imagePath(p.icao!, p.guid!, Number(p.page), url.searchParams.get('revision') ?? undefined);
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
    .add('GET', '/link/poll', (_req, res, _p, url) =>
      sendJson(res, 200, link.poll(url.searchParams.get('busy') === '1', Number(url.searchParams.get('proto')))))
    .add('POST', '/link/index', async (req, res) => {
      await link.onIndex(await readJson(req));
      sendJson(res, 200, { ok: true });
    })
    .add('POST', '/link/pages', async (req, res) => {
      sendJson(res, 200, { ok: true, ...(await link.onPages(await readJson(req))) });
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
      const host = req.headers.host?.toLowerCase() ?? '';
      const local = ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(req.socket.remoteAddress ?? '');
      const ownPage = local && /^(localhost|127\.0\.0\.1)(:\d+)?$/.test(host) && origin === `http://${host}`;
      const url = new URL(req.url ?? '/', 'http://bridge');
      if (origin && (!origin.startsWith('coui://') || url.pathname.startsWith('/bridge/')) && !ownPage) {
        throw new HttpError(403, 'unsupported Origin; use the native app or coui:// in-sim panel');
      }
      if (!(req.socket instanceof TLSSocket) && !local) throw new HttpError(403, 'LAN access requires HTTPS on the secure bridge port');
      if (url.pathname.startsWith('/link/') && !local) throw new HttpError(403, 'in-sim link must run on the bridge PC');
      // Host check stops DNS-rebinding pages from reaching the installer.
      if ((url.pathname === '/' || url.pathname.startsWith('/bridge/')) && !(local && /^(localhost|127\.0\.0\.1)(:\d+)?$/.test(req.headers.host ?? ''))) {
        throw new HttpError(403, 'open this page on the bridge PC at http://localhost:' + config.port);
      }
      if (req.method === 'OPTIONS') {
        res.writeHead(204).end();
        return;
      }
      // SimConnect status stays public so the in-sim panel and PC launcher can check health before pairing.
      const protectedResource = url.pathname.startsWith('/charts/') ||
        url.pathname.startsWith('/api/') && url.pathname !== '/api/status';
      if (protectedResource && !hasValidPairingKey(req.headers['x-simpilot-token'], pairingKey)) {
        throw new HttpError(401, 'enter the pairing key shown in SimPilot Bridge on the PC');
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

  attachWebSocket(server, hub, pairingKey);

  return server;
}

export function createSecureServer(localServer: http.Server, tls: BridgeTls, hub: Hub, pairingKey: string): https.Server {
  const request = localServer.listeners('request')[0];
  if (!request) throw new Error('bridge request handler is missing');
  const server = https.createServer({ pfx: tls.pfx, passphrase: tls.passphrase }, request as http.RequestListener);
  attachWebSocket(server, hub, pairingKey);
  return server;
}

function attachWebSocket(server: http.Server | https.Server, hub: Hub, pairingKey: string): void {
  const wss = new WebSocketServer({ noServer: true, maxPayload: 64 * 1024 });
  server.on('upgrade', (req, socket, head) => {
    if (!(req.socket instanceof TLSSocket) && !['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(req.socket.remoteAddress ?? '')) {
      socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
      return;
    }
    if (req.headers.origin || req.url !== '/ws') {
      if (req.headers.origin) log.warn('Rejected WebSocket Origin; use the native app');
      socket.destroy();
      return;
    }
    if (!hasValidPairingKey(req.headers['x-simpilot-token'], pairingKey)) {
      socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => hub.addClient(ws, req.socket.remoteAddress ?? '?'));
  });
}
