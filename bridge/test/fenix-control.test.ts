import { RawBuffer } from 'node-simconnect';
import { describe, expect, it } from 'vitest';
import { FenixProcedures, XPDR_CHARS, XPDR_CODE } from '../src/fenix.js';
import { DEF_LVARS, LVars, type SimPort } from '../src/lvars.js';

/**
 * A stand-in for the sim with a little Fenix behaviour: L:var writes land in `state`, the ATC keypad builds a code
 * from counter-style key presses, and the RMP knobs move the standby frequency. After each write it reports the
 * watched variables back like SimConnect's "changed" data request.
 */
class FakeFenix implements SimPort {
  state = new Map<string, number>();
  writes: [string, number][] = [];
  ignore = new Set<string>(); // variables whose writes the "sim" drops
  latencyMs = 5;
  keypadWorks = true;
  innerStepKhz = 25;
  private defs = new Map<number, string[]>();
  private lvars?: LVars;

  connect(lv: LVars): this {
    this.lvars = lv;
    lv.attach(this);
    return this;
  }

  addToDataDefinition(def: number, name: string): number {
    this.defs.set(def, [...(this.defs.get(def) ?? []), name.replace(/^L:/, '')]);
    return 0;
  }

  clearDataDefinition(def: number): number {
    this.defs.delete(def);
    return 0;
  }

  requestDataOnSimObject(): number {
    this.report();
    return 0;
  }

  setDataOnSimObject(def: number, _obj: number, data: { buffer: RawBuffer }): number {
    const name = this.defs.get(def)![0]!;
    const value = data.buffer.getBuffer().readDoubleLE(0);
    this.writes.push([name, value]);
    if (!this.ignore.has(name)) this.apply(name, value);
    this.report();
    return 0;
  }

  private entry = '';

  private apply(name: string, value: number): void {
    const before = this.state.get(name) ?? 0;
    this.state.set(name, value);
    const key = /^S_PED_ATC_(\d|CLR)$/.exec(name);
    // A key "click" completes when the counter becomes even again.
    if (key && this.keypadWorks && value % 2 === 0 && value > before) {
      if (key[1] === 'CLR') this.entry = '';
      else {
        this.entry += key[1];
        if (this.entry.length === 4) {
          this.state.set(XPDR_CODE, Number(this.entry));
          this.entry = '';
        }
      }
      this.state.set(XPDR_CHARS, this.entry.length);
    }
    const knob = /^E_PED_RMP(\d)_(OUTER|INNER)$/.exec(name);
    if (knob) {
      const stby = `N_PED_RMP${knob[1]}_STDBY`;
      const cur = this.state.get(stby) ?? 0;
      const dir = Math.sign(value - before);
      if (knob[2] === 'OUTER') this.state.set(stby, cur + dir * 1000);
      else {
        // kHz wraps inside the MHz, like the real RMP.
        const mhz = Math.floor(cur / 1000) * 1000;
        const khz = (((cur - mhz + dir * this.innerStepKhz) % 1000) + 1000) % 1000;
        this.state.set(stby, mhz + khz);
      }
    }
  }

  private report(): void {
    const names = this.defs.get(DEF_LVARS);
    if (!names || !this.lvars) return;
    const buf = Buffer.alloc(names.length * 8);
    names.forEach((n, i) => buf.writeDoubleLE(this.state.get(n) ?? 0, i * 8));
    const lv = this.lvars;
    setTimeout(() => lv.onData(new RawBuffer(buf)), this.latencyMs);
  }
}

const fast = { holdMs: 5, stepTimeoutMs: 150, verifyTimeoutMs: 400 };

function setup(initial: Record<string, number> = {}) {
  const emitted: Record<string, number>[] = [];
  const lv = new LVars((v) => emitted.push(v), 200);
  const sim = new FakeFenix();
  for (const [k, v] of Object.entries(initial)) sim.state.set(k, v);
  sim.connect(lv);
  return { lv, sim, emitted, fenix: new FenixProcedures(lv, fast) };
}

const settle = (ms = 120) => new Promise((r) => setTimeout(r, ms));
const allEmitted = (emitted: Record<string, number>[]) => Object.assign({}, ...emitted) as Record<string, number>;

describe('readback', () => {
  it('reports values only once the sim confirms them', async () => {
    const { lv, sim, emitted } = setup({ S_OH_EXT_LT_BEACON: 0 });
    sim.ignore.add('S_OH_EXT_LT_BEACON'); // the sim drops the write
    lv.watch(['S_OH_EXT_LT_BEACON']);
    await settle();
    await lv.run('1 (>L:S_OH_EXT_LT_BEACON)');
    await settle();
    expect(sim.writes).toEqual([['S_OH_EXT_LT_BEACON', 1]]);
    expect(allEmitted(emitted).S_OH_EXT_LT_BEACON).toBe(0); // never shows our own write
    await expect(lv.waitFor('S_OH_EXT_LT_BEACON', (v) => v === 1, 100)).rejects.toThrow();
  });

  it('confirms a write the sim accepts', async () => {
    const { lv, emitted } = setup({ S_OH_EXT_LT_BEACON: 0 });
    await lv.run('1 (>L:S_OH_EXT_LT_BEACON)');
    await expect(lv.waitFor('S_OH_EXT_LT_BEACON', (v) => v === 1, 300)).resolves.toBe(1);
    await settle();
    expect(allEmitted(emitted).S_OH_EXT_LT_BEACON).toBe(1);
  });

  it('rejects commands while the sim is disconnected', async () => {
    const { lv } = setup();
    lv.detach();
    await expect(lv.run('1 (>L:S_OH_SIGNS)')).rejects.toThrow('sim not connected');
  });
});

describe('press/release ordering', () => {
  it('runs commands strictly in order, the release seeing the press', async () => {
    const { lv, sim } = setup({ S_FCU_AP1: 4 });
    const press = lv.run('(L:S_FCU_AP1) ++ (>L:S_FCU_AP1)');
    const release = lv.run('(L:S_FCU_AP1) 2 % 1 == if{ (L:S_FCU_AP1) ++ (>L:S_FCU_AP1) }');
    await Promise.all([press, release]);
    expect(sim.writes).toEqual([['S_FCU_AP1', 5], ['S_FCU_AP1', 6]]);
  });

  it('keeps going after a failed command', async () => {
    const { lv, sim } = setup();
    await expect(lv.run('1 2 bogus')).rejects.toThrow();
    await lv.run('1 (>L:S_OH_SIGNS)');
    expect(sim.writes).toEqual([['S_OH_SIGNS', 1]]);
  });
});

describe('reconnect', () => {
  it('clears values and cancels readback waits as soon as the simulator disconnects', async () => {
    const { lv } = setup({ S_OH_SIGNS: 1 });
    lv.watch(['S_OH_SIGNS']);
    await settle();
    const wait = lv.waitFor('S_OH_SIGNS', (v) => v === 2, 1000);
    const failed = expect(wait).rejects.toThrow('session changed');
    lv.detach();
    expect(lv.value('S_OH_SIGNS')).toBeUndefined();
    await failed;
  });

  it('does not send queued commands to a newly connected simulator session', async () => {
    const { lv } = setup();
    const queued = lv.run('1 (>L:S_OH_SIGNS)');
    const failed = expect(queued).rejects.toThrow('session changed');
    lv.detach();
    const sim = new FakeFenix().connect(lv);
    await failed;
    expect(sim.writes).toEqual([]);
  });

  it('refuses to calculate a counter from zero if the sim never supplies its initial value', async () => {
    const lv = new LVars(() => {}, 30);
    const sim = new FakeFenix().connect(lv);
    sim.latencyMs = 1000;
    await expect(lv.run('(L:S_FCU_AP1) ++ (>L:S_FCU_AP1)')).rejects.toThrow('No aircraft data');
    expect(sim.writes).toEqual([]);
    lv.detach();
  });

  it('forgets old values and watches again on the new connection', async () => {
    const { lv, sim } = setup({ S_OH_SIGNS: 1 });
    lv.watch(['S_OH_SIGNS']);
    await settle();
    expect(lv.value('S_OH_SIGNS')).toBe(1);

    lv.detach();
    const sim2 = new FakeFenix();
    sim2.state.set('S_OH_SIGNS', 0);
    sim2.connect(lv);
    expect(lv.value('S_OH_SIGNS')).toBeUndefined(); // no stale value from the old session
    await settle();
    expect(lv.value('S_OH_SIGNS')).toBe(0);
    await lv.run('1 (>L:S_OH_SIGNS)');
    expect(sim2.writes).toEqual([['S_OH_SIGNS', 1]]);
    expect(sim.writes).toEqual([]);
  });
});

describe('squawk entry', () => {
  it('does not release or continue a procedure into another session after reconnecting during a held key', async () => {
    const { lv, sim } = setup({ [XPDR_CODE]: 2000, [XPDR_CHARS]: 0 });
    const fenix = new FenixProcedures(lv, { ...fast, holdMs: 150 });
    const command = fenix.setSquawk('4521');
    const failed = expect(command).rejects.toThrow('Simulator session changed');
    for (let i = 0; i < 100 && !sim.writes.length; i++) await settle(5);
    expect(sim.writes).toHaveLength(1);
    lv.detach();
    const next = new FakeFenix().connect(lv);
    await failed;
    expect(next.writes).toEqual([]);
    lv.detach();
  });

  it('types the code key by key and verifies it', async () => {
    const { fenix, sim } = setup({ [XPDR_CODE]: 2000, [XPDR_CHARS]: 0 });
    await expect(fenix.setSquawk('4521')).resolves.toBe('Squawk 4521 set');
    expect(sim.state.get(XPDR_CODE)).toBe(4521);
  });

  it('clears a half-typed entry first', async () => {
    const { fenix, sim } = setup({ [XPDR_CODE]: 2000, [XPDR_CHARS]: 0 });
    // Someone typed "7" in the cockpit and stopped.
    sim.state.set('S_PED_ATC_7', 2);
    (sim as unknown as { entry: string }).entry = '7';
    sim.state.set(XPDR_CHARS, 1);
    await expect(fenix.setSquawk('1234')).resolves.toBe('Squawk 1234 set');
    expect(sim.state.get(XPDR_CODE)).toBe(1234);
  });

  it('refuses a second entry while one is running', async () => {
    const { fenix } = setup({ [XPDR_CODE]: 2000, [XPDR_CHARS]: 0 });
    const first = fenix.setSquawk('4521');
    await expect(fenix.setSquawk('7000')).rejects.toThrow('Already entering a squawk');
    await first;
  });

  it('reports what the transponder shows when the keypad does not respond', async () => {
    const { fenix, sim } = setup({ [XPDR_CODE]: 2000, [XPDR_CHARS]: 0 });
    sim.keypadWorks = false;
    await expect(fenix.setSquawk('4521')).rejects.toThrow('Transponder shows 2000, not 4521');
  });

  it('rejects invalid codes', async () => {
    const { fenix } = setup();
    await expect(fenix.setSquawk('7800')).rejects.toThrow('0 to 7');
    await expect(fenix.setSquawk('123')).rejects.toThrow();
  });
});

describe('standby tuning', () => {
  it('turns MHz then kHz until the window matches', async () => {
    const { fenix, sim } = setup({ N_PED_RMP1_STDBY: 118575 });
    await expect(fenix.tuneStandby(1, 121800)).resolves.toBe('121.800 in standby');
    expect(sim.state.get('N_PED_RMP1_STDBY')).toBe(121800);
  });

  it('stops with a message when the channel cannot be reached exactly', async () => {
    const { fenix, sim } = setup({ N_PED_RMP2_STDBY: 121000 });
    await expect(fenix.tuneStandby(2, 121810)).rejects.toThrow(/can't tune exactly 121\.810/);
    expect(Math.abs(sim.state.get('N_PED_RMP2_STDBY')! - 121810)).toBeLessThan(25);
  });

  it('fails clearly when the knob does nothing', async () => {
    const { fenix, sim } = setup({ N_PED_RMP1_STDBY: 118000 });
    sim.ignore.add('E_PED_RMP1_OUTER');
    await expect(fenix.tuneStandby(1, 121800)).rejects.toThrow("didn't react to the MHz knob");
  });

  it('validates the frequency', async () => {
    const { fenix } = setup();
    await expect(fenix.tuneStandby(1, 140000)).rejects.toThrow('118.000 to 136.990');
  });
});
