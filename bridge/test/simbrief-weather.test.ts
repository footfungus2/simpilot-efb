import { describe, expect, it } from 'vitest';
import { Router } from '../src/http.js';
import { normalizeOfp } from '../src/simbrief.js';
import { metarCategory, parseIds } from '../src/weather.js';

// Trimmed-down SimBrief json=1 response (all values are strings, single alternates are objects).
const rawOfp = {
  fetch: { status: 'Success' },
  params: { airac: '2510', units: 'kgs' },
  general: { icao_airline: 'DLH', flight_number: '400', route: 'OBOKA DCT KERAX', route_distance: '3384', initial_altitude: '35000', costindex: '30' },
  atc: { callsign: 'DLH400' },
  aircraft: { icaocode: 'A359', name: 'A350-900', reg: 'D-AIXA' },
  origin: { icao_code: 'EDDF', iata_code: 'FRA', name: 'Frankfurt/Main', pos_lat: '50.033333', pos_long: '8.570556', elevation: '364', plan_rwy: '25C', metar: 'EDDF 191650Z CAVOK' },
  destination: { icao_code: 'KJFK', iata_code: 'JFK', name: 'John F Kennedy Intl', pos_lat: '40.639751', pos_long: '-73.778925', elevation: '13', plan_rwy: '31L' },
  alternate: { icao_code: 'KBOS', iata_code: 'BOS', name: 'Boston Logan', pos_lat: '42.36', pos_long: '-71.01' },
  times: { sched_out: '1792430000', sched_off: '1792430900', sched_on: '1792460000', sched_in: '1792460600', est_time_enroute: '29100' },
  fuel: { plan_ramp: '72000', plan_takeoff: '71500', plan_landing: '9000', min_takeoff: '70000' },
  navlog: {
    fix: [
      { ident: 'OBOKA', name: 'OBOKA', type: 'wpt', pos_lat: '50.9', pos_long: '7.9', altitude_feet: '12000', via_airway: 'OBOKA2G', stage: 'CLB', is_sid_star: '1', distance: '45', frequency: {} },
      { ident: 'KERAX', name: 'KERAX', type: 'wpt', pos_lat: '51.3', pos_long: '6.7', altitude_feet: '35000', via_airway: 'DCT', stage: 'CRZ', is_sid_star: '0', distance: '55' },
    ],
  },
  text: { plan_html: '<div>OFP</div>' },
  files: { directory: 'https://www.simbrief.com/ofp/flightplans/', pdf: { name: 'x', link: 'EDDFKJFK_PDF_1.pdf' } },
};

describe('SimBrief normalization', () => {
  it('parses airports, navlog and files', () => {
    const ofp = normalizeOfp(rawOfp);
    expect(ofp.callsign).toBe('DLH400');
    expect(ofp.origin).toMatchObject({ icao: 'EDDF', iata: 'FRA', planRwy: '25C', lat: 50.033333 });
    expect(ofp.alternates.map((a) => a.icao)).toEqual(['KBOS']);
    expect(ofp.cruiseFl).toBe(350);
    expect(ofp.distanceNm).toBe(3384);
    expect(ofp.navlog.map((f) => [f.ident, f.cumNm, f.isSidStar])).toEqual([
      ['OBOKA', 45, true],
      ['KERAX', 100, false],
    ]);
    expect(ofp.navlog[0]!.frequency).toBe(''); // {} → ''
    expect(ofp.pdfUrl).toBe('https://www.simbrief.com/ofp/flightplans/EDDFKJFK_PDF_1.pdf');
  });

  it('accepts multiple alternates and a missing navlog', () => {
    const ofp = normalizeOfp({ ...rawOfp, alternate: [rawOfp.alternate, { icao_code: 'KEWR' }], navlog: undefined });
    expect(ofp.alternates.map((a) => a.icao)).toEqual(['KBOS', 'KEWR']);
    expect(ofp.navlog).toEqual([]);
  });
});

describe('weather', () => {
  it('categorizes METARs like the Lido indicator', () => {
    expect(metarCategory({ visib: '6+', clouds: [] })).toBe('green');
    expect(metarCategory({ visib: 2, clouds: [{ cover: 'BKN', base: 2000 }] })).toBe('amber'); // 3.2 km
    expect(metarCategory({ visib: 10, clouds: [{ cover: 'SCT', base: 300 }, { cover: 'OVC', base: 1200 }] })).toBe('amber');
    expect(metarCategory({ visib: 0.5, clouds: [] })).toBe('red');
    expect(metarCategory({ visib: 10, clouds: [{ cover: 'OVC', base: 300 }] })).toBe('red');
    expect(metarCategory({})).toBe('unknown');
  });

  it('sanitizes station id lists', () => {
    expect(parseIds('eddf, EGLL,,EDDF,bad!id,KJFK')).toEqual(['EDDF', 'EGLL', 'KJFK']);
    expect(parseIds(null)).toEqual([]);
  });
});

describe('Router', () => {
  it('matches params including file extensions', () => {
    const r = new Router().add('GET', '/charts/:icao/:guid/:page.png', () => {});
    expect(r.match('GET', '/charts/EDDF/%7Bab%7D/3.png')?.params).toEqual({ icao: 'EDDF', guid: '{ab}', page: '3' });
    expect(r.match('GET', '/charts/EDDF/x/3.jpg')).toBeUndefined();
    expect(r.match('POST', '/charts/EDDF/x/3.png')).toBeUndefined();
  });
});
