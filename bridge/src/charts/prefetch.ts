// Which charts of an airport a loaded flight will need: its SID at the origin, its STAR and the approaches for the
// planned runway at the destination. Same matching as the iPad's default chart (ChartsModel.defaultChart).

import type { ChartIndex } from '../types.js';

export interface FlightWant {
  role: 'origin' | 'destination';
  /** Procedure names from the OFP navlog, e.g. ["CLN5S"]. */
  procedures: string[];
  /** Planned runway from the OFP, e.g. "04" or "22L". */
  runway?: string;
}

const norm = (s: string) => s.toUpperCase().replace(/[ .]/g, '');
const rwy = (s: string) => {
  const t = s.trim().toUpperCase().replace(/^RW/, '');
  return /^\d$/.test(t[0] ?? '') && !/^\d\d/.test(t) ? `0${t}` : t;
};

export function pickFlightCharts(index: ChartIndex, want: FlightWant): string[] {
  const wanted = want.procedures.map(norm).filter(Boolean);
  const runway = want.runway ? rwy(want.runway) : '';
  const matchesProcedure = (procs: string[]) => procs.some((p) => wanted.some((w) => norm(p) === w || norm(p).startsWith(w)));
  const sidType = want.role === 'origin' ? 'SID' : 'STAR';
  const picked: string[] = [];
  for (const chart of index.categories.flatMap((c) => c.charts)) {
    const type = chart.type.toUpperCase();
    const byProcedure = wanted.length > 0 && type.startsWith(sidType) && matchesProcedure(chart.procedures);
    const byRunway = want.role === 'destination' && runway !== '' && (type === 'IAC' || type === 'APC') && chart.runways.map(rwy).includes(runway);
    if ((byProcedure || byRunway) && !picked.includes(chart.guid)) picked.push(chart.guid);
  }
  return picked;
}
