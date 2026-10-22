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
| `lvars` | `{ values: { [name]: number } }`: watched aircraft L:vars that changed, **as read back from the sim** (the bridge never echoes its own writes) |
| `commandResult` | `{ id, ok, message? }`: outcome of an app command that carried an `id` |

App → bridge:

| `t` | payload |
|---|---|
| `requestCharts` | `{ icao }`: queues a link job unless the airport is already cached |
| `lvarWatch` | `{ names: string[] }`: start sending these L:vars (e.g. `N_PED_RMP1_ACTIVE`) as they change |
| `lvarRun` | `{ code, value?, id? }`: run an MSFS RPN snippet (HubHop preset syntax) on the aircraft's L:vars; `@` = `value`. Commands run in order; with an `id` the bridge answers `commandResult` once it has written the values |
| `fenixSquawk` | `{ code, id? }`: Fenix only. Clears a half-typed entry, types the code key by key (waiting for each key in the sim) and checks the final code; one at a time |
| `fenixTune` | `{ rmp, khz, id? }`: Fenix only. Turns RMP `rmp`'s knobs until its standby window reads `khz` (121800 = 121.800), reading it back after every click |

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
