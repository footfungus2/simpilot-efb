// SimPilot Link: runs inside MSFS 2024 as a toolbar panel. It polls the bridge on this PC for jobs: an airport's
// chart list from the sim's built-in Lido charts, or one chart's page metadata and page images. The bridge decides
// what is needed and in which order (the chart the iPad is waiting for first).
//
// Page images can't be read inside the sim, so the bridge screen-captures them (see capturePage).

import { getChartPages, getIndexForAirport, loadChartLiveView } from './charts.js';

declare const TemplateElement: { new (): HTMLElement; prototype: HTMLElement };
declare function checkAutoload(): void;
declare const __SIMPILOT_LINK_BUILD__: string;
declare global {
  interface Window { simpilotLinkStarted?: (build: string) => void }
}

// 127.0.0.1, not localhost: Windows may resolve localhost to IPv6 (::1), but the bridge listens on IPv4.
// Not 8380: that is FlyByWire SimBridge's port, so with it running the panel talked to the wrong program.
const PORT = 8386;
const BRIDGE = `http://127.0.0.1:${PORT}`;
const POLL_MS = 2000;
// What the panel and the bridge speak; the bridge refuses to hand out work to another number. Keep in sync with bridge/src/charts/link.ts.
const LINK_PROTOCOL = 3;
const BUILD_ID = typeof __SIMPILOT_LINK_BUILD__ === 'string' ? __SIMPILOT_LINK_BUILD__ : 'development';

interface Job {
  id: string;
  type: 'index' | 'chart';
  icao: string;
  provider: string;
  /** Chart jobs: the chart to export. */
  guid?: string;
}

let busy = false;
let working = false;
let bridgeChecked = false;
let lastBridgeState = '';

// ---------------------------------------------------------------- HTTP (XHR; fetch isn't reliable in Coherent)

function request(method: 'GET' | 'POST', path: string, body?: unknown, timeoutMs = 15000): Promise<any> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open(method, BRIDGE + path, true);
    xhr.timeout = timeoutMs;
    xhr.setRequestHeader('content-type', 'application/json');
    const finish = (error?: Error, value?: unknown) => {
      clearTimeout(timer);
      xhr.onload = xhr.onreadystatechange = xhr.onerror = xhr.ontimeout = xhr.onabort = null;
      if (path === '/api/status' || path.indexOf('/link/poll') === 0) {
        setText('spl-request', error?.message ?? `${method} ${path}: HTTP ${xhr.status}`, !error);
      }
      if (error) reject(error);
      else resolve(value);
    };
    // A silent request must not leave the poll loop busy forever, even if the sim never fires ontimeout.
    const timer = setTimeout(() => {
      finish(new Error(`${method} ${path}: timeout`));
      xhr.abort();
    }, timeoutMs);
    const complete = () => {
      if (xhr.status === 0) finish(new Error(`${method} ${path}: network error`));
      else if (xhr.status >= 200 && xhr.status < 300) {
        try {
          finish(undefined, xhr.responseText ? JSON.parse(xhr.responseText) : {});
        } catch {
          finish(new Error(`${method} ${path}: invalid JSON response`));
        }
      } else {
        // The bridge explains capture problems (e.g. the window isn't visible); pass that on to the iPad.
        let reason = '';
        try { reason = JSON.parse(xhr.responseText).error ?? ''; } catch { /* not JSON */ }
        finish(new Error(`${method} ${path}: HTTP ${xhr.status}${reason ? `: ${reason}` : ''}`));
      }
    };
    xhr.onload = complete;
    xhr.onreadystatechange = () => { if (xhr.readyState === 4) complete(); };
    xhr.onerror = xhr.onabort = () => finish(new Error(`${method} ${path}: network error`));
    xhr.ontimeout = () => finish(new Error(`${method} ${path}: timeout`));
    try { xhr.send(body === undefined ? null : JSON.stringify(body)); }
    catch (err) { finish(err as Error); }
  });
}

// ---------------------------------------------------------------- UI

const el = (id: string) => document.getElementById(id);

function setText(id: string, text: string, ok?: boolean): void {
  const e = el(id);
  if (!e) return;
  e.textContent = text;
  if (ok !== undefined) e.className = ok ? 'spl-ok' : 'spl-bad';
}

function uiLog(msg: string): void {
  const list = el('spl-log');
  if (!list) return;
  const li = document.createElement('li');
  li.textContent = msg;
  list.insertBefore(li, list.firstChild);
  while (list.childNodes.length > 8) list.removeChild(list.lastChild!);
}

function log(msg: string, level: 'info' | 'warn' | 'error' = 'info'): void {
  uiLog(msg);
  request('POST', '/link/log', { level, msg }).catch(() => {});
}

function connectionStatus(text: string, ok: boolean): void {
  setText('spl-bridge', text, ok);
  if (text === lastBridgeState) return;
  lastBridgeState = text;
  if (bridgeChecked) log(`Bridge: ${text}`, ok ? 'info' : 'warn');
  else uiLog(`Bridge: ${text}`);
}

async function checkBridge(): Promise<void> {
  const status = await request('GET', '/api/status', undefined, 5000);
  if (typeof status?.sim?.connected !== 'boolean' || typeof status?.link?.connected !== 'boolean'
      || (status.bridge && status.bridge.name !== 'SimPilot Bridge')) throw new Error('not SimPilot Bridge');
  const identity = status.bridge;
  setText('spl-server', identity ? `${identity.version} · ${identity.buildId}` : 'legacy bridge (build unknown)');
  if (identity && identity.linkProtocol !== LINK_PROTOCOL) {
    throw new Error(`link protocol ${identity.linkProtocol} is incompatible; update SimPilot Bridge and SimPilot Link together`);
  }
  bridgeChecked = true;
}

function connectionFailure(error: Error): void {
  bridgeChecked = false;
  const why = error.message.replace(/^GET [^ ]+: /, '');
  connectionStatus(/network error|timeout/.test(why)
    ? 'not found: start SimPilot Bridge on this PC'
    : why === 'not SimPilot Bridge' ? `port ${PORT}: not SimPilot Bridge` : `connection failed: ${why}`, false);
}

// ---------------------------------------------------------------- chart export

function pickPageUrl(urls: readonly { name: string; url: string }[]): string | undefined {
  const png = urls.filter((u) => /png/i.test(u.name) || /\.png(\?|$)/i.test(u.url));
  // The iPad has its own night mode, so prefer the day version of the chart.
  return (png.find((u) => !/dark|night/i.test(u.name + u.url)) ?? png[0] ?? urls[0])?.url;
}

// MSFS gives panels chart images only as GPU bitmaps (ChartView LiveViews): they can be shown, but reading them back
// is blocked and drawing them into a canvas crashed the sim. So the panel shows each page between two marker squares
// (magenta top-left, cyan bottom-right) and the bridge on this PC captures those screen pixels, piece by piece.
// Along the top edge, 8 black/white squares spell the number of the tile on show (tile + 1, bit k = square k), so the
// bridge only stitches a tile once the screen really shows it.
const MARKER_PX = 16;
const CODE_BITS = 8;
const MAX_TILES = 36; // the bridge accepts up to 36 columns and 36 rows
const MIN_NATIVE_WIDTH = 800; // smaller page sizes from the sim are taken to be arbitrary units, not pixels
const FALLBACK_WIDTH = 1800;

let urlsLogged = false;
let stage: { root: HTMLElement; view: HTMLElement; image: HTMLImageElement; code: HTMLElement[] } | undefined;

function captureStage(): NonNullable<typeof stage> {
  if (stage) return stage;
  const div = (css: string) => {
    const e = document.createElement('div');
    e.setAttribute('style', css);
    return e;
  };
  const root = div('position:fixed;left:0;top:0;right:0;bottom:0;z-index:1000;background:#3a3a3a;display:none;');
  const view = div(`position:absolute;left:${MARKER_PX}px;top:${MARKER_PX}px;right:${MARKER_PX}px;bottom:${MARKER_PX}px;overflow:hidden;background:#fff;`);
  const image = document.createElement('img');
  image.setAttribute('style', 'position:absolute;left:0;top:0;');
  view.appendChild(image);
  root.appendChild(div(`position:absolute;left:0;top:0;width:${MARKER_PX}px;height:${MARKER_PX}px;background:#ff00ff;`));
  root.appendChild(div(`position:absolute;right:0;bottom:0;width:${MARKER_PX}px;height:${MARKER_PX}px;background:#00ffff;`));
  root.appendChild(view);
  const code: HTMLElement[] = [];
  for (let k = 0; k < CODE_BITS; k++) {
    const cell = div(`position:absolute;left:${MARKER_PX * (k + 1)}px;top:0;width:${MARKER_PX}px;height:${MARKER_PX}px;background:#000;`);
    root.appendChild(cell);
    code.push(cell);
  }
  document.body.appendChild(root);
  stage = { root, view, image, code };
  return stage;
}

const wait = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/** Resolves true once the image reports loading, false if it stays silent (a LiveView may be shown without ever saying so). */
function loadImage(image: HTMLImageElement, src: string): Promise<boolean> {
  return new Promise<boolean>((resolve, reject) => {
    const finish = (err?: Error, loaded = true) => {
      clearTimeout(timer);
      image.onload = image.onerror = null;
      if (err) reject(err);
      else resolve(loaded);
    };
    const timer = setTimeout(() => finish(undefined, false), 6000);
    image.onload = () => finish();
    image.onerror = () => finish(new Error('MSFS could not show the chart image'));
    image.src = src;
  });
}

export function setTileCode(code: HTMLElement[], tile: number): void {
  for (let k = 0; k < code.length; k++) code[k]!.style.background = ((tile + 1) >> k) & 1 ? '#fff' : '#000';
}

/**
 * Tile layout for a page: shown at its own resolution (one panel pixel per image pixel) so nothing is resampled, and
 * only shrunk when that would take more than MAX_TILES.
 */
export function captureLayout(viewW: number, viewH: number, naturalW: number, naturalH: number) {
  let scale = 1;
  for (;;) {
    const w = naturalW * scale;
    const h = naturalH * scale;
    const cols = Math.max(1, Math.ceil(w / viewW - 0.001));
    const rows = Math.max(1, Math.ceil(h / viewH - 0.001));
    if (cols * rows <= MAX_TILES || scale < 0.1) return { cols, rows, w, h };
    scale *= 0.9;
  }
}

/** The size to show the page at: what the image itself reports, else the page size the sim gave (if it looks like pixels). */
export function pageSize(img: { naturalWidth: number; naturalHeight: number }, shape: { width: number; height: number }) {
  if (img.naturalWidth > 0 && img.naturalHeight > 0) return { w: img.naturalWidth, h: img.naturalHeight, from: 'image' };
  const ok = shape.width > 0 && shape.height > 0;
  if (ok && shape.width >= MIN_NATIVE_WIDTH) return { w: shape.width, h: shape.height, from: 'page size' };
  const aspect = ok ? shape.height / shape.width : 1.4;
  return { w: FALLBACK_WIDTH, h: FALLBACK_WIDTH * aspect, from: 'assumed' };
}

/** Shows one page and has the bridge capture it. Capture errors (window hidden…) reject: they'd hit every page. */
async function capturePage(job: Job, guid: string, page: number, url: string, shape: { width: number; height: number }): Promise<boolean> {
  let live: { imageUrl: string; release: () => void };
  try {
    live = await loadChartLiveView(url);
  } catch (err) {
    log(`chart page ${page + 1}: ${(err as Error).message}`, 'warn');
    return false;
  }
  const s = captureStage();
  s.root.style.display = 'block';
  try {
    try {
      if (!(await loadImage(s.image, live.imageUrl))) log(`chart page ${page + 1}: MSFS didn't report the image as loaded; capturing it anyway`, 'warn');
    } catch (err) {
      log(`chart page ${page + 1}: ${(err as Error).message}`, 'warn');
      return false;
    }
    const viewW = s.view.clientWidth;
    const viewH = s.view.clientHeight;
    if (viewW < 100 || viewH < 100) throw new Error('The SimPilot Link window is hidden or too small; open it, make it bigger and export the chart again');
    const natural = pageSize(s.image, shape);
    const { cols, rows, w, h } = captureLayout(viewW, viewH, natural.w, natural.h);
    log(`chart page ${page + 1}: ${Math.round(natural.w)}x${Math.round(natural.h)} from ${natural.from} (page size ${shape.width}x${shape.height}), view ${viewW}x${viewH}, ${cols}x${rows} tiles at ${(w / natural.w).toFixed(2)}x`);
    s.image.style.width = `${w}px`;
    s.image.style.height = `${h}px`;
    let saved = false;
    for (let j = 0; j < rows; j++) {
      for (let i = 0; i < cols; i++) {
        s.image.style.left = `${-i * viewW}px`;
        s.image.style.top = `${-j * viewH}px`;
        setTileCode(s.code, j * cols + i);
        // Let the sim draw the new position; the bridge also waits until the tile number is on screen.
        await wait(i === 0 && j === 0 ? 600 : 250);
        const res = await request('POST', '/link/capture', {
          jobId: job.id, icao: job.icao, guid, page, i, j, cols, rows, view: { w: viewW, h: viewH }, image: { w, h },
        }, 60000) as { saved?: boolean };
        saved = res.saved === true;
      }
    }
    if (saved) setText('spl-method', 'screen capture', true);
    return saved;
  } finally {
    s.root.style.display = 'none';
    // Detach the image from the LiveView before the view is destroyed.
    s.image.src = '';
    live.release();
  }
}

/** An airport's chart list: no screen needed, so the iPad shows it at once. */
async function runIndexJob(job: Job): Promise<void> {
  setText('spl-job', `${job.icao}: chart list…`);
  log(`${job.icao}: fetching ${job.provider} chart list`);
  const index = await getIndexForAirport(job.icao, job.provider);
  await request('POST', '/link/index', { jobId: job.id, icao: job.icao, provider: job.provider, index }, 30000);
  const count = index.charts.reduce((n, category) => n + category.charts.length, 0);
  setText('spl-job', `${job.icao}: ${count} charts listed`, count > 0);
  await request('POST', '/link/done', { jobId: job.id, icao: job.icao });
}

/** One chart: its pages are captured from the screen, except those the bridge already has. */
async function runChartJob(job: Job, guid: string): Promise<void> {
  setText('spl-job', `${job.icao}: chart…`);
  const { pages } = await getChartPages(guid);
  if (!pages.length) throw new Error('This chart has no pages');
  const { have = [] } = (await request('POST', '/link/pages', { jobId: job.id, icao: job.icao, guid, pages }, 30000)) as { have?: number[] };
  if (!urlsLogged) {
    urlsLogged = true;
    log(`page URL names from the sim: ${pages[0]!.urls.map((u) => u.name).join(', ') || '(none)'}`);
  }
  let failed = 0;
  for (let p = 0; p < pages.length; p++) {
    if (have.indexOf(p) >= 0) continue; // indexOf: old Coherent builds lack newer Array methods (flatMap)
    setText('spl-job', `${job.icao}: page ${p + 1}/${pages.length}`);
    const url = pickPageUrl(pages[p]!.urls);
    if (!url || !(await capturePage(job, guid, p, url, pages[p]!))) failed++;
  }
  const summary = `${job.icao}: chart exported${failed ? `, ${failed} of ${pages.length} pages failed` : ` (${pages.length} pages)`}`;
  log(summary, failed ? 'error' : 'info');
  setText('spl-job', summary, failed === 0);
  await request('POST', '/link/done', {
    jobId: job.id,
    icao: job.icao,
    error: failed ? `${failed} chart page(s) could not be exported; please retry` : undefined,
  });
}

// ---------------------------------------------------------------- poll loop

async function tick(): Promise<void> {
  setText('spl-build', BUILD_ID);
  if (busy) {
    // Still working: tell the bridge the panel is there, so the iPad doesn't think it was closed during a long export.
    if (working) request('GET', `/link/poll?proto=${LINK_PROTOCOL}&busy=1`, undefined, 5000).catch(connectionFailure);
    return;
  }
  busy = true;
  try {
    if (!bridgeChecked) await checkBridge();
    const { jobs } = (await request('GET', `/link/poll?proto=${LINK_PROTOCOL}`, undefined, 5000)) as { jobs?: Job[] };
    if (!Array.isArray(jobs)) throw new Error('not SimPilot Bridge');
    connectionStatus('connected', true);
    for (const job of jobs) {
      working = true;
      try {
        if (job.type === 'chart' && job.guid) await runChartJob(job, job.guid);
        else if (job.type === 'index') await runIndexJob(job);
        else throw new Error(`Unknown job type ${String(job.type)}; use the same version of SimPilot Bridge and SimPilot Link`);
      } catch (err) {
        const msg = (err as Error).message;
        log(`${job.icao}: ${msg}`, 'error');
        setText('spl-job', `${job.icao}: failed`);
        await request('POST', '/link/done', { jobId: job.id, icao: job.icao, error: msg }).catch(() => {});
      } finally {
        working = false;
      }
    }
  } catch (err) {
    connectionFailure(err as Error);
  } finally {
    busy = false;
  }
}

// The script is loaded after the markup; poll independently of custom-element registration.
window.simpilotLinkStarted?.(BUILD_ID);
setText('spl-start', 'running', true);
setText('spl-target', BRIDGE);
uiLog(`SimPilot Link ${BUILD_ID} started`);
setInterval(() => void tick(), POLL_MS);
void tick();

try {
  class SimPilotLinkPanel extends TemplateElement {
    connectedCallback(): void {
      (TemplateElement.prototype as any).connectedCallback?.call(this);
      uiLog('SimPilot Link ready');
    }
  }
  window.customElements.define('simpilot-link-panel', SimPilotLinkPanel as unknown as CustomElementConstructor);
  checkAutoload();
} catch (err) {
  log(`panel setup: ${(err as Error).message}`, 'warn');
}
