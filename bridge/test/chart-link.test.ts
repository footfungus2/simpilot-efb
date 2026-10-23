import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ChartLink } from '../src/charts/link.js';
import { ChartStore } from '../src/charts/store.js';
import { Hub } from '../src/hub.js';

const pngBase64 = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(16)]).toString('base64');

describe('chart export completion', () => {
  let dir: string;
  let store: ChartStore;
  let hub: Hub;
  let link: ChartLink;
  beforeEach(async () => {
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    dir = await fs.mkdtemp(path.join(os.tmpdir(), 'simpilot-job-'));
    store = new ChartStore(dir);
    hub = new Hub();
    vi.spyOn(hub, 'broadcast');
    link = new ChartLink(store, hub);
  });
  afterEach(async () => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
    await fs.rm(dir, { recursive: true, force: true });
  });

  async function start() {
    const job = link.request('EDDF');
    await link.onIndex({ jobId: job.id, index: { airportIcao: { ident: 'EDDF' }, charts: [{ name: 'IAC', charts: [{ guid: 'chart-1' }] }] } });
    await link.onPages({ jobId: job.id, guid: 'chart-1', pages: [{ width: 10, height: 10 }, { width: 10, height: 10 }] });
    return job;
  }

  it('publishes the cache only after all images are saved, counting duplicate uploads once', async () => {
    const job = await start();
    expect(await store.getIndex('EDDF')).toBeUndefined();
    for (const page of [0, 0, 1]) await link.onImage({ jobId: job.id, guid: 'chart-1', page, pngBase64 });
    expect(hub.broadcast).toHaveBeenLastCalledWith({ t: 'chartsProgress', icao: 'EDDF', done: 2, total: 2 });
    await link.onDone({ jobId: job.id });
    expect(await store.getIndex('EDDF')).toBeDefined();
    expect(hub.broadcast).toHaveBeenLastCalledWith({ t: 'chartsReady', icao: 'EDDF' });
  });

  it('does not poison the cache with an incomplete export and permits retry', async () => {
    const job = await start();
    await link.onImage({ jobId: job.id, guid: 'chart-1', page: 0, pngBase64 });
    await link.onDone({ jobId: job.id });
    expect(await store.getIndex('EDDF')).toBeUndefined();
    expect(hub.broadcast).toHaveBeenLastCalledWith(expect.objectContaining({ t: 'chartsError' }));
    expect(link.request('EDDF').id).not.toBe(job.id);
  });

  it('counts concurrent duplicate page metadata once', async () => {
    const job = link.request('EDDF');
    await link.onIndex({ jobId: job.id, index: { charts: [{ charts: [{ guid: 'chart-1' }] }] } });
    const metadata = { jobId: job.id, guid: 'chart-1', pages: [{ width: 10, height: 10 }] };
    await Promise.all([link.onPages(metadata), link.onPages(metadata)]);
    await link.onImage({ jobId: job.id, guid: 'chart-1', page: 0, pngBase64 });
    expect(hub.broadcast).toHaveBeenLastCalledWith({ t: 'chartsProgress', icao: 'EDDF', done: 1, total: 1 });
    await link.onDone({ jobId: job.id });
    expect(hub.broadcast).toHaveBeenLastCalledWith({ t: 'chartsReady', icao: 'EDDF' });
  });

  it('checks every current chart GUID when an index changes during export', async () => {
    const job = await start();
    for (const page of [0, 1]) await link.onImage({ jobId: job.id, guid: 'chart-1', page, pngBase64 });
    await link.onIndex({ jobId: job.id, index: { charts: [{ charts: [{ guid: 'chart-2' }] }] } });
    await link.onDone({ jobId: job.id });
    expect(await store.getIndex('EDDF')).toBeUndefined();
    expect(hub.broadcast).toHaveBeenLastCalledWith(expect.objectContaining({ t: 'chartsError' }));
  });

  it('rejects airport, chart and image metadata outside the current job', async () => {
    const job = await start();
    await expect(link.onIndex({ jobId: job.id, index: { airportIcao: 'EGSS', charts: [] } })).rejects.toThrow('requested airport');
    await expect(link.onPages({ jobId: job.id, guid: '../unknown', pages: [] })).rejects.toThrow('index');
    await expect(link.onImage({ jobId: job.id, guid: 'chart-1', page: 20, pngBase64 })).rejects.toThrow('metadata');
  });

  it('bounds streamed image downloads even without a content-length header', async () => {
    const job = await start();
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(new ReadableStream({
      start(controller) {
        controller.enqueue(new Uint8Array(24 * 1024 * 1024 + 1));
        controller.close();
      },
    }))));
    await expect(link.onImage({ jobId: job.id, guid: 'chart-1', page: 0, url: 'https://charts.example/image.png?token=secret' })).resolves.toBe(false);
    expect(await store.hasImage('EDDF', 'chart-1', 0)).toBe(false);
  });
});
