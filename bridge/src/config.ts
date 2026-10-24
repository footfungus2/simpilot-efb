import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/** True in the bundled Windows bridge (the packaging script defines it at bundle time). */
export const packaged = process.env.SIMPILOT_PACKAGED === '1';

const here = packaged ? '' : path.dirname(fileURLToPath(import.meta.url));

function envInt(name: string, fallback: number, max: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const n = /^\d+$/.test(raw) ? Number(raw) : NaN;
  if (!Number.isInteger(n) || n < 1 || n > max) throw new Error(`${name} must be an integer from 1 to ${max}`);
  return n;
}

export const config = {
  /** HTTP + WebSocket port shared by the iPad app and the in-sim link panel. */
  port: envInt('SIMPILOT_PORT', 8380, 65535),
  /**
   * Where chart images, indexes and OFPs are cached on disk. The packaged app keeps them in the user's local app
   * data, so it works from any folder (Downloads, Desktop, Program Files).
   */
  cacheDir: process.env.SIMPILOT_CACHE_DIR ??
    (packaged ? path.join(process.env.LOCALAPPDATA ?? os.homedir(), 'SimPilot Bridge', 'cache') : path.resolve(here, '..', 'cache')),
  /**
   * Remote SimConnect endpoint. Leave unset on the sim PC (auto-detected from the registry).
   * Set to e.g. `192.168.1.20:5111` to run the bridge on another machine during development.
   */
  simconnect: parseHostPort(process.env.SIMPILOT_SIMCONNECT),
  /** Ownship update rate pushed to the iPad. */
  ownshipHz: envInt('SIMPILOT_OWNSHIP_HZ', 10, 60),
  /** The link panel counts as disconnected after this long without a poll. */
  linkTimeoutMs: 6000,
  bridgeVersion: '0.1.4',
};

function parseHostPort(v: string | undefined): { host: string; port: number } | undefined {
  if (!v) return undefined;
  const match = /^([^:\s]+):(\d+)$/.exec(v);
  const host = match?.[1];
  const p = Number(match?.[2]);
  if (!host || !Number.isInteger(p) || p < 1 || p > 65535) {
    throw new Error('SIMPILOT_SIMCONNECT must look like host:port with a port from 1 to 65535');
  }
  return { host, port: p };
}
