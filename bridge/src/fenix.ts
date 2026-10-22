import type { LVars } from './lvars.js';

// Fenix A320 procedures that need several steps and a check from the sim after each one. Variable names come from
// the community HubHop presets (see ios/SimPilotEFB/Aircraft/FenixA320.swift).

export const XPDR_CODE = 'N_FREQ_XPDR_SELECTED';
export const XPDR_CHARS = 'N_PED_XPDR_CHAR_DISPLAYED';
const XPDR_CLR = 'S_PED_ATC_CLR';
const xpdrDigit = (d: number) => `S_PED_ATC_${d}`;
const rmpVar = (n: number, v: 'STDBY' | 'OUTER' | 'INNER') => (v === 'STDBY' ? `N_PED_RMP${n}_STDBY` : `E_PED_RMP${n}_${v}`);

const inc = (v: string) => `(L:${v}) ++ (>L:${v})`;
const dec = (v: string) => `(L:${v}) -- (>L:${v})`;
/** Fenix momentary buttons count presses: +1 on press, +1 on release (only if the count is odd). */
const pressCode = (v: string) => inc(v);
const releaseCode = (v: string) => `(L:${v}) 2 % 1 == if{ (L:${v}) ++ (>L:${v}) }`;

export interface FenixTiming {
  /** Time between press and release of a pushbutton. */
  holdMs: number;
  /** How long to wait for the sim to react to one key or knob click. */
  stepTimeoutMs: number;
  /** How long to wait for the final value. */
  verifyTimeoutMs: number;
}

const DEFAULT_TIMING: FenixTiming = { holdMs: 120, stepTimeoutMs: 800, verifyTimeoutMs: 3000 };

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const fmtCode = (v: number | undefined) => (v === undefined ? '----' : String(Math.round(v)).padStart(4, '0'));
const fmtFreq = (khz: number | undefined) => (khz === undefined ? '---.---' : (khz / 1000).toFixed(3));

export class FenixProcedures {
  private squawkBusy = false;
  private tuning = new Set<number>();
  private readonly t: FenixTiming;

  constructor(
    private readonly lv: LVars,
    timing: Partial<FenixTiming> = {},
  ) {
    this.t = { ...DEFAULT_TIMING, ...timing };
  }

  private async press(v: string): Promise<void> {
    await this.lv.run(pressCode(v));
    await sleep(this.t.holdMs);
    await this.lv.run(releaseCode(v));
  }

  /** Waits for a change of `name` from `before`; false if the sim didn't react in time. */
  private async changed(name: string, before: number | undefined, timeoutMs = this.t.stepTimeoutMs): Promise<boolean> {
    try {
      await this.lv.waitFor(name, (v) => v !== before, timeoutMs);
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Types a squawk on the ATC keypad: clears a half-typed entry first, waits for each key to register and checks the
   * code the transponder ends up with. One squawk entry at a time.
   */
  async setSquawk(code: string): Promise<string> {
    if (!/^[0-7]{4}$/.test(code)) throw new Error('A squawk is four digits from 0 to 7');
    if (this.squawkBusy) throw new Error('Already entering a squawk');
    this.squawkBusy = true;
    try {
      const target = Number(code);
      this.lv.watch([XPDR_CODE, XPDR_CHARS, XPDR_CLR, ...[0, 1, 2, 3, 4, 5, 6, 7].map(xpdrDigit)]);
      await this.lv.waitFor(XPDR_CODE, () => true, this.t.verifyTimeoutMs).catch(() => {
        throw new Error('No transponder data from the sim');
      });
      if (this.lv.value(XPDR_CODE) === target) return `Squawk ${code} already set`;

      // A partly typed code would swallow our first digits.
      const typed = this.lv.value(XPDR_CHARS) ?? 0;
      if (typed > 0) {
        await this.press(XPDR_CLR);
        await this.lv.waitFor(XPDR_CHARS, (v) => v === 0, this.t.stepTimeoutMs).catch(() => undefined);
      }
      for (const ch of code) {
        const before = this.lv.value(XPDR_CHARS);
        await this.press(xpdrDigit(Number(ch)));
        // Not every panel state reports progress; the final check decides.
        await this.changed(XPDR_CHARS, before);
      }
      try {
        await this.lv.waitFor(XPDR_CODE, (v) => v === target, this.t.verifyTimeoutMs);
      } catch {
        throw new Error(`Transponder shows ${fmtCode(this.lv.value(XPDR_CODE))}, not ${code}`);
      }
      return `Squawk ${code} set`;
    } finally {
      this.squawkBusy = false;
    }
  }

  /**
   * Turns an RMP's knobs until its standby window shows `khz` (e.g. 121800 for 121.800): whole MHz with the outer
   * knob, then the inner knob one click at a time, reading the window back after every click.
   */
  async tuneStandby(rmp: number, khz: number): Promise<string> {
    if (rmp !== 1 && rmp !== 2) throw new Error('Radio 1 or 2');
    if (!Number.isInteger(khz) || khz < 118000 || khz > 136990) throw new Error('VHF frequencies are 118.000 to 136.990');
    if (this.tuning.has(rmp)) throw new Error(`Radio ${rmp} is already being tuned`);
    this.tuning.add(rmp);
    const stby = rmpVar(rmp, 'STDBY');
    try {
      this.lv.watch([stby, rmpVar(rmp, 'OUTER'), rmpVar(rmp, 'INNER')]);
      await this.lv.waitFor(stby, (v) => v > 0, this.t.verifyTimeoutMs).catch(() => {
        throw new Error(`No data from radio ${rmp} (is it switched on?)`);
      });
      const target = `${fmtFreq(khz)}`;
      let current = this.lv.value(stby)!;
      if (current === khz) return `${target} already in standby`;

      // Whole MHz first.
      let mhzSteps = Math.floor(khz / 1000) - Math.floor(current / 1000);
      while (mhzSteps !== 0) {
        const before = this.lv.value(stby);
        await this.lv.run(mhzSteps > 0 ? inc(rmpVar(rmp, 'OUTER')) : dec(rmpVar(rmp, 'OUTER')));
        if (!(await this.changed(stby, before))) throw new Error(`Radio ${rmp} didn't react to the MHz knob`);
        mhzSteps -= Math.sign(mhzSteps);
      }

      // Then kHz, one channel at a time, until it matches. Give up if it keeps overshooting (channel not available).
      let lastDir = 0;
      let reversals = 0;
      for (let i = 0; i < 120; i++) {
        current = this.lv.value(stby)!;
        if (current === khz) return `${target} in standby`;
        const dir = khz > current ? 1 : -1;
        if (lastDir !== 0 && dir !== lastDir && ++reversals >= 2) {
          throw new Error(`Radio ${rmp} can't tune exactly ${target}; it stopped at ${fmtFreq(current)}`);
        }
        lastDir = dir;
        const before = current;
        await this.lv.run(dir > 0 ? inc(rmpVar(rmp, 'INNER')) : dec(rmpVar(rmp, 'INNER')));
        if (!(await this.changed(stby, before))) throw new Error(`Radio ${rmp} didn't react to the kHz knob`);
      }
      throw new Error(`Gave up tuning ${target} on radio ${rmp}`);
    } finally {
      this.tuning.delete(rmp);
    }
  }
}
