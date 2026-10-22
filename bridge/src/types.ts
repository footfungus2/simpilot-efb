// Wire types shared with the iPad app. Keep in sync with shared/protocol.md and ios/SimPilotEFB/Models.

export interface Ownship {
  lat: number;
  lon: number;
  altFt: number;
  gsKt: number;
  trkDeg: number;
  hdgDeg: number;
  vsFpm: number;
  onGround: boolean;
  magVarDeg: number;
  ts: number;
}

export interface BridgeStatus {
  sim: { connected: boolean; aircraftTitle?: string };
  link: { connected: boolean; lastSeenMs?: number };
}

export interface Rect {
  upperLeft: [number, number];
  lowerRight: [number, number];
  orientation: number;
}

export interface ChartArea {
  layer: string;
  geoReferenced: boolean;
  chartRect: Rect;
  worldRect?: Rect;
  projection?: { standardParallel1: number; standardParallel2: number; centralMeridian: number };
}

export interface ChartMeta {
  guid: string;
  type: string;
  name: string;
  runways: string[];
  procedures: string[];
  geoReferenced: boolean;
  pageCount?: number;
  validFrom: number | null;
  validUntil: number | null;
}

export interface ChartIndex {
  icao: string;
  provider: string;
  fetchedAt: number;
  categories: { name: string; charts: ChartMeta[] }[];
}

export interface ChartPage {
  index: number;
  width: number;
  height: number;
  geoReferenced: boolean;
  areas: ChartArea[];
  /** Relative URL of the cached PNG, or null if the image hasn't been fetched (yet). */
  image: string | null;
}

export type BridgeToApp =
  | { t: 'hello'; v: 1; bridgeVersion: string; status: BridgeStatus }
  | ({ t: 'status' } & BridgeStatus)
  | ({ t: 'ownship' } & Ownship)
  | { t: 'chartsReady'; icao: string }
  | { t: 'chartsProgress'; icao: string; done: number; total: number }
  | { t: 'chartsError'; icao: string; message: string }
  | { t: 'lvars'; values: Record<string, number> }
  /** Outcome of an app command that carried an `id`. */
  | { t: 'commandResult'; id: string; ok: boolean; message?: string };

export type AppToBridge =
  | { t: 'requestCharts'; icao: string }
  /** Start sending these aircraft L:vars (names without "L:") as they change. */
  | { t: 'lvarWatch'; names: string[] }
  /** Run an MSFS RPN snippet against the aircraft's L:vars; `@` in the code is `value`. */
  | { t: 'lvarRun'; code: string; value?: number; id?: string }
  /** Fenix: type a squawk on the ATC keypad and check the result. */
  | { t: 'fenixSquawk'; code: string; id?: string }
  /** Fenix: turn an RMP's knobs until standby shows `khz` (121800 = 121.800). */
  | { t: 'fenixTune'; rmp: number; khz: number; id?: string };
