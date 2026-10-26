import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { type CaptureTile, type Capturer, ScreenCapture } from '../src/charts/capture.js';
import { ChartLink, LINK_PROTOCOL } from '../src/charts/link.js';
import { HttpError } from '../src/http.js';
import { ChartStore } from '../src/charts/store.js';
import { Hub } from '../src/hub.js';

const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(16)]);
const rawIndex = (...guids: string[]) => ({ airportIcao: { ident: 'EDDF' }, charts: [{ name: 'IAC', charts: guids.map((guid) => ({ guid })) }] });
const pages = (n: number) => Array.from({ length: n }, () => ({ width: 10, height: 14 }));
const tile = (jobId: string, page: number, i = 0, j = 0, cols = 1, rows = 1, guid = 'chart-1') =>
  ({ jobId, guid, page, i, j, cols, rows, view: { w: 600, h: 400 }, image: { w: 600 * cols, h: 400 * rows } });

describe('chart list and chart export', () => {
  let dir: string;
  let store: ChartStore;
  let hub: Hub;
  let link: ChartLink;
  const capturer: Capturer = { tile: async () => {}, finish: async () => png };
  beforeEach(async () => {
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    dir = await fs.mkdtemp(path.join(os.tmpdir(), 'simpilot-job-'));
    store = new ChartStore(dir);
    hub = new Hub();
    vi.spyOn(hub, 'broadcast');
    link = new ChartLink(store, hub, capturer);
  });
  afterEach(async () => {
    vi.useRealTimers();
    vi.restoreAllMocks();
    await fs.rm(dir, { recursive: true, force: true });
  });

  /** The panel lists the airport's charts. */
  async function listed(...guids: string[]) {
    const job = link.requestIndex('EDDF');
    await link.onIndex({ jobId: job.id, index: rawIndex(...(guids.length ? guids : ['chart-1', 'chart-2'])) });
    await link.onDone({ jobId: job.id });
  }

  /** The panel sends the pages of a chart and exports the ones the bridge doesn't have yet. */
  async function exportChart(guid: string, count: number, skip: number[] = []) {
    const job = await link.requestChart('EDDF', guid);
    const { have } = await link.onPages({ jobId: job.id, guid, pages: pages(count) });
    for (let page = 0; page < count; page++) if (!have.includes(page) && !skip.includes(page)) await link.onCapture(tile(job.id, page, 0, 0, 1, 1, guid));
    return { job, have };
  }

  it('saves the chart list as soon as the panel sends it and tells the iPad once', async () => {
    const job = link.requestIndex('EDDF');
    expect(link.requestIndex('eddf')).toBe(job);
    await link.onIndex({ jobId: job.id, index: rawIndex('chart-1') });
    expect((await store.getIndex('EDDF'))?.categories[0]?.charts.map((c) => c.guid)).toEqual(['chart-1']);
    expect(hub.broadcast).toHaveBeenLastCalledWith({ t: 'chartsReady', icao: 'EDDF' });
    await link.onDone({ jobId: job.id });
    expect(hub.broadcast).toHaveBeenCalledTimes(1);
    // A refresh with the same charts changes nothing for the app; a changed list does.
    const refresh = link.requestIndex('EDDF');
    await link.onIndex({ jobId: refresh.id, index: rawIndex('chart-1') });
    expect(hub.broadcast).toHaveBeenCalledTimes(1);
    await link.onIndex({ jobId: refresh.id, index: rawIndex('chart-1', 'chart-3') });
    expect(hub.broadcast).toHaveBeenCalledTimes(2);
  });

  it('does not keep an empty chart list and reports it', async () => {
    const job = link.requestIndex('EDDF');
    await link.onIndex({ jobId: job.id, index: rawIndex() });
    await link.onDone({ jobId: job.id });
    expect(await store.getIndex('EDDF')).toBeUndefined();
    expect(hub.broadcast).toHaveBeenLastCalledWith({ t: 'chartsError', icao: 'EDDF', message: 'The sim has no charts for EDDF' });
  });

  it('exports a chart page by page and reports it ready only when every page is saved', async () => {
    await listed();
    const job = await link.requestChart('EDDF', 'chart-1');
    await link.onPages({ jobId: job.id, guid: 'chart-1', pages: pages(2) });
    expect(hub.broadcast).toHaveBeenLastCalledWith({ t: 'chartProgress', icao: 'EDDF', guid: 'chart-1', done: 0, total: 2 });
    expect(await link.onCapture(tile(job.id, 0))).toBe(true);
    expect(hub.broadcast).toHaveBeenLastCalledWith({ t: 'chartProgress', icao: 'EDDF', guid: 'chart-1', done: 1, total: 2 });
    await link.onDone({ jobId: job.id });
    expect(hub.broadcast).toHaveBeenLastCalledWith(expect.objectContaining({ t: 'chartError', guid: 'chart-1' }));
    // Trying again keeps page 1 and exports only the missing one.
    const { job: retry, have } = await exportChart('chart-1', 2);
    expect(have).toEqual([0]);
    await link.onDone({ jobId: retry.id });
    expect(hub.broadcast).toHaveBeenLastCalledWith({ t: 'chartReady', icao: 'EDDF', guid: 'chart-1' });
    const chart = await store.getChart('EDDF', 'chart-1');
    expect(chart?.pages.map((p) => p.image)).toEqual([expect.stringMatching(/\/0\.png\?v=\d+$/), expect.stringMatching(/\/1\.png\?v=\d+$/)]);
  });

  it('shows the error the panel reports instead of calling the chart ready', async () => {
    await listed();
    const { job } = await exportChart('chart-1', 1);
    await link.onDone({ jobId: job.id, error: "Can't see the SimPilot Link window" });
    expect(hub.broadcast).toHaveBeenLastCalledWith({ t: 'chartError', icao: 'EDDF', guid: 'chart-1', message: "Can't see the SimPilot Link window" });
  });

  it('only exports charts that are in the airport list', async () => {
    await expect(link.requestChart('EDDF', 'chart-1')).rejects.toThrow('not in the airport list');
    await listed();
    await expect(link.requestChart('EDDF', '../unknown')).rejects.toThrow('not in the airport list');
    expect((await link.requestChart('EDDF', 'chart-2')).guid).toBe('chart-2');
  });

  it('hands the panel chart lists first, then the charts newest request first, one per poll', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    await listed('chart-1', 'chart-2', 'chart-3');
    const first = await link.requestChart('EDDF', 'chart-1');
    vi.advanceTimersByTime(10);
    const second = await link.requestChart('EDDF', 'chart-2');
    vi.advanceTimersByTime(10);
    const list = link.requestIndex('EGLL');
    const ids = () => link.poll(false, LINK_PROTOCOL).jobs.map((j) => j.id);
    expect(ids()).toEqual([list.id, second.id]);
    await link.onDone({ jobId: list.id, error: 'x' });
    await link.onDone({ jobId: second.id, error: 'x' });
    expect(ids()).toEqual([first.id]);
    await link.onDone({ jobId: first.id, error: 'x' });
    expect(ids()).toEqual([]);
  });

  it('moves a chart that is asked for again to the front', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    await listed();
    const first = await link.requestChart('EDDF', 'chart-1');
    vi.advanceTimersByTime(10);
    const second = await link.requestChart('EDDF', 'chart-2');
    vi.advanceTimersByTime(10);
    expect(await link.requestChart('EDDF', 'chart-1')).toBe(first);
    expect(link.poll(false, LINK_PROTOCOL).jobs.map((j) => j.id)).toEqual([first.id]);
    await link.onDone({ jobId: first.id, error: 'x' });
    expect(link.poll(false, LINK_PROTOCOL).jobs.map((j) => j.id)).toEqual([second.id]);
  });

  it('tells the app when the panel in the sim is from another version instead of handing it work', async () => {
    await listed();
    await link.requestChart('EDDF', 'chart-1');
    link.requestIndex('EGLL');
    expect(link.poll().jobs).toEqual([]);
    expect(hub.broadcast).toHaveBeenCalledWith({ t: 'chartError', icao: 'EDDF', guid: 'chart-1', message: expect.stringContaining('out of date') });
    expect(hub.broadcast).toHaveBeenCalledWith({ t: 'chartsError', icao: 'EGLL', message: expect.stringContaining('Install SimPilot Link') });
    expect(link.poll(false, LINK_PROTOCOL - 1).jobs).toEqual([]);
    link.requestIndex('EGLL');
    expect(link.poll(false, LINK_PROTOCOL).jobs).toHaveLength(1);
  });

  it('gets the screen capture ready once, when the panel first connects', () => {
    const warmUp = vi.fn();
    link = new ChartLink(store, hub, { ...capturer, warmUp });
    link.poll(false, LINK_PROTOCOL - 1);
    expect(warmUp).not.toHaveBeenCalled();
    link.poll(false, LINK_PROTOCOL);
    link.poll(true, LINK_PROTOCOL);
    expect(warmUp).toHaveBeenCalledTimes(1);
  });

  it('only shows the panel is alive when it polls while busy', async () => {
    await listed();
    const job = await link.requestChart('EDDF', 'chart-1');
    vi.spyOn(hub, 'linkSeen');
    expect(link.poll(true, LINK_PROTOCOL).jobs).toEqual([]);
    expect(hub.linkSeen).toHaveBeenCalledTimes(1);
    expect(link.poll(false, LINK_PROTOCOL).jobs.map((j) => j.id)).toEqual([job.id]);
    for (let n = 0; n < 5; n++) link.poll(true, LINK_PROTOCOL); // not counted as lost tries
    expect(link.poll(false, LINK_PROTOCOL).jobs.map((j) => j.id)).toEqual([job.id]);
  });

  it('offers a job the panel lost again, and gives up after three tries', async () => {
    await listed();
    const job = await link.requestChart('EDDF', 'chart-1');
    // The panel only polls when it is idle, so a poll with the job still open means it lost the job.
    for (let attempt = 0; attempt < 3; attempt++) expect(link.poll(false, LINK_PROTOCOL).jobs.map((j) => j.id)).toEqual([job.id]);
    expect(link.poll(false, LINK_PROTOCOL).jobs).toEqual([]);
    expect(hub.broadcast).toHaveBeenLastCalledWith({ t: 'chartError', icao: 'EDDF', guid: 'chart-1', message: 'The sim stopped answering while exporting; try again' });
    // The app can ask again afterwards.
    expect((await link.requestChart('EDDF', 'chart-1')).id).not.toBe(job.id);
  });

  it('rejects metadata outside the current job', async () => {
    await listed();
    const list = link.requestIndex('EDDF');
    await expect(link.onIndex({ jobId: list.id, index: { airportIcao: 'EGSS', charts: [] } })).rejects.toThrow('requested airport');
    await expect(link.onPages({ jobId: list.id, guid: 'chart-1', pages: pages(1) })).rejects.toThrow('not a chart job');
    const job = await link.requestChart('EDDF', 'chart-1');
    await expect(link.onPages({ jobId: job.id, guid: 'chart-2', pages: pages(1) })).rejects.toThrow('requested chart');
    await expect(link.onPages({ jobId: job.id, guid: 'chart-1', pages: [{ width: 0, height: 5 }] })).rejects.toThrow('dimensions');
    await expect(link.onCapture(tile(job.id, 0))).rejects.toThrow('does not match'); // pages not sent yet
    await link.onPages({ jobId: job.id, guid: 'chart-1', pages: pages(1) });
    await expect(link.onCapture(tile(job.id, 1))).rejects.toThrow('does not match');
    await expect(link.onCapture({ ...tile(job.id, 0), i: 1 })).rejects.toThrow('invalid capture tile');
    await expect(link.onPages({ jobId: 'nope', guid: 'chart-1', pages: pages(1) })).rejects.toThrow('unknown job');
  });

  it('captures every tile and saves the stitched page after the last one', async () => {
    const tiles: CaptureTile[] = [];
    link = new ChartLink(store, hub, { tile: async (t) => void tiles.push(t), finish: async () => png });
    await listed();
    const job = await link.requestChart('EDDF', 'chart-1');
    await link.onPages({ jobId: job.id, guid: 'chart-1', pages: pages(1) });
    const saved = [];
    for (const [i, j] of [[0, 0], [1, 0], [0, 1], [1, 1]] as const) saved.push(await link.onCapture(tile(job.id, 0, i, j, 2, 2)));
    expect(saved).toEqual([false, false, false, true]);
    expect(tiles.map((t) => [t.i, t.j])).toEqual([[0, 0], [1, 0], [0, 1], [1, 1]]);
    expect(await store.hasImage('EDDF', 'chart-1', 0)).toBe(true);
  });

  it('passes the helper error on to the panel', async () => {
    link = new ChartLink(store, hub, {
      tile: async () => { throw new HttpError(409, "Can't see the SimPilot Link window"); },
      finish: async () => Buffer.alloc(0),
    });
    await listed();
    const job = await link.requestChart('EDDF', 'chart-1');
    await link.onPages({ jobId: job.id, guid: 'chart-1', pages: pages(1) });
    await expect(link.onCapture(tile(job.id, 0))).rejects.toThrow(/SimPilot Link window/);
    expect(await store.hasImage('EDDF', 'chart-1', 0)).toBe(false);
  });
});

// Compiles and runs the real helper; only meaningful on Windows (CI runs it there).
describe.runIf(process.platform === 'win32')('screen capture helper on Windows', () => {
  it('starts and answers commands', async () => {
    const capture = new ScreenCapture();
    try {
      // No SimPilot Link window on screen here: the helper must answer with an error, not hang or crash.
      await expect(capture.tile({ i: 0, j: 0, cols: 1, rows: 1, view: { w: 600, h: 400 }, image: { w: 600, h: 800 } }))
        .rejects.toThrow(/SimPilot Link window|handle|screen/i);
      await expect(capture.finish()).rejects.toThrow(/interrupted/);
    } finally {
      capture.stop();
    }
  }, 120_000);
});
