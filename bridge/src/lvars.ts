import {
  DataRequestFlag,
  RawBuffer,
  SimConnectConstants,
  SimConnectDataType,
  SimConnectPeriod,
} from 'node-simconnect';
import { logger } from './log.js';
import { runRpn, rpnVars } from './rpn.js';

const log = logger('lvars');

export const DEF_LVARS = 10;
export const REQ_LVARS = 10;
const FIRST_WRITE_DEF = 100;
const READ_TIMEOUT_MS = 1500;
const BROADCAST_MS = 50;

/** The part of a SimConnect connection the L:var service uses (a fake implements it in tests). */
export interface SimPort {
  addToDataDefinition(def: number, name: string, unit: string | null, type?: SimConnectDataType): number;
  clearDataDefinition(def: number): number;
  requestDataOnSimObject(req: number, def: number, obj: number, period: SimConnectPeriod, flags?: DataRequestFlag): number;
  setDataOnSimObject(def: number, obj: number, data: { buffer: RawBuffer; arrayCount: number; tagged: boolean }): number;
}

/**
 * Aircraft local variables (L:vars) over SimConnect. The app asks to watch names and receives their values as the
 * **sim** reports them (never our own writes), so a value on the iPad is always a readback. Commands are MSFS RPN
 * snippets (HubHop presets); they run strictly one after another.
 */
export class LVars {
  private port: SimPort | undefined;
  private watched = new Set<string>();
  private order: string[] = [];
  /** Values RPN reads from: sim readbacks plus our own writes since. */
  private working = new Map<string, number>();
  /** Values as last reported by the sim. */
  private sim = new Map<string, number>();
  private writeDefs = new Map<string, number>();
  private pending: Record<string, number> = {};
  private flushTimer: NodeJS.Timeout | undefined;
  private rebuildTimer: NodeJS.Timeout | undefined;
  private listeners = new Set<() => void>();
  private queue: Promise<unknown> = Promise.resolve();
  private generation = 0;
  private queued = 0;

  constructor(
    private readonly emit: (values: Record<string, number>) => void,
    private readonly readTimeoutMs = READ_TIMEOUT_MS,
  ) {}

  get connected(): boolean {
    return this.port !== undefined;
  }

  get session(): number {
    return this.generation;
  }

  attach(port: SimPort): void {
    if (this.port === port) {
      for (const def of this.writeDefs.values()) port.clearDataDefinition(def);
    }
    this.detach();
    this.port = port;
    this.writeDefs.clear();
    this.working.clear();
    this.sim.clear();
    if (this.watched.size) this.scheduleRebuild();
  }

  detach(): void {
    this.generation++;
    this.port = undefined;
    this.working.clear();
    this.sim.clear();
    this.pending = {};
    this.order = [];
    clearTimeout(this.flushTimer);
    clearTimeout(this.rebuildTimer);
    this.flushTimer = undefined;
    for (const listener of [...this.listeners]) listener();
  }

  /** Last value the sim reported. */
  value(name: string): number | undefined {
    return this.sim.get(name);
  }

  /** Current values of these names that the sim has reported. */
  snapshot(names: string[]): Record<string, number> {
    const out: Record<string, number> = {};
    for (const n of names) {
      const v = this.sim.get(n);
      if (v !== undefined) out[n] = v;
    }
    return out;
  }

  watch(names: string[]): void {
    if (names.some((n) => typeof n !== 'string' || !/^[A-Za-z0-9_:.-]{1,128}$/.test(n))) throw new Error('Invalid L:var name');
    if (new Set([...this.watched, ...names]).size > 512) throw new Error('Too many watched L:vars');
    let added = false;
    for (const raw of names) {
      const n = raw.trim();
      if (n && !this.watched.has(n)) {
        this.watched.add(n);
        added = true;
      }
    }
    if (added) this.scheduleRebuild();
  }

  /** Runs a command after the ones before it. Resolves with the variables written; rejects if it couldn't run. */
  run(code: string, param = 0): Promise<string[]> {
    if (this.queued >= 256) return Promise.reject(new Error('Too many queued commands'));
    const generation = this.generation;
    this.queued++;
    const result = this.queue.then(() => this.runNow(code, param, generation)).finally(() => this.queued--);
    this.queue = result.catch(() => undefined);
    return result;
  }

  private async runNow(code: string, param: number, generation: number): Promise<string[]> {
    if (!this.port || generation !== this.generation) throw new Error('sim not connected or session changed');
    if (code.length > 4096 || !Number.isFinite(param)) throw new Error('Invalid RPN command');
    const { reads, writes } = rpnVars(code);
    this.watch([...reads, ...writes]);
    await this.whenKnown(reads);
    if (!this.port || generation !== this.generation) throw new Error('sim session changed');
    runRpn(code, { read: (n) => this.working.get(n)!, write: (n, v) => this.set(n, v) }, param);
    return writes;
  }

  private set(name: string, value: number): void {
    const port = this.port;
    if (!port) throw new Error('sim not connected');
    let def = this.writeDefs.get(name);
    if (def === undefined) {
      def = FIRST_WRITE_DEF + this.writeDefs.size;
      this.writeDefs.set(name, def);
      port.addToDataDefinition(def, `L:${name}`, 'number', SimConnectDataType.FLOAT64);
    }
    const buffer = new RawBuffer(8);
    buffer.writeFloat64(value);
    port.setDataOnSimObject(def, SimConnectConstants.OBJECT_ID_USER, { buffer, arrayCount: 0, tagged: false });
    // Later commands in this batch read the new value; the app only hears about it once the sim confirms it.
    this.working.set(name, value);
  }

  /** Data for REQ_LVARS: values in watch order. */
  onData(data: RawBuffer): void {
    if (!this.port || data.remaining() < this.order.length * 8) return;
    for (const name of this.order) {
      const v = data.readFloat64();
      if (!Number.isFinite(v)) continue;
      this.working.set(name, v);
      if (this.sim.get(name) !== v) {
        this.sim.set(name, v);
        this.pending[name] = v;
      }
    }
    this.flushTimer ??= setTimeout(() => {
      this.flushTimer = undefined;
      const out = this.pending;
      this.pending = {};
      if (Object.keys(out).length) this.emit(out);
    }, BROADCAST_MS);
    for (const l of [...this.listeners]) l();
  }

  /** Resolves with the sim's value once `test` passes; rejects after `timeoutMs`. */
  waitFor(name: string, test: (v: number) => boolean, timeoutMs: number): Promise<number> {
    if (!this.port) return Promise.reject(new Error('sim not connected'));
    const generation = this.generation;
    this.watch([name]);
    const now = this.sim.get(name);
    if (now !== undefined && test(now)) return Promise.resolve(now);
    return new Promise((resolve, reject) => {
      const done = () => {
        clearTimeout(timer);
        this.listeners.delete(check);
      };
      const check = () => {
        if (!this.port || generation !== this.generation) {
          done();
          reject(new Error('sim session changed'));
          return;
        }
        const v = this.sim.get(name);
        if (v !== undefined && test(v)) {
          done();
          resolve(v);
        }
      };
      const timer = setTimeout(() => {
        done();
        reject(new Error(`no readback for ${name}`));
      }, timeoutMs);
      this.listeners.add(check);
    });
  }

  private whenKnown(names: string[]): Promise<void> {
    const generation = this.generation;
    if (names.every((n) => this.working.has(n))) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const done = () => {
        clearTimeout(timer);
        this.listeners.delete(check);
      };
      const check = () => {
        if (!this.port || generation !== this.generation) {
          done();
          reject(new Error('sim session changed'));
        } else if (names.every((n) => this.working.has(n))) {
          done();
          resolve();
        }
      };
      const timer = setTimeout(() => {
        done();
        reject(new Error('No aircraft data for command'));
      }, this.readTimeoutMs);
      this.listeners.add(check);
    });
  }

  private scheduleRebuild(): void {
    clearTimeout(this.rebuildTimer);
    this.rebuildTimer = setTimeout(() => this.rebuild(), 30);
  }

  /** One data definition with every watched variable, sent whenever any of them changes. */
  private rebuild(): void {
    const port = this.port;
    if (!port) return;
    this.order = [...this.watched];
    port.clearDataDefinition(DEF_LVARS);
    for (const name of this.order) {
      port.addToDataDefinition(DEF_LVARS, `L:${name}`, 'number', SimConnectDataType.FLOAT64);
    }
    port.requestDataOnSimObject(
      REQ_LVARS,
      DEF_LVARS,
      SimConnectConstants.OBJECT_ID_USER,
      SimConnectPeriod.VISUAL_FRAME,
      DataRequestFlag.DATA_REQUEST_FLAG_CHANGED,
    );
    log.debug(`watching ${this.order.length} L:vars`);
  }
}
