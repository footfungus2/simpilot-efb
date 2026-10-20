// Fetches the latest SimBrief OFP for a user and reduces it to what the Flight Folder needs.
// SimBrief's JSON is all strings; numbers are parsed here.

import { HttpError } from './http.js';

export interface OfpAirport {
  icao: string;
  iata: string;
  name: string;
  lat: number;
  lon: number;
  elevFt: number;
  planRwy: string;
  metar: string;
}

export interface OfpFix {
  ident: string;
  name: string;
  type: string;
  lat: number;
  lon: number;
  altFt: number;
  airway: string;
  stage: string;
  isSidStar: boolean;
  legNm: number;
  cumNm: number;
  frequency: string;
}

export interface Ofp {
  fetchedAt: number;
  airac: string;
  callsign: string;
  aircraft: { icao: string; name: string; reg: string };
  origin: OfpAirport;
  destination: OfpAirport;
  alternates: OfpAirport[];
  route: string;
  distanceNm: number;
  cruiseFl: number;
  costIndex: string;
  times: { schedOut: number; schedOff: number; schedOn: number; schedIn: number; eteSec: number };
  fuel: { units: string; ramp: number; takeoff: number; landing: number; minTakeoff: number };
  navlog: OfpFix[];
  ofpHtml: string;
  pdfUrl: string | null;
}

type Raw = Record<string, any>;

const num = (v: unknown): number => {
  const n = Number.parseFloat(String(v ?? ''));
  return Number.isFinite(n) ? n : 0;
};
const str = (v: unknown): string => (typeof v === 'string' ? v : v == null || typeof v === 'object' ? '' : String(v));
const arr = <T>(v: T | T[] | undefined | null): T[] => (v == null ? [] : Array.isArray(v) ? v : [v]);

function airport(a: Raw | undefined): OfpAirport {
  return {
    icao: str(a?.icao_code),
    iata: str(a?.iata_code),
    name: str(a?.name),
    lat: num(a?.pos_lat),
    lon: num(a?.pos_long),
    elevFt: num(a?.elevation),
    planRwy: str(a?.plan_rwy),
    metar: str(a?.metar),
  };
}

export function normalizeOfp(raw: Raw): Ofp {
  const g = raw.general ?? {};
  let cum = 0;
  const navlog = arr<Raw>(raw.navlog?.fix).map((f) => {
    const leg = num(f.distance);
    cum += leg;
    return {
      ident: str(f.ident),
      name: str(f.name),
      type: str(f.type),
      lat: num(f.pos_lat),
      lon: num(f.pos_long),
      altFt: num(f.altitude_feet),
      airway: str(f.via_airway),
      stage: str(f.stage),
      isSidStar: str(f.is_sid_star) === '1',
      legNm: leg,
      cumNm: cum,
      frequency: str(f.frequency),
    };
  });

  const files = raw.files ?? {};
  const pdfLink = str(files.pdf?.link);
  return {
    fetchedAt: Date.now(),
    airac: str(raw.params?.airac),
    callsign: str(raw.atc?.callsign) || `${str(g.icao_airline)}${str(g.flight_number)}`,
    aircraft: { icao: str(raw.aircraft?.icaocode), name: str(raw.aircraft?.name), reg: str(raw.aircraft?.reg) },
    origin: airport(raw.origin),
    destination: airport(raw.destination),
    alternates: arr<Raw>(raw.alternate).map(airport).filter((a) => a.icao),
    route: str(g.route),
    distanceNm: num(g.route_distance) || num(g.gc_distance),
    cruiseFl: Math.round(num(g.initial_altitude) / 100),
    costIndex: str(g.costindex),
    times: {
      schedOut: num(raw.times?.sched_out),
      schedOff: num(raw.times?.sched_off),
      schedOn: num(raw.times?.sched_on),
      schedIn: num(raw.times?.sched_in),
      eteSec: num(raw.times?.est_time_enroute),
    },
    fuel: {
      units: str(raw.params?.units) || 'kgs',
      ramp: num(raw.fuel?.plan_ramp),
      takeoff: num(raw.fuel?.plan_takeoff),
      landing: num(raw.fuel?.plan_landing),
      minTakeoff: num(raw.fuel?.min_takeoff),
    },
    navlog,
    ofpHtml: str(raw.text?.plan_html),
    pdfUrl: pdfLink && str(files.directory) ? `${str(files.directory)}${pdfLink}` : null,
  };
}

export async function fetchOfp(user: string): Promise<Ofp> {
  const trimmed = user.trim();
  if (!trimmed) throw new HttpError(400, 'missing SimBrief username or pilot ID');
  const key = /^\d+$/.test(trimmed) ? 'userid' : 'username';
  const url = `https://www.simbrief.com/api/xml.fetcher.php?${key}=${encodeURIComponent(trimmed)}&json=1`;
  const res = await fetch(url, { signal: AbortSignal.timeout(20_000) });
  const body = (await res.json().catch(() => null)) as Raw | null;
  if (!res.ok || !body) {
    const msg = str(body?.fetch?.status) || `SimBrief HTTP ${res.status}`;
    throw new HttpError(res.status === 400 ? 404 : 502, msg);
  }
  if (str(body.fetch?.status) && str(body.fetch.status) !== 'Success') {
    throw new HttpError(404, str(body.fetch.status));
  }
  return normalizeOfp(body);
}
