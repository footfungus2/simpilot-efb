import { RawBuffer, SimConnectDataType, SimObjectType } from 'node-simconnect';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { DEF_TRAFFIC, REQ_TRAFFIC, Traffic, type TrafficPort } from '../src/traffic.js';
import type { BridgeToApp } from '../src/types.js';

class FakePort implements TrafficPort {
  defs: { name: string; type?: SimConnectDataType }[] = [];
  requests: { radius: number; type: SimObjectType }[] = [];
  addToDataDefinition(_def: number, name: string, _unit: string | null, type?: SimConnectDataType): number {
    this.defs.push({ name, type });
    return 0;
  }
  requestDataOnSimObjectType(_req: number, _def: number, radius: number, type: SimObjectType): number {
    this.requests.push({ radius, type });
    return 0;
  }
}

/** One aircraft as the sim answers it, laid out the way Traffic.attach defines it. */
function aircraft(o: { title?: string; tail?: string; airline?: string; flight?: string; lat: number; lon: number; alt?: number; hdg?: number; gs?: number; ground?: boolean }): RawBuffer {
  const b = new RawBuffer(0);
  b.writeString256(o.title ?? 'Airbus A320neo');
  b.writeString32(o.tail ?? '');
  b.writeString64(o.airline ?? '');
  b.writeString8(o.flight ?? '');
  for (const v of [o.lat, o.lon, o.alt ?? 3000, o.hdg ?? 90, o.gs ?? 250, o.ground ? 1 : 0]) b.writeFloat64(v);
  return new RawBuffer(b.getBuffer());
}

describe('traffic feed', () => {
  let sent: BridgeToApp[];
  let clients: number;
  let traffic: Traffic;
  let port: FakePort;
  const hub = { broadcast: (m: BridgeToApp) => void sent.push(m), clientCount: () => clients };

  beforeEach(() => {
    vi.useFakeTimers();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    sent = [];
    clients = 1;
    traffic = new Traffic(hub);
    port = new FakePort();
    traffic.attach(port);
  });
  afterEach(() => {
    traffic.detach();
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it('asks the sim only while the app wants traffic', () => {
    vi.advanceTimersByTime(10_000);
    expect(port.requests).toHaveLength(0);
    traffic.watch(true);
    expect(port.requests).toHaveLength(1);
    expect(port.requests[0]).toEqual({ radius: 150_000, type: SimObjectType.AIRCRAFT });
    vi.advanceTimersByTime(6_000);
    expect(port.requests.length).toBeGreaterThanOrEqual(3);
    const asked = port.requests.length;
    traffic.watch(false);
    vi.advanceTimersByTime(10_000);
    expect(port.requests).toHaveLength(asked);
    expect(sent.at(-1)).toEqual({ t: 'traffic', aircraft: [] }); // the iPad clears its symbols
  });

  it('stops asking once no app is connected', () => {
    traffic.watch(true);
    clients = 0;
    vi.advanceTimersByTime(3_500);
    const asked = port.requests.length;
    vi.advanceTimersByTime(20_000);
    expect(port.requests).toHaveLength(asked);
  });

  it('collects a whole answer and publishes it once, with the airline callsign when there is one', () => {
    traffic.setUser(1, 51.9, 0.2);
    traffic.onData({ objectID: 7, entryNumber: 1, outOf: 3, data: aircraft({ airline: 'EASY', flight: '1234', lat: 51.5, lon: 0.1, alt: 4500.4, hdg: 271.6, gs: 220.2 }) });
    traffic.onData({ objectID: 8, entryNumber: 2, outOf: 3, data: aircraft({ tail: 'G-ABCD', lat: 52, lon: 0.3, ground: true, gs: 0 }) });
    expect(sent).toEqual([]);
    traffic.onData({ objectID: 9, entryNumber: 3, outOf: 3, data: aircraft({ lat: 53, lon: 1 }) });
    expect(sent).toHaveLength(1);
    const list = (sent[0] as Extract<BridgeToApp, { t: 'traffic' }>).aircraft;
    expect(list.map((a) => a.callsign)).toEqual(['EASY 1234', 'G-ABCD', '']);
    expect(list[0]).toMatchObject({ id: 7, lat: 51.5, lon: 0.1, altFt: 4500, hdgDeg: 272, gsKt: 220, onGround: false });
    expect(list[1]!.onGround).toBe(true);
  });

  it('leaves out the user aircraft, by object id or by position', () => {
    traffic.setUser(1, 51.9, 0.2);
    traffic.onData({ objectID: 1, entryNumber: 1, outOf: 3, data: aircraft({ lat: 10, lon: 10 }) });
    traffic.onData({ objectID: 5, entryNumber: 2, outOf: 3, data: aircraft({ lat: 51.9001, lon: 0.2001 }) });
    traffic.onData({ objectID: 6, entryNumber: 3, outOf: 3, data: aircraft({ lat: 51.7, lon: 0.2 }) });
    expect((sent[0] as Extract<BridgeToApp, { t: 'traffic' }>).aircraft.map((a) => a.id)).toEqual([6]);
  });

  it('publishes an empty list when the sim finds nothing, and drops nonsense positions', () => {
    traffic.onData({ objectID: 0, entryNumber: 0, outOf: 0, data: new RawBuffer(0) });
    expect(sent.at(-1)).toEqual({ t: 'traffic', aircraft: [] });
    traffic.onData({ objectID: 3, entryNumber: 1, outOf: 1, data: aircraft({ lat: 123, lon: 0 }) });
    expect((sent.at(-1) as Extract<BridgeToApp, { t: 'traffic' }>).aircraft).toEqual([]);
  });

  it('defines the data the reader expects, in order', () => {
    expect(port.defs.map((d) => d.name)).toEqual(['TITLE', 'ATC ID', 'ATC AIRLINE', 'ATC FLIGHT NUMBER', 'PLANE LATITUDE', 'PLANE LONGITUDE', 'PLANE ALTITUDE', 'PLANE HEADING DEGREES TRUE', 'GROUND VELOCITY', 'SIM ON GROUND']);
    expect(DEF_TRAFFIC).toBe(REQ_TRAFFIC);
  });
});
