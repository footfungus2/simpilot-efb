import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { normalizeIndex, normalizePages, procedureLabel, runwayLabel } from '../src/charts/normalize.js';
import { ChartStore, safeIcao, safeId } from '../src/charts/store.js';

// Shape mirrors SimChartIndex from @microsoft/msfs-sdk.
const rawIndex = {
  airportIcao: { __Type: 'JS_ICAO', type: 'A', region: '', airport: '', ident: 'EDDF' },
  charts: [
    {
      name: 'IAC',
      charts: [
        {
          provider: 'LIDO',
          guid: '{A1B2-C3}',
          type: 'IAC',
          airportIcao: { ident: 'EDDF' },
          name: 'ILS Z RWY 25L',
          geoReferenced: true,
          procedures: [
            {
              type: 2,
              ident: '',
              enrouteTransition: null,
              runways: [{ number: '25', designator: 'L' }],
              approachIdentifier: { type: 'ILS', suffix: 'Z', runway: { number: '25', designator: 'L' } },
            },
          ],
          runways: [{ number: '25', designator: 'L' }],
          aircraftTypes: [],
          relationships: [],
          validFrom: 1790000000000,
          validUntil: null,
        },
        { name: 'broken, no guid' },
      ],
    },
    {
      name: 'SID',
      charts: [
        {
          guid: 'sid-1',
          type: 'SID',
          name: 'OBOKA 2G',
          procedures: [{ type: 0, ident: 'OBOKA2G', enrouteTransition: null, runways: [{ number: '7', designator: 'C' }] }],
          runways: [],
        },
      ],
    },
  ],
};

describe('chart normalization', () => {
  it('formats runways and procedures', () => {
    expect(runwayLabel({ number: '7', designator: 'C' })).toBe('07C');
    expect(runwayLabel(null)).toBe('');
    expect(procedureLabel(rawIndex.charts[0]!.charts[0]!.procedures![0]!)).toBe('ILS Z 25L');
    expect(procedureLabel({ type: 1, ident: 'UNOK1A', enrouteTransition: 'UNOKO' })).toBe('UNOK1A.UNOKO');
  });

  it('normalizes an index and drops charts without a GUID', () => {
    const idx = normalizeIndex(rawIndex, 'EDDF', 'LIDO');
    expect(idx.categories.map((c) => c.name)).toEqual(['IAC', 'SID']);
    expect(idx.categories[0]!.charts).toHaveLength(1);
    expect(idx.categories[0]!.charts[0]).toMatchObject({ guid: '{A1B2-C3}', runways: ['25L'], procedures: ['ILS Z 25L'], geoReferenced: true });
    expect(idx.categories[1]!.charts[0]!.runways).toEqual(['07C']);
  });

  it('normalizes pages and keeps only complete georeferenced areas', () => {
    const pages = normalizePages([
      {
        width: 1000,
        height: 1400,
        geoReferenced: true,
        urls: [
          { name: 'thumbnail', url: 'https://x/t.jpg' },
          { name: 'light_png', url: 'https://x/p.png' },
        ],
        areas: [
          {
            layer: 'plan',
            geoReferenced: true,
            chartRectangle: { upperLeft: [10, 20], lowerRight: [990, 1000], orientation: 0 },
            worldRectangle: { upperLeft: [8.3, 50.2], lowerRight: [8.9, 49.9], orientation: 0 },
            projection: { standardParallel1: 49, standardParallel2: 51, centralMeridian: 8.6 },
          },
          { layer: 'profile', geoReferenced: false, chartRectangle: { upperLeft: [0, 1000], lowerRight: [1000, 1400], orientation: 0 } },
          { layer: 'bad', geoReferenced: true, chartRectangle: { upperLeft: [0, 0], lowerRight: [1, 1], orientation: 0 } },
        ],
      },
    ]);
    expect(pages[0]!.areas).toHaveLength(3);
    expect(pages[0]!.areas[0]!.geoReferenced).toBe(true);
    expect(pages[0]!.areas[2]!.geoReferenced).toBe(false); // missing projection → not usable
  });
});

describe('ChartStore', () => {
  it('rejects unsafe identifiers', () => {
    expect(() => safeIcao('../etc')).toThrow();
    expect(safeIcao(' eddf ')).toBe('EDDF');
    expect(safeId('{A1/B2}')).toBe('{A1_B2}');
    expect(() => safeId('..')).toThrow();
  });

  it('round-trips index, pages and images', async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'simpilot-'));
    const store = new ChartStore(dir);
    await store.saveIndex(normalizeIndex(rawIndex, 'EDDF', 'LIDO'));
    await store.savePages('EDDF', '{A1B2-C3}', normalizePages([{ width: 10, height: 10, areas: [], urls: [] }, { width: 10, height: 10 }]));
    const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(16)]);
    await store.saveImage('EDDF', '{A1B2-C3}', 1, png);
    await expect(store.saveImage('EDDF', '{A1B2-C3}', 0, Buffer.from('nope, not png'))).rejects.toThrow();

    const chart = await store.getChart('EDDF', '{A1B2-C3}');
    expect(chart?.chart.pageCount).toBe(2);
    expect(chart?.pages[0]!.image).toBeNull();
    expect(chart?.pages[1]!.image).toMatch(/^\/charts\/EDDF\/%7BA1B2-C3%7D\/1\.png\?v=\d+$/);

    await store.removeChart('EDDF', '{A1B2-C3}');
    expect(await store.getChart('EDDF', '{A1B2-C3}')).toBeUndefined();
    await fs.rm(dir, { recursive: true });
  });
});
