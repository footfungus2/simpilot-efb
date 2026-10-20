// Converts the raw objects the in-sim link forwards from the SDK's ChartsClient
// (SimChartIndex / SimChartPage, see @microsoft/msfs-sdk) into our wire types.
// Everything is read defensively: the link is forwarding sim-provided JSON as-is.

import type { ChartArea, ChartIndex, ChartMeta, Rect } from '../types.js';

type Raw = Record<string, any>;

export function runwayLabel(rwy: Raw | undefined | null): string {
  if (!rwy) return '';
  const num = String(rwy.number ?? '').trim();
  const des = String(rwy.designator ?? '').trim();
  if (!num) return '';
  return `${num.padStart(2, '0')}${des}`;
}

export function procedureLabel(proc: Raw): string {
  // ChartProcedureType: 0 = SID, 1 = STAR, 2 = Approach
  if (proc?.type === 2 && proc.approachIdentifier) {
    const a = proc.approachIdentifier;
    const parts = [String(a.type ?? '').trim(), String(a.suffix ?? '').trim(), runwayLabel(a.runway)];
    return parts.filter(Boolean).join(' ');
  }
  const ident = String(proc?.ident ?? '').trim();
  const trans = String(proc?.enrouteTransition ?? '').trim();
  return trans && trans !== ident ? `${ident}.${trans}` : ident;
}

export function icaoIdent(icao: unknown): string {
  if (typeof icao === 'string') return icao.trim().toUpperCase();
  if (icao && typeof icao === 'object' && 'ident' in icao) return String((icao as Raw).ident).trim().toUpperCase();
  return '';
}

function uniq(xs: string[]): string[] {
  return [...new Set(xs.filter(Boolean))];
}

export function normalizeChartMeta(c: Raw): ChartMeta {
  const procs: Raw[] = Array.isArray(c.procedures) ? c.procedures : [];
  const runways: Raw[] = Array.isArray(c.runways) ? c.runways : [];
  return {
    guid: String(c.guid),
    type: String(c.type ?? 'UNKNOWN'),
    name: String(c.name ?? ''),
    runways: uniq([...runways.map(runwayLabel), ...procs.flatMap((p) => (p.runways ?? []).map(runwayLabel))]),
    procedures: uniq(procs.map(procedureLabel)),
    geoReferenced: Boolean(c.geoReferenced),
    validFrom: typeof c.validFrom === 'number' ? c.validFrom : null,
    validUntil: typeof c.validUntil === 'number' ? c.validUntil : null,
  };
}

export function normalizeIndex(raw: Raw, icao: string, provider: string): ChartIndex {
  const cats: Raw[] = Array.isArray(raw?.charts) ? raw.charts : [];
  return {
    icao,
    provider,
    fetchedAt: Date.now(),
    categories: cats.map((cat) => ({
      name: String(cat.name ?? 'Other'),
      charts: (Array.isArray(cat.charts) ? cat.charts : []).filter((c: Raw) => c?.guid).map(normalizeChartMeta),
    })),
  };
}

function rect(r: Raw | undefined): Rect | undefined {
  if (!r || !Array.isArray(r.upperLeft) || !Array.isArray(r.lowerRight)) return undefined;
  return {
    upperLeft: [Number(r.upperLeft[0]), Number(r.upperLeft[1])],
    lowerRight: [Number(r.lowerRight[0]), Number(r.lowerRight[1])],
    orientation: Number(r.orientation ?? 0),
  };
}

export function normalizeArea(a: Raw): ChartArea | undefined {
  const chartRect = rect(a?.chartRectangle);
  if (!chartRect) return undefined;
  const area: ChartArea = { layer: String(a.layer ?? ''), geoReferenced: Boolean(a.geoReferenced), chartRect };
  if (area.geoReferenced) {
    area.worldRect = rect(a.worldRectangle);
    const p = a.projection;
    if (p) {
      area.projection = {
        standardParallel1: Number(p.standardParallel1),
        standardParallel2: Number(p.standardParallel2),
        centralMeridian: Number(p.centralMeridian),
      };
    }
    if (!area.worldRect || !area.projection) area.geoReferenced = false;
  }
  return area;
}

export interface StoredPage {
  index: number;
  width: number;
  height: number;
  geoReferenced: boolean;
  areas: ChartArea[];
  /** Raw URL list from the sim, kept for diagnostics and re-downloads. */
  urls: { name: string; url: string }[];
}

export function normalizePages(rawPages: Raw[]): StoredPage[] {
  return (Array.isArray(rawPages) ? rawPages : []).map((p, index) => ({
    index,
    width: Number(p?.width ?? 0),
    height: Number(p?.height ?? 0),
    geoReferenced: Boolean(p?.geoReferenced),
    areas: (Array.isArray(p?.areas) ? p.areas : []).map(normalizeArea).filter((a: ChartArea | undefined): a is ChartArea => !!a),
    urls: (Array.isArray(p?.urls) ? p.urls : []).map((u: Raw) => ({ name: String(u?.name ?? ''), url: String(u?.url ?? '') })),
  }));
}

/** Picks the PNG URL of a page (ChartView docs say page URLs point to PNG files). */
export function pickImageUrl(urls: { name: string; url: string }[]): string | undefined {
  const png = urls.find((u) => /png/i.test(u.name) || /\.png(\?|$)/i.test(u.url));
  return (png ?? urls[0])?.url || undefined;
}
