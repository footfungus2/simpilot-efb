// SimPilot Link: runs inside MSFS 2024 as a toolbar panel. It polls the bridge on this PC for
// chart jobs and exports the sim's built-in Lido charts (index, page metadata, page images).
//
// Chart page URLs are simulator handles; MSFS ChartView is the supported way to load them.

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
      } else reject(new Error(`${method} ${path}: HTTP ${xhr.status}`));
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
  const png = urls.find((u) => /png/i.test(u.name) || /\.png(\?|$)/i.test(u.url));
  return (png ?? urls[0])?.url;
}

async function viaView(url: string): Promise<string> {
  const { imageUrl, release } = await loadChartLiveView(url);
  try {
    const image = new Image();
    image.crossOrigin = 'anonymous';
    await new Promise<void>((resolve, reject) => {
      const finish = (err?: Error) => {
        clearTimeout(timer);
        image.onload = image.onerror = null;
        if (err) reject(err);
        else resolve();
      };
      const timer = setTimeout(() => finish(new Error('Chart image timed out')), 20000);
      image.onload = () => finish();
      image.onerror = () => finish(new Error('Could not load MSFS ChartView image (CORS or image error)'));
      image.src = imageUrl;
    });
    const canvas = document.createElement('canvas');
    canvas.width = image.naturalWidth || image.width;
    canvas.height = image.naturalHeight || image.height;
    const ctx = canvas.getContext('2d');
    if (!ctx || !canvas.width || !canvas.height) throw new Error('canvas unavailable');
    ctx.drawImage(image, 0, 0);
    const dataUrl = canvas.toDataURL('image/png');
    if (!dataUrl.startsWith('data:image/png;base64,') || dataUrl.length < 100) throw new Error('canvas readback blocked');
    return dataUrl.slice('data:image/png;base64,'.length);
  } finally {
    release();
  }
}

async function exportPage(job: Job, guid: string, page: number, url: string): Promise<boolean> {
  const base = { jobId: job.id, icao: job.icao, guid, page };
  try {
    const res = await request('POST', '/link/image', { ...base, pngBase64: await viaView(url) }, 30000) as { saved?: boolean };
    if (res.saved) {
      setText('spl-method', 'ChartView', true);
      return true;
    }
    log(`chart page ${page + 1}: ChartView returned no image`, 'warn');
  } catch (err) {
    log(`chart page ${page + 1}: ChartView export failed: ${(err as Error).message}`, 'warn');
  }
  return false;
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
      const exported = url ? await exportPage(job, chart.guid, p, url) : false;
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
