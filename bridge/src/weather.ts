// Real-world weather from aviationweather.gov (free, global METAR/TAF + international SIGMETs).
// Results are cached briefly so several app screens can poll without hammering the API.

import { HttpError } from './http.js';

const BASE = 'https://aviationweather.gov/api/data';
const TTL_MS = 5 * 60_000;

const cache = new Map<string, { at: number; data: unknown }>();

async function cached<T>(key: string, load: () => Promise<T>): Promise<T> {
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < TTL_MS) return hit.data as T;
  const data = await load();
  cache.set(key, { at: Date.now(), data });
  return data;
}

async function getJson(url: string): Promise<any> {
  const res = await fetch(url, { signal: AbortSignal.timeout(20_000), headers: { 'user-agent': 'SimPilotEFB-bridge' } });
  if (res.status === 204) return [];
  if (!res.ok) throw new HttpError(502, `aviationweather.gov HTTP ${res.status}`);
  return res.json();
}

export function parseIds(raw: string | null): string[] {
  return [...new Set((raw ?? '').split(',').map((s) => s.trim().toUpperCase()).filter((s) => /^[A-Z0-9]{3,4}$/.test(s)))].sort();
}

/**
 * Lido-style colour category for the graphical METAR indicator.
 * green ≥ 5 km and ceiling ≥ 1500 ft; amber ≥ 1.5 km / 500 ft; red below.
 */
export type WxCategory = 'green' | 'amber' | 'red' | 'unknown';

export function metarCategory(m: { visib?: unknown; clouds?: { cover?: string; base?: number | null }[] }): WxCategory {
  const visSm = typeof m.visib === 'number' ? m.visib : typeof m.visib === 'string' ? Number.parseFloat(m.visib) : NaN;
  const ceiling = (m.clouds ?? [])
    .filter((c) => c.cover === 'BKN' || c.cover === 'OVC' || c.cover === 'OVX')
    .map((c) => c.base ?? 0)
    .reduce((min, b) => Math.min(min, b), Infinity);
  if (!Number.isFinite(visSm) && ceiling === Infinity) return 'unknown';
  const visKm = Number.isFinite(visSm) ? visSm * 1.609 : Infinity;
  if (visKm < 1.5 || ceiling < 500) return 'red';
  if (visKm < 5 || ceiling < 1500) return 'amber';
  return 'green';
}

export async function metars(ids: string[]): Promise<unknown[]> {
  if (ids.length === 0) return [];
  return cached(`metar:${ids.join(',')}`, async () => {
    const list = (await getJson(`${BASE}/metar?ids=${ids.join(',')}&format=json`)) as any[];
    return list.map((m) => ({ ...m, category: metarCategory(m) }));
  });
}

/** METARs inside a lat/lon box, for the enroute map's graphical indicators. */
export async function metarsInBox(minLat: number, minLon: number, maxLat: number, maxLon: number): Promise<unknown[]> {
  const r = (n: number) => Math.round(n * 10) / 10;
  const bbox = [r(minLat), r(minLon), r(maxLat), r(maxLon)].join(',');
  return cached(`metarbox:${bbox}`, async () => {
    const list = (await getJson(`${BASE}/metar?bbox=${bbox}&format=json`)) as any[];
    return list.map((m) => ({
      icao: m.icaoId,
      lat: m.lat,
      lon: m.lon,
      category: metarCategory(m),
      raw: m.rawOb,
      obsTime: m.obsTime,
    }));
  });
}

export async function tafs(ids: string[]): Promise<unknown[]> {
  if (ids.length === 0) return [];
  return cached(`taf:${ids.join(',')}`, () => getJson(`${BASE}/taf?ids=${ids.join(',')}&format=json`));
}

/** International SIGMETs as a GeoJSON FeatureCollection of polygons. */
export async function sigmets(): Promise<unknown> {
  return cached('isigmet', async () => {
    const list = (await getJson(`${BASE}/isigmet?format=json`)) as any[];
    return {
      type: 'FeatureCollection',
      features: list
        .filter((s) => Array.isArray(s.coords) && s.coords.length >= 3)
        .map((s) => ({
          type: 'Feature',
          properties: {
            fir: s.firId,
            firName: s.firName,
            hazard: s.hazard,
            qualifier: s.qualifier,
            base: s.base,
            top: s.top,
            validFrom: s.validTimeFrom,
            validTo: s.validTimeTo,
            raw: s.rawSigmet,
          },
          geometry: {
            type: 'Polygon',
            coordinates: [s.coords.map((c: { lon: number; lat: number }) => [c.lon, c.lat])],
          },
        })),
    };
  });
}
