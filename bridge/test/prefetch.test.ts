import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Capturer } from '../src/charts/capture.js';
import { ChartLink, LINK_PROTOCOL } from '../src/charts/link.js';
import { type FlightWant, pickFlightCharts } from '../src/charts/prefetch.js';
import { ChartStore } from '../src/charts/store.js';
import { Hub } from '../src/hub.js';
import type { ChartIndex, ChartMeta } from '../src/types.js';

const chart = (guid: string, type: string, procedures: string[] = [], runways: string[] = []): ChartMeta =>
  ({ guid, type, name: guid, procedures, runways, geoReferenced: false, validFrom: null, validUntil: null });
const indexOf = (...charts: ChartMeta[]): ChartIndex => ({ icao: 'EGSS', provider: 'LIDO', fetchedAt: 0, categories: [{ name: 'All', charts }] });
const rawChart = (c: ChartMeta) => ({
  guid: c.guid, type: c.type, name: c.name,
  procedures: c.procedures.map((ident) => ({ type: c.type === 'SID' ? 0 : 1, ident })),
  runways: c.runways.map((number) => ({ number })),
});

describe('which charts a flight needs', () => {
  const all = indexOf(
    chart('sid-cln5s', 'SID', ['CLN5S']), chart('sid-det2d', 'SID', ['DET2D']), chart('star-lam', 'STAR', ['LAM1A']),
    chart('iac-04', 'IAC', ['ILS 04'], ['04']), chart('iac-22', 'IAC', ['ILS 22'], ['22']), chart('agc', 'AGC'),
  );
  const pick = (want: FlightWant) => pickFlightCharts(all, want);

  it('takes the SID at the origin, however its name is spaced', () => {
    expect(pick({ role: 'origin', procedures: ['CLN5S'] })).toEqual(['sid-cln5s']);
    expect(pick({ role: 'origin', procedures: ['cln 5s'] })).toEqual(['sid-cln5s']);
    expect(pick({ role: 'origin', procedures: [] })).toEqual([]);
  });

  it('takes the STAR and the approaches of the planned runway at the destination', () => {
    expect(pick({ role: 'destination', procedures: ['LAM1A'], runway: '4' })).toEqual(['star-lam', 'iac-04']);
    expect(pick({ role: 'destination', procedures: [], runway: '22' })).toEqual(['iac-22']);
  });

  it('does not take approaches at the origin', () => {
    expect(pick({ role: 'origin', procedures: ['CLN5S'], runway: '04' })).toEqual(['sid-cln5s']);
  });
});

describe('exporting a flight\'s charts ahead of time', () => {
  let dir: string;
  let store: ChartStore;
  let hub: Hub;
  let link: ChartLink;
  const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(16)]);
  const capturer: Capturer = { tile: async () => {}, finish: async () => png };
  const sid = chart('sid-cln5s', 'SID', ['CLN5S']);
  const other = chart('iac-04', 'IAC', ['ILS 04'], ['04']);
  const want: FlightWant = { role: 'origin', procedures: ['CLN5S'] };

  beforeEach(async () => {
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    dir = await fs.mkdtemp(path.join(os.tmpdir(), 'simpilot-prefetch-'));
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

  const polled = () => link.poll(false, LINK_PROTOCOL).jobs;

  /** The panel lists the airport's charts. */
  async function listed() {
    const job = link.requestIndex('EGSS');
    await link.onIndex({ jobId: job.id, index: { airportIcao: { ident: 'EGSS' }, charts: [{ name: 'All', charts: [sid, other].map(rawChart) }] } });
    await link.onDone({ jobId: job.id });
  }

  it('waits for the chart list, then queues the flight\'s chart', async () => {
    link.requestIndex('EGSS');
    await link.wantFlightCharts('EGSS', want);
    expect(polled().map((j) => j.type)).toEqual(['index']);
    await listed();
    expect(polled().map((j) => j.guid)).toEqual(['sid-cln5s']);
  });

  it('queues straight away when the list is already cached', async () => {
    await listed();
    await link.wantFlightCharts('EGSS', want);
    expect(polled().map((j) => j.guid)).toEqual(['sid-cln5s']);
  });

  it('gives a chart the iPad opens priority over a newer ahead-of-time one', async () => {
    await listed();
    await link.wantFlightCharts('EGSS', want);
    const opened = await link.requestChart('EGSS', 'iac-04');
    expect(polled().map((j) => j.id)).toEqual([opened.id]);
  });

  it('treats a prefetched chart that is then opened as asked for', async () => {
    await listed();
    await link.wantFlightCharts('EGSS', want);
    const job = await link.requestChart('EGSS', 'sid-cln5s');
    expect(job.prefetch).toBe(false);
  });

  it('does not tell the iPad when an ahead-of-time chart fails', async () => {
    await listed();
    await link.wantFlightCharts('EGSS', want);
    const [job] = polled();
    (hub.broadcast as ReturnType<typeof vi.fn>).mockClear();
    await link.onDone({ jobId: job!.id, error: 'sim said no' });
    expect(hub.broadcast).not.toHaveBeenCalled();
  });

  it('skips a chart that is already exported', async () => {
    await listed();
    const first = await link.requestChart('EGSS', 'sid-cln5s');
    await link.onPages({ jobId: first.id, guid: 'sid-cln5s', pages: [{ width: 10, height: 14 }] });
    await link.onCapture({ jobId: first.id, guid: 'sid-cln5s', page: 0, i: 0, j: 0, cols: 1, rows: 1, view: { w: 600, h: 400 }, image: { w: 600, h: 400 } });
    await link.onDone({ jobId: first.id });
    await link.wantFlightCharts('EGSS', want);
    expect(polled()).toEqual([]);
  });
});
