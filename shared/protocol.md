# SimPilot EFB protocol (v1)

Three parties:

- **bridge**: Node server on the MSFS PC, port `8380` by default.
- **link**: an in-sim toolbar panel. It reaches the bridge at `http://localhost:8380` (HTTP only; Coherent's WebSocket support is unreliable).
- **app**: the iPad. It finds the bridge through Bonjour `_simpilot._tcp` or a manually entered IP.

All JSON fields are camelCase. Coordinates are decimal degrees, altitudes are feet, speeds are knots, angles are degrees true.

## App ⇄ bridge: WebSocket `ws://<host>:8380/ws`

Bridge → app:

| `t` | payload |
|---|---|
| `hello` | `{ v: 1, bridgeVersion, status }` |
| `status` | `{ sim: { connected, aircraftTitle? }, link: { connected, lastSeenMs? } }` |
| `ownship` | `{ lat, lon, altFt, gsKt, trkDeg, hdgDeg, vsFpm, onGround, magVarDeg, ts }` (≈10 Hz) |
| `chartsReady` | `{ icao }`: the chart index and pages are now cached |
| `chartsProgress` | `{ icao, done, total }` |
| `chartsError` | `{ icao, message }` |

App → bridge:

| `t` | payload |
|---|---|
| `requestCharts` | `{ icao }`: queues a link job unless the airport is already cached |

## App → bridge: HTTP

| method & path | result |
|---|---|
| `GET /api/status` | same as the `status` message |
| `GET /api/charts/:icao` | `ChartIndex` (below), or `202 { queued: true }` if not cached yet |
| `GET /api/charts/:icao/:guid` | `{ chart: ChartMeta, pages: ChartPage[] }` |
| `GET /charts/:icao/:guid/:page.png` | the PNG image |
| `GET /api/ofp?user=<simbrief username or id>` | `Ofp` (normalized SimBrief OFP) |
| `GET /api/wx/metar?ids=EDDF,EGLL` | `Metar[]` |
| `GET /api/wx/taf?ids=…` | `Taf[]` |
| `GET /api/wx/sigmets` | GeoJSON FeatureCollection of international SIGMETs |
| `GET /api/amm/:icao` | GeoJSON FeatureCollection for the airport moving map (phase 5) |

```ts
type ChartIndex = { icao: string; provider: 'LIDO' | 'FAA'; fetchedAt: number;
  categories: { name: string; charts: ChartMeta[] }[] };
type ChartMeta = { guid: string; type: string; name: string; runways: string[];
  procedures: string[]; geoReferenced: boolean; pageCount?: number;
  validFrom: number | null; validUntil: number | null };
type ChartPage = { index: number; width: number; height: number; geoReferenced: boolean;
  areas: ChartArea[]; image: string | null /* relative URL, or null if missing */ };
type ChartArea = { layer: string; geoReferenced: boolean;
  chartRect: Rect; worldRect?: Rect;
  projection?: { standardParallel1: number; standardParallel2: number; centralMeridian: number } };
type Rect = { upperLeft: [number, number]; lowerRight: [number, number]; orientation: number };
```

## Link ⇄ bridge: HTTP (polling)

| method & path | body / result |
|---|---|
| `GET /link/poll` | heartbeat → `{ jobs: { id, type: 'charts', icao, provider }[] }` |
| `POST /link/index` | `{ jobId, icao, provider, index: <raw SimChartIndex> }` |
| `POST /link/pages` | `{ jobId, icao, guid, pages: <raw SimChartPage[]> }` |
| `POST /link/image` | `{ jobId, icao, guid, page, pngBase64 }`, **or** `{ …, url }` so the bridge downloads it → `{ ok, saved }`; if `saved` is false the link tries its next export method |
| `POST /link/done` | `{ jobId, icao, error? }` |
| `POST /link/log` | `{ level, msg }` for spike diagnostics |
