import { SimConnectDataType, SimObjectType, type RawBuffer } from 'node-simconnect';
import type { Hub } from './hub.js';
import { logger } from './log.js';
import type { TrafficAircraft } from './types.js';

const log = logger('traffic');

export const DEF_TRAFFIC = 20;
export const REQ_TRAFFIC = 20;
/** How often the sim is asked for the aircraft around the user, and how far around (metres, ~80 NM). */
const POLL_MS = 3000;
const RADIUS_M = 150_000;
const MAX_AIRCRAFT = 400;

/** The part of a SimConnect connection the traffic service uses (a fake implements it in tests). */
export interface TrafficPort {
  addToDataDefinition(def: number, name: string, unit: string | null, type?: SimConnectDataType): number;
  requestDataOnSimObjectType(req: number, def: number, radiusMeters: number, type: SimObjectType): number;
}

/** One answer of the sim's by-type request (one aircraft of `outOf`). */
export interface TrafficEntry {
  objectID: number;
  entryNumber: number;
  outOf: number;
  data: RawBuffer;
}

/**
 * AI and multiplayer aircraft around the user, for the iPad's traffic layer. The sim is only asked while the app
 * has turned the layer on (and at least one app is connected), because the list can be long.
 */
export class Traffic {
  private port: TrafficPort | undefined;
  private wanted = false;
  private timer: NodeJS.Timeout | undefined;
  private userObject: number | undefined;
  private user: { lat: number; lon: number } | undefined;
  private batch: TrafficAircraft[] = [];

  constructor(private readonly hub: Pick<Hub, 'broadcast' | 'clientCount'>) {}

  attach(port: TrafficPort): void {
    this.detach();
    this.port = port;
    // Order matters: the values are read back in this order (see read()).
    const defs: [string, string | null, SimConnectDataType][] = [
      ['TITLE', null, SimConnectDataType.STRING256],
      ['ATC ID', null, SimConnectDataType.STRING32],
      ['ATC AIRLINE', null, SimConnectDataType.STRING64],
      ['ATC FLIGHT NUMBER', null, SimConnectDataType.STRING8],
      ['PLANE LATITUDE', 'degrees', SimConnectDataType.FLOAT64],
      ['PLANE LONGITUDE', 'degrees', SimConnectDataType.FLOAT64],
      ['PLANE ALTITUDE', 'feet', SimConnectDataType.FLOAT64],
      ['PLANE HEADING DEGREES TRUE', 'degrees', SimConnectDataType.FLOAT64],
      ['GROUND VELOCITY', 'knots', SimConnectDataType.FLOAT64],
      ['SIM ON GROUND', 'bool', SimConnectDataType.FLOAT64],
    ];
    for (const [name, unit, type] of defs) port.addToDataDefinition(DEF_TRAFFIC, name, unit, type);
    if (this.wanted) this.start();
  }

  detach(): void {
    this.stop();
    this.port = undefined;
    this.batch = [];
  }

  /** The app turned the traffic layer on or off. */
  watch(on: boolean): void {
    this.wanted = on;
    if (on) this.start();
    else {
      this.stop();
      this.hub.broadcast({ t: 'traffic', aircraft: [] });
    }
  }

  /** The user's own aircraft is part of the sim's answer; it is left out by object id or, failing that, by position. */
  setUser(objectID: number, lat: number, lon: number): void {
    this.userObject = objectID;
    this.user = { lat, lon };
  }

  onData(entry: TrafficEntry): void {
    if (entry.entryNumber <= 1) this.batch = [];
    if (entry.outOf > 0 && entry.objectID !== this.userObject) {
      const aircraft = this.read(entry.objectID, entry.data);
      if (aircraft && !this.isUser(aircraft) && this.batch.length < MAX_AIRCRAFT) this.batch.push(aircraft);
    }
    if (entry.outOf === 0 || entry.entryNumber >= entry.outOf) {
      this.hub.broadcast({ t: 'traffic', aircraft: this.batch });
      this.batch = [];
    }
  }

  private read(id: number, d: RawBuffer): TrafficAircraft | undefined {
    const title = d.readString256();
    const tail = d.readString32().trim();
    const airline = d.readString64().trim();
    const flight = d.readString8().trim();
    const lat = d.readFloat64();
    const lon = d.readFloat64();
    const altFt = d.readFloat64();
    const hdgDeg = d.readFloat64();
    const gsKt = d.readFloat64();
    const onGround = d.readFloat64() !== 0;
    if (![lat, lon, altFt, hdgDeg, gsKt].every(Number.isFinite) || Math.abs(lat) > 90 || Math.abs(lon) > 180) return undefined;
    // AI airliners carry airline + flight number; multiplayer and others only a tail number.
    const callsign = airline && flight ? `${airline} ${flight}` : tail;
    return { id, callsign, type: title, lat, lon, altFt: Math.round(altFt), hdgDeg: Math.round(hdgDeg), gsKt: Math.round(gsKt), onGround };
  }

  private isUser(a: TrafficAircraft): boolean {
    if (!this.user) return false;
    return Math.abs(a.lat - this.user.lat) < 0.0003 && Math.abs(a.lon - this.user.lon) < 0.0003;
  }

  private start(): void {
    if (!this.port || this.timer) return;
    const ask = () => {
      if (this.hub.clientCount() === 0) {
        // Nobody is listening any more (the app closed): stop asking until it asks again.
        this.wanted = false;
        this.stop();
        return;
      }
      try {
        this.port?.requestDataOnSimObjectType(REQ_TRAFFIC, DEF_TRAFFIC, RADIUS_M, SimObjectType.AIRCRAFT);
      } catch (err) {
        log.warn('traffic request failed', err);
      }
    };
    ask();
    this.timer = setInterval(ask, POLL_MS);
    this.timer.unref();
  }

  private stop(): void {
    clearInterval(this.timer);
    this.timer = undefined;
  }
}
