import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

function envInt(name: string, fallback: number): number {
  const raw = process.env[name];
  const n = raw ? Number.parseInt(raw, 10) : NaN;
  return Number.isFinite(n) ? n : fallback;
}

export const config = {
  /** HTTP + WebSocket port shared by the iPad app and the in-sim link panel. */
  port: envInt('SIMPILOT_PORT', 8380),
  /** Where chart images, indexes and OFPs are cached on disk. */
  cacheDir: process.env.SIMPILOT_CACHE_DIR ?? path.resolve(here, '..', 'cache'),
  /**
   * Remote SimConnect endpoint. Leave unset on the sim PC (auto-detected from the registry).
   * Set to e.g. `192.168.1.20:5111` to run the bridge on another machine during development.
   */
  simconnect: parseHostPort(process.env.SIMPILOT_SIMCONNECT),
  /** Ownship update rate pushed to the iPad. */
  ownshipHz: envInt('SIMPILOT_OWNSHIP_HZ', 10),
  /** The link panel counts as disconnected after this long without a poll. */
  linkTimeoutMs: 6000,
  bridgeVersion: '0.1.0',
};

function parseHostPort(v: string | undefined): { host: string; port: number } | undefined {
  if (!v) return undefined;
  const [host, port] = v.split(':');
  const p = Number.parseInt(port ?? '', 10);
  if (!host || !Number.isFinite(p)) {
    throw new Error(`SIMPILOT_SIMCONNECT must look like host:port, got "${v}"`);
  }
  return { host, port: p };
}
