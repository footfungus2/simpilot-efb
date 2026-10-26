// Job queue + ingest for the in-sim link panel. The panel polls GET /link/poll for work and does what it's told:
// list an airport's charts (cheap, no screen needed) or export one chart's pages (screen capture). The bridge decides
// the order, so the chart the iPad is waiting for always goes first.

import { randomUUID } from 'node:crypto';
import type { Hub } from '../hub.js';
import { HttpError } from '../http.js';
import { logger } from '../log.js';
import type { ChartIndex } from '../types.js';
import { type Capturer, ScreenCapture } from './capture.js';
import { icaoIdent, normalizeIndex, normalizePages } from './normalize.js';
import { type ChartStore, isPng, safeIcao } from './store.js';

const log = logger('link');

/** What the panel and the bridge speak; the panel sends its number with every poll. Keep in sync with sim-package/src/link.ts. */
export const LINK_PROTOCOL = 2;
/** A job the panel keeps losing (e.g. the sim crashes on it) is given up after this many tries. */
const MAX_ATTEMPTS = 3;
const MAX_JOBS = 64;

export interface Job {
  id: string;
  type: 'index' | 'chart';
  icao: string;
  provider: string;
  /** Chart jobs: the chart to export. */
  guid?: string;
  queuedAt: number;
  /** How often the panel was given this job. */
  attempts: number;
  indexSaved: boolean;
  /** Chart jobs: page count once the panel has sent the pages, and the pages that are on disk. */
  total: number;
  saved: Set<number>;
}

const chartGuids = (index: ChartIndex) => index.categories.flatMap((c) => c.charts.map((chart) => chart.guid)).sort().join('|');

export class ChartLink {
  private jobs = new Map<string, Job>();
  private warmedUp = false;

  constructor(
    private readonly store: ChartStore,
    private readonly hub: Hub,
    private readonly capturer: Capturer = new ScreenCapture(),
  ) {}

  private queue(type: Job['type'], icaoRaw: string, provider: string, guid?: string): Job {
    const icao = safeIcao(icaoRaw);
    const existing = [...this.jobs.values()].find((j) => j.type === type && j.icao === icao && j.provider === provider && j.guid === guid);
    if (existing) {
      existing.queuedAt = Date.now(); // asking again moves it to the front
      return existing;
    }
    if (this.jobs.size >= MAX_JOBS) throw new HttpError(429, 'too many pending chart requests');
    const job: Job = { id: randomUUID(), type, icao, provider, guid, queuedAt: Date.now(), attempts: 0, indexSaved: false, total: 0, saved: new Set() };
    this.jobs.set(job.id, job);
    log.info(`queued ${provider} ${type === 'index' ? 'chart list' : 'chart'} for ${icao}`);
    return job;
  }

  /** Queues the chart list of an airport unless that's already pending. */
  requestIndex(icao: string, provider = 'LIDO'): Job {
    return this.queue('index', icao, provider);
  }

  /** Queues the export of one chart (all its pages) unless that's already pending. */
  async requestChart(icao: string, guid: string, provider = 'LIDO'): Promise<Job> {
    const index = await this.store.getIndex(icao);
    if (!index?.categories.some((c) => c.charts.some((chart) => chart.guid === guid))) throw new HttpError(404, 'chart is not in the airport list');
    return this.queue('chart', icao, provider, guid);
  }

  /**
   * The panel only asks for work when it has nothing in progress, so a job it was given before and never finished was
   * lost (panel reloaded, sim restarted): it is simply offered again, a few times at most. While it is busy it polls
   * with `busy` just to show it is still there.
   */
  poll(busy = false, protocol = 0): { jobs: { id: string; type: string; icao: string; provider: string; guid?: string }[] } {
    this.hub.linkSeen();
    if (!this.warmedUp && protocol === LINK_PROTOCOL) {
      this.warmedUp = true;
      this.capturer.warmUp?.();
    }
    if (protocol !== LINK_PROTOCOL) {
      // A panel from another version would run the wrong kind of job; say so instead of handing it work.
      for (const job of [...this.jobs.values()]) {
        this.jobs.delete(job.id);
        this.fail(job, 'SimPilot Link in the sim is out of date. Close MSFS, run Install SimPilot Link again and start MSFS.');
      }
      return { jobs: [] };
    }
    if (busy) return { jobs: [] };
    for (const job of [...this.jobs.values()]) {
      if (job.attempts < MAX_ATTEMPTS) continue;
      this.jobs.delete(job.id);
      this.fail(job, 'The sim stopped answering while exporting; try again');
    }
    // Chart lists are quick, so they go first; of the charts only the newest request, the one being waited for.
    const jobs = [...this.jobs.values()];
    const chart = jobs.filter((j) => j.type === 'chart').sort((a, b) => b.queuedAt - a.queuedAt)[0];
    const out = [...jobs.filter((j) => j.type === 'index'), ...(chart ? [chart] : [])];
    for (const j of out) j.attempts++;
    return { jobs: out.map(({ id, type, icao, provider, guid }) => ({ id, type, icao, provider, guid })) };
  }

  async onIndex(body: any): Promise<void> {
    const job = this.job(body.jobId, 'index');
    const icao = safeIcao(icaoIdent(body.index?.airportIcao) || job.icao);
    if (icao !== job.icao || !Array.isArray(body.index?.charts)) throw new HttpError(400, 'chart index does not match requested airport');
    const index = normalizeIndex(body.index, icao, job.provider);
    const n = index.categories.reduce((s, c) => s + c.charts.length, 0);
    log.info(`${icao}: ${n} charts in ${index.categories.length} categories`);
    if (!n) return; // an empty list is more likely a hiccup than the truth; don't keep it
    const previous = await this.store.getIndex(icao).catch(() => undefined);
    await this.store.saveIndex(index);
    job.indexSaved = true;
    if (!previous || chartGuids(previous) !== chartGuids(index)) this.hub.broadcast({ t: 'chartsReady', icao });
  }

  /** Stores a chart's page metadata. Returns the pages that are already exported, which the panel skips. */
  async onPages(body: any): Promise<{ have: number[] }> {
    const job = this.job(body.jobId, 'chart');
    if (String(body.guid) !== job.guid) throw new HttpError(400, 'chart pages do not match the requested chart');
    const pages = normalizePages(body.pages);
    if (!pages.length || pages.some((p) => !Number.isFinite(p.width) || !Number.isFinite(p.height) || p.width <= 0 || p.height <= 0)) {
      throw new HttpError(400, 'chart pages require positive image dimensions');
    }
    await this.store.savePages(job.icao, job.guid!, pages);
    const have: number[] = [];
    for (const p of pages) if (await this.store.hasImage(job.icao, job.guid!, p.index)) have.push(p.index);
    job.total = pages.length;
    job.saved = new Set(have);
    this.progress(job);
    return { have };
  }

  /** One screen-captured tile of a page the panel is showing; the page is saved after its last tile. */
  async onCapture(body: any): Promise<boolean> {
    const job = this.job(body.jobId, 'chart');
    const page = Number(body.page);
    if (String(body.guid) !== job.guid || !Number.isInteger(page) || page < 0 || page >= job.total) throw new HttpError(400, 'capture page does not match chart metadata');
    const int = (v: unknown, max: number) => Number.isInteger(v) && (v as number) >= 0 && (v as number) <= max;
    const size = (v: any, min: number, max: number) => [v?.w, v?.h].every((n) => Number.isFinite(n) && n >= min && n <= max);
    const { i, j, cols, rows } = body;
    if (!int(cols, 16) || !int(rows, 64) || cols < 1 || rows < 1 || !int(i, cols - 1) || !int(j, rows - 1) ||
      !size(body.view, 50, 20_000) || !size(body.image, 1, 100_000)) {
      throw new HttpError(400, 'invalid capture tile');
    }
    await this.capturer.tile({ i, j, cols, rows, view: { w: body.view.w, h: body.view.h }, image: { w: body.image.w, h: body.image.h } });
    if (i !== cols - 1 || j !== rows - 1) return false;
    const png = await this.capturer.finish();
    if (!isPng(png)) throw new HttpError(500, 'chart capture produced no image');
    await this.store.saveImage(job.icao, job.guid!, page, png);
    job.saved.add(page);
    this.progress(job);
    return true;
  }

  async onDone(body: any): Promise<void> {
    const job = this.jobs.get(String(body.jobId));
    if (!job) return;
    this.jobs.delete(job.id);
    const error = body.error ? String(body.error) : this.incomplete(job);
    if (error) this.fail(job, error);
    else if (job.type === 'chart') {
      log.info(`${job.icao}: chart exported (${job.saved.size}/${job.total} pages)`);
      this.hub.broadcast({ t: 'chartReady', icao: job.icao, guid: job.guid! });
    }
  }

  private fail(job: Job, message: string): void {
    log.warn(`${job.icao}: ${message}`);
    this.hub.broadcast(job.type === 'index' ? { t: 'chartsError', icao: job.icao, message } : { t: 'chartError', icao: job.icao, guid: job.guid!, message });
  }

  private incomplete(job: Job): string | undefined {
    if (job.type === 'index') return job.indexSaved ? undefined : `The sim has no charts for ${job.icao}`;
    return job.total > 0 && job.saved.size >= job.total ? undefined : `Incomplete chart export (${job.saved.size}/${job.total} pages); try again`;
  }

  private progress(job: Job): void {
    this.hub.broadcast({ t: 'chartProgress', icao: job.icao, guid: job.guid!, done: job.saved.size, total: job.total });
  }

  private job(id: unknown, type: Job['type']): Job {
    const job = this.jobs.get(String(id));
    if (!job) throw new HttpError(404, `unknown job ${String(id)}`);
    if (job.type !== type) throw new HttpError(400, `job ${String(id)} is not a ${type} job`);
    return job;
  }
}
