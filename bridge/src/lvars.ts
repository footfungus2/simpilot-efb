import {
  DataRequestFlag,
  RawBuffer,
  SimConnectConstants,
  SimConnectDataType,
  SimConnectPeriod,
  type SimConnectConnection,
} from 'node-simconnect';
import { logger } from './log.js';
import { runRpn, rpnVars } from './rpn.js';

const log = logger('lvars');

export const DEF_LVARS = 10;
export const REQ_LVARS = 10;
const FIRST_WRITE_DEF = 100;
const READ_TIMEOUT_MS = 1500;
const BROADCAST_MS = 50;

/**
 * Aircraft local variables (L:vars) over SimConnect: the app asks to watch a set of names and gets
 * their values as they change; commands are MSFS RPN snippets (HubHop presets) run against them.
 */
export class LVars {
  private handle: SimConnectConnection | undefined;
  private watched = new Set<string>();
  private order: string[] = [];
  private values = new Map<string, number>();
  private writeDefs = new Map<string, number>();
  private pending: Record<string, number> = {};
  private flushTimer: NodeJS.Timeout | undefined;
  private rebuildTimer: NodeJS.Timeout | undefined;
  private waiters: (() => void)[] = [];
  private queue: Promise<void> = Promise.resolve();

  constructor(private readonly emit: (values: Record<string, number>) => void) {}

  attach(handle: SimConnectConnection): void {
    this.handle = handle;
    this.writeDefs.clear();
    this.values.clear();
    if (this.watched.size) this.scheduleRebuild();
  }

  detach(): void {
    this.handle = undefined;
  }

  /** Current values of these names that are already known. */
  snapshot(names: string[]): Record<string, number> {
    const out: Record<string, number> = {};
    for (const n of names) {
      const v = this.values.get(n);
      if (v !== undefined) out[n] = v;
    }
    return out;
  }

  watch(names: string[]): void {
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

  /** Runs a command; commands run one after another so a release sees the press's result. */
  run(code: string, param = 0): Promise<void> {
    this.queue = this.queue.then(() => this.runNow(code, param)).catch((err) => {
      log.warn(`command failed: ${(err as Error).message} — ${code}`);
    });
    return this.queue;
  }

  private async runNow(code: string, param: number): Promise<void> {
    if (!this.handle) throw new Error('sim not connected');
    const { reads, writes } = rpnVars(code);
    this.watch([...reads, ...writes]);
    await this.whenKnown(reads);
    runRpn(code, { read: (n) => this.values.get(n) ?? 0, write: (n, v) => this.set(n, v) }, param);
  }

  private set(name: string, value: number): void {
    const handle = this.handle;
    if (!handle) return;
    let def = this.writeDefs.get(name);
    if (def === undefined) {
      def = FIRST_WRITE_DEF + this.writeDefs.size;
      this.writeDefs.set(name, def);
      handle.addToDataDefinition(def, `L:${name}`, 'number', SimConnectDataType.FLOAT64);
    }
    const buffer = new RawBuffer(8);
    buffer.writeFloat64(value);
    handle.setDataOnSimObject(def, SimConnectConstants.OBJECT_ID_USER, { buffer, arrayCount: 0, tagged: false });
    // Optimistic: the next command reads the new value even before the sim echoes it.
    this.store(name, value);
  }

  /** Data for REQ_LVARS: values in watch order. */
  onData(data: RawBuffer): void {
    for (const name of this.order) this.store(name, data.readFloat64());
    const ws = this.waiters.splice(0);
    for (const w of ws) w();
  }

  private store(name: string, value: number): void {
    if (this.values.get(name) === value) return;
    this.values.set(name, value);
    this.pending[name] = value;
    this.flushTimer ??= setTimeout(() => {
      this.flushTimer = undefined;
      const out = this.pending;
      this.pending = {};
      this.emit(out);
    }, BROADCAST_MS);
  }

  private whenKnown(names: string[]): Promise<void> {
    if (names.every((n) => this.values.has(n))) return Promise.resolve();
    return new Promise((resolve) => {
      const timer = setTimeout(resolve, READ_TIMEOUT_MS);
      const check = () => {
        if (names.every((n) => this.values.has(n))) {
          clearTimeout(timer);
          resolve();
        } else this.waiters.push(check);
      };
      this.waiters.push(check);
    });
  }

  private scheduleRebuild(): void {
    clearTimeout(this.rebuildTimer);
    this.rebuildTimer = setTimeout(() => this.rebuild(), 30);
  }

  /** One data definition with every watched variable, sent whenever any of them changes. */
  private rebuild(): void {
    const handle = this.handle;
    if (!handle) return;
    this.order = [...this.watched];
    handle.clearDataDefinition(DEF_LVARS);
    for (const name of this.order) {
      handle.addToDataDefinition(DEF_LVARS, `L:${name}`, 'number', SimConnectDataType.FLOAT64);
    }
    handle.requestDataOnSimObject(
      REQ_LVARS,
      DEF_LVARS,
      SimConnectConstants.OBJECT_ID_USER,
      SimConnectPeriod.VISUAL_FRAME,
      DataRequestFlag.DATA_REQUEST_FLAG_CHANGED,
    );
    log.debug(`watching ${this.order.length} L:vars`);
  }
}
