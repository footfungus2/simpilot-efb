// Job queue + ingest for the in-sim link panel. The panel polls GET /link/poll for jobs and
// posts back the chart index, page metadata and page images for each requested airport.

import { randomUUID } from 'node:crypto';
import type { Hub } from '../hub.js';
import { HttpError } from '../http.js';
import { logger } from '../log.js';
import { icaoIdent, normalizeIndex, normalizePages, pickImageUrl } from './normalize.js';
import { type ChartStore, isPng, safeIcao } from './store.js';

const log = logger('link');

/** A handed-out job that hasn't finished in this time is offered again (e.g. the panel was reloaded). */
const JOB_RETRY_MS = 5 * 60_000;

interface Job {
  id: string;
  type: 'charts';
  icao: string;
  provider: string;
  handedAt?: number;
  total: number;
  done: number;
}

export class ChartLink {
  private jobs = new Map<string, Job>();

  constructor(
    private readonly store: ChartStore,
    private readonly hub: Hub,
  ) {}

  /** Queues a chart download for an airport unless one is already pending. */
  request(icaoRaw: string, provider = 'LIDO'): Job {
    const icao = safeIcao(icaoRaw);
    const existing = [...this.jobs.values()].find((j) => j.icao === icao && j.provider === provider);
    if (existing) return existing;
    const job: Job = { id: randomUUID(), type: 'charts', icao, provider, total: 0, done: 0 };
    this.jobs.set(job.id, job);
    log.info(`queued ${provider} charts for ${icao}`);
    return job;
  }

  isPending(icao: string): boolean {
    return [...this.jobs.values()].some((j) => j.icao === icao);
  }

  poll(): { jobs: { id: string; type: string; icao: string; provider: string }[] } {
    this.hub.linkSeen();
    const now = Date.now();
    const out = [];
    for (const j of this.jobs.values()) {
      if (j.handedAt === undefined || now - j.handedAt > JOB_RETRY_MS) {
        j.handedAt = now;
        out.push({ id: j.id, type: j.type, icao: j.icao, provider: j.provider });
      }
    }
    return { jobs: out };
  }

  async onIndex(body: any): Promise<void> {
    const job = this.job(body.jobId);
    const icao = safeIcao(icaoIdent(body.index?.airportIcao) || job.icao);
    const index = normalizeIndex(body.index, icao, String(body.provider ?? job.provider));
    await this.store.saveIndex(index);
    const n = index.categories.reduce((s, c) => s + c.charts.length, 0);
    log.info(`${icao}: index with ${index.categories.length} categories / ${n} charts`);
  }

  async onPages(body: any): Promise<void> {
    const job = this.job(body.jobId);
    const pages = normalizePages(body.pages);
    await this.store.savePages(job.icao, String(body.guid), pages);
    job.total += pages.length;
    if (job.total === pages.length && pages[0]) {
      // First chart of the job: log URL shapes once, that's the main unknown of the spike.
      log.info(`${job.icao}: first page URLs`, pages[0].urls);
    }
    this.progress(job);
  }

  /** Stores one page image. Returns false if nothing usable arrived, so the link can try its next method. */
  async onImage(body: any): Promise<boolean> {
    const job = this.job(body.jobId);
    const guid = String(body.guid);
    const page = Number(body.page);
    let png: Buffer | undefined;

    if (typeof body.pngBase64 === 'string' && body.pngBase64.length > 0) {
      png = Buffer.from(body.pngBase64.replace(/^data:image\/png;base64,/, ''), 'base64');
      if (!isPng(png)) {
        log.warn(`${job.icao} ${guid}#${page}: link sent data that isn't a PNG (${png.length} bytes)`);
        png = undefined;
      }
    }

    if (!png) {
      const stored = await this.store.getStoredPages(job.icao, guid);
      const url = typeof body.url === 'string' ? body.url : pickImageUrl(stored?.[page]?.urls ?? []);
      if (url) png = await download(url, `${job.icao} ${guid}#${page}`);
    }

    if (!png) return false;
    await this.store.saveImage(job.icao, guid, page, png);
    job.done += 1;
    this.progress(job);
    return true;
  }

  onDone(body: any): void {
    const job = this.jobs.get(String(body.jobId));
    if (!job) return;
    this.jobs.delete(job.id);
    if (body.error) {
      log.warn(`${job.icao}: link reported error: ${body.error}`);
      this.hub.broadcast({ t: 'chartsError', icao: job.icao, message: String(body.error) });
    } else {
      log.info(`${job.icao}: done (${job.done}/${job.total} pages)`);
      this.hub.broadcast({ t: 'chartsReady', icao: job.icao });
    }
  }

  private progress(job: Job): void {
    this.hub.broadcast({ t: 'chartsProgress', icao: job.icao, done: job.done, total: job.total });
  }

  private job(id: unknown): Job {
    const job = this.jobs.get(String(id));
    if (!job) throw new HttpError(404, `unknown job ${String(id)}`);
    return job;
  }
}

async function download(url: string, what: string): Promise<Buffer | undefined> {
  if (!/^https?:\/\//i.test(url)) {
    log.warn(`${what}: can't download non-http URL from the bridge: ${url.slice(0, 120)}`);
    return undefined;
  }
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(20_000) });
    if (!res.ok) {
      log.warn(`${what}: download failed HTTP ${res.status} for ${url.slice(0, 120)}`);
      return undefined;
    }
    const buf = Buffer.from(await res.arrayBuffer());
    if (!isPng(buf)) {
      log.warn(`${what}: downloaded ${buf.length} bytes of ${res.headers.get('content-type')}, not a PNG`);
      return undefined;
    }
    return buf;
  } catch (err) {
    log.warn(`${what}: download error ${(err as Error).message}`);
    return undefined;
  }
}
