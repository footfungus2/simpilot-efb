import fs from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import type { ChartIndex, ChartMeta, ChartPage } from '../types.js';
import type { StoredPage } from './normalize.js';

const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
type StoredChart = { pages: StoredPage[]; revision?: string };

export function isPng(buf: Buffer): boolean {
  return buf.length > 8 && buf.subarray(0, 8).equals(PNG_MAGIC);
}

/** Chart GUIDs come from the sim; keep only filesystem-safe characters. */
export function safeId(id: string): string {
  const s = id.replace(/[^A-Za-z0-9._{}-]/g, '_');
  if (!s || s === '.' || s === '..') throw new Error(`bad id: ${id}`);
  return s;
}

export function safeIcao(icao: string): string {
  const s = icao.trim().toUpperCase();
  if (!/^[A-Z0-9]{3,4}$/.test(s)) throw new Error(`bad ICAO: ${icao}`);
  return s;
}

/** On-disk cache: <root>/charts/<ICAO>/index.json, <ICAO>/<guid>/pages.json, <ICAO>/<guid>/<n>.png */
export class ChartStore {
  constructor(private readonly root: string) {}

  private airportDir(icao: string): string {
    return path.join(this.root, 'charts', safeIcao(icao));
  }

  private chartDir(icao: string, guid: string): string {
    return path.join(this.airportDir(icao), safeId(guid));
  }

  private revisionDir(icao: string, guid: string, revision: string): string {
    if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(revision)) throw new Error('bad chart revision');
    return path.join(this.chartDir(icao, guid), 'revisions', revision);
  }

  imagePath(icao: string, guid: string, page: number, revision?: string): string {
    if (!Number.isInteger(page) || page < 0) throw new Error(`bad page: ${page}`);
    const dir = revision === undefined ? this.chartDir(icao, guid) : this.revisionDir(icao, guid, revision);
    return path.join(dir, `${page}.png`);
  }

  async saveIndex(index: ChartIndex): Promise<void> {
    const dir = this.airportDir(index.icao);
    await fs.mkdir(dir, { recursive: true });
    await writeAtomic(path.join(dir, 'index.json'), JSON.stringify(index));
  }

  async getIndex(icao: string): Promise<ChartIndex | undefined> {
    return readJson<ChartIndex>(path.join(this.airportDir(icao), 'index.json'));
  }

  async savePages(icao: string, guid: string, pages: StoredPage[], revision?: string): Promise<void> {
    const dir = this.chartDir(icao, guid);
    await fs.mkdir(dir, { recursive: true });
    await writeAtomic(path.join(dir, 'pages.json'), JSON.stringify(revision ? { revision, pages } : pages));
  }

  private async storedChart(icao: string, guid: string): Promise<StoredChart | undefined> {
    const stored = await readJson<StoredPage[] | StoredChart>(path.join(this.chartDir(icao, guid), 'pages.json'));
    return Array.isArray(stored) ? { pages: stored } : stored;
  }

  async currentRevision(icao: string, guid: string): Promise<string | undefined> {
    return (await this.storedChart(icao, guid))?.revision;
  }

  async saveImage(icao: string, guid: string, page: number, png: Buffer, revision?: string): Promise<void> {
    if (!isPng(png)) throw new Error('not a PNG');
    const file = this.imagePath(icao, guid, page, revision);
    await fs.mkdir(path.dirname(file), { recursive: true });
    await writeAtomic(file, png);
  }

  async hasImage(icao: string, guid: string, page: number): Promise<boolean> {
    try {
      await fs.access(this.imagePath(icao, guid, page));
      return true;
    } catch {
      return false;
    }
  }

  async discardRevision(icao: string, guid: string, revision: string): Promise<void> {
    await fs.rm(this.revisionDir(icao, guid, revision), { recursive: true, force: true });
  }

  async publishRevision(icao: string, guid: string, pages: StoredPage[], revision: string): Promise<void> {
    const previous = await this.currentRevision(icao, guid);
    await Promise.all(pages.map((page) => fs.access(this.imagePath(icao, guid, page.index, revision))));
    await this.savePages(icao, guid, pages, revision);
    // Keep the preceding revision readable while iPads switch to the new page URLs.
    const dir = path.dirname(this.revisionDir(icao, guid, revision));
    const entries = await fs.readdir(dir).catch(() => []);
    await Promise.all(entries.filter((entry) => entry !== revision && entry !== previous)
      .map((entry) => fs.rm(path.join(dir, entry), { recursive: true, force: true }).catch(() => {})));
  }

  /** Chart metadata + pages in wire format, with image URLs only for pages whose PNG is cached. */
  async getChart(icao: string, guid: string): Promise<{ chart: ChartMeta; pages: ChartPage[] } | undefined> {
    const index = await this.getIndex(icao);
    const chart = index?.categories.flatMap((c) => c.charts).find((c) => c.guid === guid);
    const stored = await this.storedChart(icao, guid);
    if (!chart || !stored) return undefined;
    const pages: ChartPage[] = [];
    for (const p of stored.pages) {
      const version = await fs.stat(this.imagePath(icao, guid, p.index, stored.revision)).then((s) => Math.round(s.mtimeMs), () => undefined);
      const revision = stored.revision ? `&revision=${stored.revision}` : '';
      pages.push({
        index: p.index,
        width: p.width,
        height: p.height,
        geoReferenced: p.geoReferenced,
        areas: p.areas,
        image: version === undefined ? null : `/charts/${safeIcao(icao)}/${encodeURIComponent(guid)}/${p.index}.png?v=${version}${revision}`,
      });
    }
    return { chart: { ...chart, pageCount: stored.pages.length }, pages };
  }
}

async function readJson<T>(file: string): Promise<T | undefined> {
  try {
    return JSON.parse(await fs.readFile(file, 'utf8')) as T;
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return undefined;
    throw err;
  }
}

async function writeAtomic(file: string, data: string | Buffer): Promise<void> {
  const tmp = `${file}.${randomUUID()}.tmp`;
  try {
    await fs.writeFile(tmp, data);
    await fs.rename(tmp, file);
  } finally {
    await fs.rm(tmp, { force: true });
  }
}
