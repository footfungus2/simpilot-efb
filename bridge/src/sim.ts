import {
  open,
  Protocol,
  SimConnectConstants,
  SimConnectDataType,
  SimConnectPeriod,
  type SimConnectConnection,
} from 'node-simconnect';
import { config } from './config.js';
import type { Hub } from './hub.js';
import { REQ_LVARS, type LVars } from './lvars.js';
import { logger } from './log.js';

const log = logger('sim');

const DEF_OWNSHIP = 1;
const DEF_TITLE = 2;
const REQ_OWNSHIP = 1;
const REQ_TITLE = 2;
const EVT_AIRCRAFT_LOADED = 1;

const RETRY_MS = 5000;

/** Keeps a SimConnect connection alive and publishes ownship state to the hub. */
export function startSim(hub: Hub, lvars: LVars): void {
  let lastSent = 0;
  const minIntervalMs = 1000 / config.ownshipHz;

  const connect = async (): Promise<void> => {
    let handle: SimConnectConnection;
    try {
      const options = config.simconnect ? { remote: config.simconnect } : undefined;
      const res = await open('SimPilot EFB Bridge', Protocol.KittyHawk, options);
      handle = res.handle;
      log.info(`connected to ${res.recvOpen.applicationName}`);
    } catch (err) {
      log.debug(`SimConnect not available (${(err as Error).message}); retrying in ${RETRY_MS / 1000}s`);
      setTimeout(connect, RETRY_MS);
      return;
    }

    hub.setSim(true);
    lvars.attach(handle);

    // Order matters: values are read back in the same order.
    const vars: [string, string][] = [
      ['PLANE LATITUDE', 'degrees'],
      ['PLANE LONGITUDE', 'degrees'],
      ['PLANE ALTITUDE', 'feet'],
      ['GROUND VELOCITY', 'knots'],
      ['GPS GROUND TRUE TRACK', 'degrees'],
      ['PLANE HEADING DEGREES TRUE', 'degrees'],
      ['VERTICAL SPEED', 'feet per minute'],
      ['SIM ON GROUND', 'bool'],
      ['MAGVAR', 'degrees'],
    ];
    for (const [name, unit] of vars) {
      handle.addToDataDefinition(DEF_OWNSHIP, name, unit, SimConnectDataType.FLOAT64);
    }
    handle.addToDataDefinition(DEF_TITLE, 'TITLE', null, SimConnectDataType.STRING256);

    handle.requestDataOnSimObject(REQ_OWNSHIP, DEF_OWNSHIP, SimConnectConstants.OBJECT_ID_USER, SimConnectPeriod.VISUAL_FRAME);
    const requestTitle = () =>
      handle.requestDataOnSimObject(REQ_TITLE, DEF_TITLE, SimConnectConstants.OBJECT_ID_USER, SimConnectPeriod.ONCE);
    requestTitle();
    handle.subscribeToSystemEvent(EVT_AIRCRAFT_LOADED, 'AircraftLoaded');

    handle.on('event', (ev) => {
      if (ev.clientEventId === EVT_AIRCRAFT_LOADED) requestTitle();
    });

    handle.on('simObjectData', (rx) => {
      if (rx.requestID === REQ_LVARS) {
        lvars.onData(rx.data);
        return;
      }
      if (rx.requestID === REQ_TITLE) {
        const title = rx.data.readString256();
        log.info(`aircraft: ${title}`);
        hub.setSim(true, title);
        return;
      }
      if (rx.requestID !== REQ_OWNSHIP) return;

      const now = Date.now();
      if (now - lastSent < minIntervalMs) return;
      lastSent = now;

      const d = rx.data;
      const lat = d.readFloat64();
      const lon = d.readFloat64();
      const altFt = d.readFloat64();
      const gsKt = d.readFloat64();
      const gpsTrk = d.readFloat64();
      const hdgDeg = d.readFloat64();
      const vsFpm = d.readFloat64();
      const onGround = d.readFloat64() !== 0;
      const magVarDeg = d.readFloat64();
      hub.ownship({
        lat,
        lon,
        altFt,
        gsKt,
        // GPS track is noise when stationary; fall back to heading.
        trkDeg: gsKt < 5 ? hdgDeg : gpsTrk,
        hdgDeg,
        vsFpm,
        onGround,
        magVarDeg,
        ts: now,
      });
    });

    handle.on('exception', (ex) => log.warn(`SimConnect exception ${ex.exception} (packet ${ex.sendId})`));

    let gone = false;
    const lost = (why: string) => {
      // 'quit' is usually followed by 'close'; only schedule one reconnect.
      if (gone) return;
      gone = true;
      lvars.detach();
      log.warn(`SimConnect ${why}; reconnecting in ${RETRY_MS / 1000}s`);
      hub.setSim(false);
      setTimeout(connect, RETRY_MS);
    };
    handle.once('quit', () => lost('quit'));
    handle.once('close', () => lost('closed'));
  };

  void connect();
}
