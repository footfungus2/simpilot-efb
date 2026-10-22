import { describe, expect, it } from 'vitest';
import { rpnVars, runRpn } from '../src/rpn.js';

function env(initial: Record<string, number> = {}) {
  const vars = { ...initial };
  const writes: [string, number][] = [];
  return {
    vars,
    writes,
    read: (n: string) => vars[n] ?? 0,
    write: (n: string, v: number) => {
      vars[n] = v;
      writes.push([n, v]);
    },
  };
}

describe('RPN presets (Fenix A320 / HubHop)', () => {
  it('increments a counter', () => {
    const e = env({ S_PED_RMP1_XFER: 4 });
    runRpn('(L:S_PED_RMP1_XFER) ++ (>L:S_PED_RMP1_XFER)', e);
    expect(e.vars.S_PED_RMP1_XFER).toBe(5);
  });

  it('releases a momentary button only when the count is odd', () => {
    const code = '(L:S_FCU_ATHR) s0 2 % 0 != if{ l0 ++ (>L:S_FCU_ATHR) }';
    const odd = env({ S_FCU_ATHR: 3 });
    runRpn(code, odd);
    expect(odd.vars.S_FCU_ATHR).toBe(4);
    const even = env({ S_FCU_ATHR: 4 });
    runRpn(code, even);
    expect(even.writes).toEqual([]);
  });

  it('handles if/els and units', () => {
    const code = '(L:S_FCU_SPEED, BOOL) if{ 0 (>L:S_FCU_SPEED) } els{ 1 (>L:S_FCU_SPEED) }';
    const on = env({ S_FCU_SPEED: 1 });
    runRpn(code, on);
    expect(on.vars.S_FCU_SPEED).toBe(0);
    const off = env({ S_FCU_SPEED: 0 });
    runRpn(code, off);
    expect(off.vars.S_FCU_SPEED).toBe(1);
  });

  it('cycles a 3-position switch and clamps with min/max', () => {
    const e = env({ S_OH_EXT_LT_STROBE: 2 });
    runRpn('(L:S_OH_EXT_LT_STROBE, Number) ++ 3 % (>L:S_OH_EXT_LT_STROBE, Number)', e);
    expect(e.vars.S_OH_EXT_LT_STROBE).toBe(0);
    const k = env({ S_TCAS_RANGE: 3 });
    runRpn('(L:S_TCAS_RANGE) 1 + 3 min (>L:S_TCAS_RANGE)', k);
    expect(k.vars.S_TCAS_RANGE).toBe(3);
  });

  it('uses the @ parameter and writes several variables in order', () => {
    const e = env();
    runRpn('@ 1023 / 0 max 1 min (>L:A_FCU_LIGHTING)', e, 512);
    expect(e.vars.A_FCU_LIGHTING).toBeCloseTo(0.5, 2);
    const both = env();
    runRpn('2 (>L:S_OH_EXT_LT_LANDING_L) 2 (>L:S_OH_EXT_LT_LANDING_R)', both);
    expect(both.writes).toEqual([['S_OH_EXT_LT_LANDING_L', 2], ['S_OH_EXT_LT_LANDING_R', 2]]);
  });

  it('lists the variables a preset touches', () => {
    expect(rpnVars('(L:S_FCU_ATHR) s0 2 % 0 != if{ l0 ++ (>L:S_FCU_ATHR) }')).toEqual({
      reads: ['S_FCU_ATHR'],
      writes: ['S_FCU_ATHR'],
    });
  });
});
