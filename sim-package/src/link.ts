// SimPilot Link: runs inside MSFS 2024 as a toolbar panel. It polls the bridge on this PC for
// chart jobs and exports the sim's built-in Lido charts (index, page metadata, page images).
//
// Getting page images out of the sim is the main unknown, so three methods are tried in order
// and the first one that works is remembered:
//   1. 'xhr'    – download the page URL from inside the sim and send the bytes to the bridge
//   2. 'bridge' – send the URL to the bridge and let it download (works if URLs are public)
//   3. 'view'   – render through a ChartView LiveView into a canvas and read back the PNG

import { getChartPages, getIndexForAirport, loadChartLiveView } from './charts.js';

declare const TemplateElement: { new (): HTMLElement; prototype: HTMLElement };
declare function checkAutoload(): void;

// 127.0.0.1, not localhost: Windows may resolve localhost to IPv6 (::1), but the bridge listens on IPv4.
const BRIDGE = 'http://127.0.0.1:8380';
const POLL_MS = 2000;

type Method = 'xhr' | 'bridge' | 'view';
interface Job {
  id: string;
  type: 'charts';
  icao: string;
  provider: string;
}

let preferred: Method | undefined;
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
          resolve({});
        }
      } else reject(new Error(`${method} ${path}: HTTP ${xhr.status}`));
    };
    xhr.onerror = () => reject(new Error(`${method} ${path}: network error`));
    xhr.ontimeout = () => reject(new Error(`${method} ${path}: timeout`));
    xhr.send(body === undefined ? null : JSON.stringify(body));
  });
}

/** Binary download via the classic x-user-defined trick, which works without responseType support. */
function downloadBase64(url: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('GET', url, true);
    xhr.timeout = 20000;
    xhr.overrideMimeType('text/plain; charset=x-user-defined');
    xhr.onload = () => {
      if (xhr.status !== 200 && xhr.status !== 0) return reject(new Error(`HTTP ${xhr.status}`));
      const text = xhr.responseText;
      if (!text) return reject(new Error('empty response'));
      let bin = '';
      for (let i = 0; i < text.length; i++) bin += String.fromCharCode(text.charCodeAt(i) & 0xff);
      if (!bin.startsWith('\x89PNG')) return reject(new Error(`not a PNG (${text.length} bytes)`));
      resolve(btoa(bin));
    };
    xhr.onerror = () => reject(new Error('network error'));
    xhr.ontimeout = () => reject(new Error('timeout'));
    xhr.send();
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
    await new Promise<void>((resolve, reject) => {
      image.onload = () => resolve();
      image.onerror = () => reject(new Error(`could not load ${imageUrl}`));
      image.src = imageUrl;
    });
    const canvas = document.createElement('canvas');
    canvas.width = image.naturalWidth || image.width;
    canvas.height = image.naturalHeight || image.height;
    const ctx = canvas.getContext('2d');
    if (!ctx || !canvas.width) throw new Error('canvas unavailable');
    ctx.drawImage(image, 0, 0);
    const dataUrl = canvas.toDataURL('image/png');
    if (!dataUrl.startsWith('data:image/png;base64,') || dataUrl.length < 100) throw new Error('canvas readback blocked');
    return dataUrl.slice('data:image/png;base64,'.length);
  } finally {
    release();
  }
}

/** Tries each export method (preferred one first). Returns the method that worked. */
async function exportPage(job: Job, guid: string, page: number, url: string): Promise<Method | undefined> {
  const order: Method[] = preferred ? [preferred, ...(['xhr', 'bridge', 'view'] as Method[]).filter((m) => m !== preferred)] : ['xhr', 'bridge', 'view'];
  const base = { jobId: job.id, icao: job.icao, guid, page };
  for (const method of order) {
    try {
      let res: { saved?: boolean };
      if (method === 'xhr') res = await request('POST', '/link/image', { ...base, pngBase64: await downloadBase64(url) }, 30000);
      else if (method === 'bridge') res = await request('POST', '/link/image', { ...base, url }, 30000);
      else res = await request('POST', '/link/image', { ...base, pngBase64: await viaView(url) }, 30000);
      if (res.saved) return method;
      if (!preferred) log(`export '${method}' gave no image`, 'warn');
    } catch (err) {
      if (!preferred) log(`export '${method}' failed: ${(err as Error).message}`, 'warn');
    }
  }
  return undefined;
}

async function runJob(job: Job): Promise<void> {
  setText('spl-job', `${job.icao}: index…`);
  log(`${job.icao}: fetching ${job.provider} chart index`);
  const index = await getIndexForAirport(job.icao, job.provider);
  await request('POST', '/link/index', { jobId: job.id, icao: job.icao, provider: job.provider, index }, 30000);

  const charts = index.charts.flatMap((c) => c.charts);
  let pagesOk = 0;
  let pagesFailed = 0;
  for (let i = 0; i < charts.length; i++) {
    const chart = charts[i]!;
    setText('spl-job', `${job.icao}: ${i + 1}/${charts.length} charts`);
    const { pages } = await getChartPages(chart.guid);
    await request('POST', '/link/pages', { jobId: job.id, icao: job.icao, guid: chart.guid, pages }, 30000);
    if (i === 0 && pages[0]) log(`page URL names: ${pages[0].urls.map((u) => u.name).join(', ') || '(none)'}`);

    for (let p = 0; p < pages.length; p++) {
      const url = pickPageUrl(pages[p]!.urls);
      const method = url ? await exportPage(job, chart.guid, p, url) : undefined;
      if (method) {
        pagesOk++;
        if (preferred !== method) {
          preferred = method;
          setText('spl-method', method, true);
          log(`chart images: using '${method}' export`);
        }
      } else {
        pagesFailed++;
      }
    }
  }
  const summary = `${job.icao}: ${charts.length} charts, ${pagesOk} pages${pagesFailed ? `, ${pagesFailed} failed` : ''}`;
  log(summary, pagesFailed && !pagesOk ? 'error' : 'info');
  setText('spl-job', summary);
  await request('POST', '/link/done', {
    jobId: job.id,
    icao: job.icao,
    error: pagesOk === 0 && pagesFailed > 0 ? 'no export method could read chart images' : undefined,
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
