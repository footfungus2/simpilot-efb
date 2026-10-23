// Job queue + ingest for the in-sim link panel. The panel polls GET /link/poll for jobs and
// posts back the chart index, page metadata and page images for each requested airport.

import { randomUUID } from 'node:crypto';
import type { Hub } from '../hub.js';
import { HttpError } from '../http.js';
import { logger } from '../log.js';
import type { ChartIndex } from '../types.js';
import { icaoIdent, normalizeIndex, normalizePages, pickImageUrl } from './normalize.js';
import { type ChartStore, isPng, safeIcao } from './store.js';

const log = logger('link');

/** A handed-out job that hasn't finished in this time is offered again (e.g. the panel was reloaded). */
const JOB_RETRY_MS = 5 * 60_000;
const MAX_IMAGE_BYTES = 24 * 1024 * 1024;

interface Job {
  id: string;
  type: 'charts';
  icao: string;
  provider: string;
  handedAt?: number;
  total: number;
  done: number;
  index?: ChartIndex;
  pages: Map<string, { count: number; saved: boolean }>;
  images: Set<string>;
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
    if (this.jobs.size >= 32) throw new HttpError(429, 'too many pending chart airports');
    const job: Job = { id: randomUUID(), type: 'charts', icao, provider, total: 0, done: 0, pages: new Map(), images: new Set() };
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
    if (icao !== job.icao || !Array.isArray(body.index?.charts)) throw new HttpError(400, 'chart index does not match requested airport');
    const index = normalizeIndex(body.index, icao, String(body.provider ?? job.provider));
    job.index = index;
    const n = index.categories.reduce((s, c) => s + c.charts.length, 0);
    log.info(`${icao}: index with ${index.categories.length} categories / ${n} charts`);
  }

  async onPages(body: any): Promise<void> {
    const job = this.job(body.jobId);
    const guid = String(body.guid);
    if (!job.index?.categories.some((c) => c.charts.some((chart) => chart.guid === guid)) || !Array.isArray(body.pages)) {
      throw new HttpError(400, 'chart pages do not match the index');
    }
    const pages = normalizePages(body.pages);
    if (!pages.length || pages.some((p) => !Number.isFinite(p.width) || !Number.isFinite(p.height) || p.width <= 0 || p.height <= 0)) {
      throw new HttpError(400, 'chart pages require positive image dimensions');
    }
    const previous = job.pages.get(guid);
    if (previous !== undefined && previous.count !== pages.length) throw new HttpError(409, 'chart page count changed during export');
    const metadata = previous ?? { count: pages.length, saved: false };
    if (!previous) {
      job.total += pages.length;
      job.pages.set(guid, metadata);
    }
    await this.store.savePages(job.icao, guid, pages);
    metadata.saved = true;
    this.progress(job);
  }

  /** Stores one page image. Returns false if nothing usable arrived, so the link can try its next method. */
  async onImage(body: any): Promise<boolean> {
    const job = this.job(body.jobId);
    const guid = String(body.guid);
    const page = Number(body.page);
    const metadata = job.pages.get(guid);
    if (!Number.isInteger(page) || page < 0 || !metadata?.saved || page >= metadata.count) throw new HttpError(400, 'image page does not match chart metadata');
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
    job.images.add(`${guid}#${page}`);
    job.done = job.images.size;
    this.progress(job);
    return true;
  }

  async onDone(body: any): Promise<void> {
    const job = this.jobs.get(String(body.jobId));
    if (!job) return;
    const charts = new Set(job.index?.categories.flatMap((c) => c.charts.map((chart) => chart.guid)));
    const incomplete = !job.index || [...charts].some((guid) => {
      const pages = job.pages.get(guid);
      return !pages?.saved || Array.from({ length: pages.count }, (_, page) => `${guid}#${page}`).some((key) => !job.images.has(key));
    });
    const error = body.error ? String(body.error) : incomplete ?
      `Incomplete chart export (${job.done}/${job.total} pages); request the airport again to retry` : undefined;
    if (error) {
      log.warn(`${job.icao}: link reported error: ${error}`);
      this.hub.broadcast({ t: 'chartsError', icao: job.icao, message: error });
    } else {
      await this.store.saveIndex(job.index!);
      log.info(`${job.icao}: done (${job.done}/${job.total} pages)`);
      this.hub.broadcast({ t: 'chartsReady', icao: job.icao });
    }
    this.jobs.delete(job.id);
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
    if (Number(res.headers.get('content-length')) > MAX_IMAGE_BYTES || !res.body) {
      await res.body?.cancel();
      log.warn(`${what}: image exceeds download limit or has no body`);
      return undefined;
    }
    const reader = res.body.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > MAX_IMAGE_BYTES) {
          await reader.cancel();
          log.warn(`${what}: image exceeds download limit`);
          return undefined;
        }
        chunks.push(value);
      }
    } finally {
      reader.releaseLock();
    }
    const buf = Buffer.concat(chunks);
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
