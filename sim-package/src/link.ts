// SimPilot Link: runs inside MSFS 2024 as a toolbar panel. It polls the bridge on this PC for
// chart jobs and exports the sim's built-in Lido charts (index, page metadata, page images).
//
// Page images can't be read inside the sim, so the bridge screen-captures them (see capturePage).

import { getChartPages, getIndexForAirport, loadChartLiveView } from './charts.js';

declare const TemplateElement: { new (): HTMLElement; prototype: HTMLElement };
declare function checkAutoload(): void;

// 127.0.0.1, not localhost: Windows may resolve localhost to IPv6 (::1), but the bridge listens on IPv4.
const BRIDGE = 'http://127.0.0.1:8380';
const POLL_MS = 2000;

interface Job {
  id: string;
  type: 'charts';
  icao: string;
  provider: string;
}

let busy = false;

// ---------------------------------------------------------------- HTTP (XHR; fetch isn't reliable in Coherent)

function request(method: 'GET' | 'POST', path: string, body?: unknown, timeoutMs = 15000): Promise<any> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open(method, BRIDGE + path, true);
    xhr.timeout = timeoutMs;
    xhr.setRequestHeader('content-type', 'application/json');
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        try {
          resolve(xhr.responseText ? JSON.parse(xhr.responseText) : {});
        } catch {
          reject(new Error(`${method} ${path}: invalid JSON response`));
        }
      } else {
        // The bridge explains capture problems (e.g. the window isn't visible); pass that on to the iPad.
        let reason = '';
        try { reason = JSON.parse(xhr.responseText).error ?? ''; } catch { /* not JSON */ }
        reject(new Error(reason || `${method} ${path}: HTTP ${xhr.status}`));
      }
    };
    xhr.onerror = () => reject(new Error(`${method} ${path}: network error`));
    xhr.ontimeout = () => reject(new Error(`${method} ${path}: timeout`));
    xhr.send(body === undefined ? null : JSON.stringify(body));
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

// ---------------------------------------------------------------- chart export

function pickPageUrl(urls: readonly { name: string; url: string }[]): string | undefined {
  const png = urls.filter((u) => /png/i.test(u.name) || /\.png(\?|$)/i.test(u.url));
  // The iPad has its own night mode, so prefer the day version of the chart.
  return (png.find((u) => !/dark|night/i.test(u.name + u.url)) ?? png[0] ?? urls[0])?.url;
}

// MSFS gives panels chart images only as GPU bitmaps (ChartView LiveViews): they can be shown, but reading them back
// is blocked and drawing them into a canvas crashed the sim. So the panel shows each page between two marker squares
// (magenta top-left, cyan bottom-right) and the bridge on this PC captures those screen pixels, piece by piece.
const MARKER_PX = 16;
const TARGET_WIDTH = 1800; // stitched page width to aim for, in panel pixels
const MAX_TILES = 16;

let stage: { root: HTMLElement; view: HTMLElement; image: HTMLImageElement } | undefined;

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
  document.body.appendChild(root);
  stage = { root, view, image };
  return stage;
}

const wait = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

function loadImage(image: HTMLImageElement, src: string): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    const finish = (err?: Error) => {
      clearTimeout(timer);
      image.onload = image.onerror = null;
      if (err) reject(err);
      else resolve();
    };
    const timer = setTimeout(() => finish(new Error('Chart image timed out')), 20000);
    image.onload = () => finish();
    image.onerror = () => finish(new Error('MSFS could not show the chart image'));
    image.src = src;
  });
}

/** Tile layout for a page: about TARGET_WIDTH wide (never above the image's own resolution), at most MAX_TILES. */
export function captureLayout(viewW: number, viewH: number, naturalW: number, naturalH: number) {
  let cols = Math.max(1, Math.min(4, Math.ceil(Math.min(TARGET_WIDTH, naturalW) / viewW)));
  for (;;) {
    const w = cols * viewW;
    const h = (w * naturalH) / naturalW;
    const rows = Math.max(1, Math.ceil(h / viewH - 0.001));
    if (cols === 1 || cols * rows <= MAX_TILES) return { cols, rows, w, h };
    cols--;
  }
}

/** Shows one page and has the bridge capture it. Capture errors (window hidden…) reject: they'd hit every page. */
async function capturePage(job: Job, guid: string, page: number, url: string): Promise<boolean> {
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
      await loadImage(s.image, live.imageUrl);
    } catch (err) {
      log(`chart page ${page + 1}: ${(err as Error).message}`, 'warn');
      return false;
    }
    const viewW = s.view.clientWidth;
    const viewH = s.view.clientHeight;
    if (viewW < 100 || viewH < 100) throw new Error('The SimPilot Link window is too small; make it bigger and request the charts again');
    const { cols, rows, w, h } = captureLayout(viewW, viewH, s.image.naturalWidth || 1000, s.image.naturalHeight || 1414);
    s.image.style.width = `${w}px`;
    s.image.style.height = `${h}px`;
    let saved = false;
    for (let j = 0; j < rows; j++) {
      for (let i = 0; i < cols; i++) {
        s.image.style.left = `${-i * viewW}px`;
        s.image.style.top = `${-j * viewH}px`;
        // Let the sim draw the new position before the bridge looks at the screen.
        await wait(i === 0 && j === 0 ? 700 : 350);
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

async function runJob(job: Job): Promise<void> {
  setText('spl-job', `${job.icao}: index…`);
  log(`${job.icao}: fetching ${job.provider} chart index`);
  const index = await getIndexForAirport(job.icao, job.provider);
  await request('POST', '/link/index', { jobId: job.id, icao: job.icao, provider: job.provider, index }, 30000);

  const charts = [];
  for (const category of index.charts) {
    for (const chart of category.charts) charts.push(chart);
  }
  if (!charts.length) throw new Error('No charts available for this airport');
  let pagesOk = 0;
  let pagesFailed = 0;
  for (let i = 0; i < charts.length; i++) {
    const chart = charts[i]!;
    setText('spl-job', `${job.icao}: ${i + 1}/${charts.length} charts`);
    const { pages } = await getChartPages(chart.guid);
    await request('POST', '/link/pages', { jobId: job.id, icao: job.icao, guid: chart.guid, pages }, 30000);
    if (!pages.length) {
      pagesFailed++;
      log(`${job.icao}: chart ${i + 1} has no pages`, 'warn');
    }

    for (let p = 0; p < pages.length; p++) {
      const url = pickPageUrl(pages[p]!.urls);
      const exported = url ? await capturePage(job, chart.guid, p, url) : false;
      if (exported) {
        pagesOk++;
      } else {
        pagesFailed++;
      }
    }
  }
  const summary = `${job.icao}: ${charts.length} charts, ${pagesOk} pages${pagesFailed ? `, ${pagesFailed} failed` : ''}`;
  log(summary, pagesFailed ? 'error' : 'info');
  setText('spl-job', summary, pagesFailed === 0);
  await request('POST', '/link/done', {
    jobId: job.id,
    icao: job.icao,
    error: pagesFailed ? `${pagesFailed} chart page(s) could not be exported; please retry` : undefined,
  });
}

// ---------------------------------------------------------------- poll loop

async function tick(): Promise<void> {
  if (busy) return;
  busy = true;
  try {
    const { jobs } = (await request('GET', '/link/poll', undefined, 5000)) as { jobs: Job[] };
    setText('spl-bridge', 'connected', true);
    for (const job of jobs) {
      try {
        await runJob(job);
      } catch (err) {
        const msg = (err as Error).message;
        log(`${job.icao}: ${msg}`, 'error');
        setText('spl-job', `${job.icao}: failed`);
        await request('POST', '/link/done', { jobId: job.id, icao: job.icao, error: msg }).catch(() => {});
      }
    }
  } catch (err) {
    // Show why, so a blocked or wrong address can be told apart from a bridge that isn't started.
    setText('spl-bridge', `not reachable (${(err as Error).message.replace('GET /link/poll: ', '')})`, false);
  } finally {
    busy = false;
  }
}

// Start polling first, as soon as the panel's view is loaded, so a UI registration error below can't stop it.
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
