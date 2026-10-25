// SimPilot Link: runs inside MSFS 2024 as a toolbar panel. It polls the bridge on this PC for
// chart jobs and exports the sim's built-in Lido charts (index, page metadata, page images).
//
// Chart images can't be exported (see runJob); only the chart index is read.

import { getIndexForAirport } from './charts.js';

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

// MSFS hands chart pages to panels only as GPU bitmaps (ChartView LiveViews): they can be shown but not read back,
// and drawing them into a canvas to copy them crashed the sim. So the panel lists the charts and stops there.
async function runJob(job: Job): Promise<void> {
  setText('spl-job', `${job.icao}: index…`);
  log(`${job.icao}: fetching ${job.provider} chart index`);
  const index = await getIndexForAirport(job.icao, job.provider);
  const count = index.charts.reduce((n, category) => n + category.charts.length, 0);
  throw new Error(`MSFS 2024 has ${count} charts for ${job.icao} but doesn't let add-ons copy chart images, so they can't be shown on the iPad`);
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
