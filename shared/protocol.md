# SimPilot EFB protocol (v1)

Three parties:

- **bridge**: Node server on the MSFS PC, port `8386` by default.
- **link**: an in-sim toolbar panel. It reaches the bridge at `http://127.0.0.1:8386` (not 8380, FlyByWire SimBridge's port) (HTTP only; Coherent's WebSocket support is unreliable).
- **app**: the iPad. It finds the bridge through Bonjour `_simpilot._tcp` or a manually entered IP.

All JSON fields are camelCase. Coordinates are decimal degrees, altitudes are feet, speeds are knots, angles are degrees true.

## App ⇄ bridge: WebSocket `ws://<host>:8386/ws`

Bridge → app:

| `t` | payload |
|---|---|
| `hello` | `{ v: 1, bridgeVersion, status }` |
| `status` | `{ sim: { connected, aircraftTitle? }, link: { connected, lastSeenMs? } }` |
| `ownship` | `{ lat, lon, altFt, gsKt, trkDeg, hdgDeg, vsFpm, onGround, magVarDeg, ts }` (≈10 Hz) |
| `chartsReady` | `{ icao }`: the airport's chart list is cached |
| `chartsError` | `{ icao, message }`: the chart list couldn't be fetched |
| `chartReady` | `{ icao, guid }`: every page of the chart is exported and cached |
| `chartProgress` | `{ icao, guid, done, total }`: pages exported so far |
| `chartError` | `{ icao, guid, message }`: the chart couldn't be exported |
| `lvars` | `{ values: { [name]: number } }`: watched aircraft L:vars that changed, **as read back from the sim** (the bridge never echoes its own writes) |
| `commandResult` | `{ id, ok, message? }`: outcome of an app command that carried an `id` |

App → bridge:

| `t` | payload |
|---|---|
| `requestCharts` | `{ icao }`: queues the airport's chart list unless it is already cached (e.g. for the airports of a loaded flight) |
| `lvarWatch` | `{ names: string[] }`: start sending these L:vars (e.g. `N_PED_RMP1_ACTIVE`) as they change |
| `lvarRun` | `{ code, value?, id? }`: run an MSFS RPN snippet (HubHop preset syntax) on the aircraft's L:vars; `@` = `value`. Commands run in order; with an `id` the bridge answers `commandResult` once it has written the values |
| `fenixSquawk` | `{ code, id? }`: Fenix only. Clears a half-typed entry, types the code key by key (waiting for each key in the sim) and checks the final code; one at a time |
| `fenixTune` | `{ rmp, khz, id? }`: Fenix only. Turns RMP `rmp`'s knobs until its standby window reads `khz` (121800 = 121.800), reading it back after every click |

## App → bridge: HTTP

| method & path | result |
|---|---|
| `GET /api/status` | same as the `status` message |
| `GET /api/charts/:icao` | `ChartIndex` (below), or `202 { queued: true, linkConnected }` if the list isn't cached yet. A list older than 24 h is served as is and fetched again in the background |
| `GET /api/charts/:icao/:guid` | `{ chart: ChartMeta, pages: ChartPage[] }` once every page is exported. Otherwise `202 { queued: true, linkConnected, done, total }`: the sim exports the chart now and `chartProgress`, then `chartReady` or `chartError`, follow. `?refresh=1` forgets the exported pages first |
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
| `GET /link/poll?proto=2` | heartbeat → `{ jobs: { id, type: 'index' \| 'chart', icao, provider, guid? }[] }`. Chart lists (`index`) come first, then only the chart that was asked for last (`chart`, with its `guid`); the bridge decides, the link just does the work. `proto` is the link protocol number: with another number the bridge hands out nothing and fails the waiting requests with an "out of date" message. While the link is busy it sends `&busy=1`, which only shows it is still there |
| `POST /link/index` | `{ jobId, icao, provider, index: <raw SimChartIndex> }`: the bridge stores the list and tells the app at once |
| `POST /link/pages` | `{ jobId, icao, guid, pages: <raw SimChartPage[]> }` → `{ ok, have: number[] }`: the pages that are exported already, which the link skips |
| `POST /link/capture` | `{ jobId, icao, guid, page, i, j, cols, rows, view: { w, h }, image: { w, h } }` → `{ ok, saved }`: one screen-captured tile of the page the panel shows; `saved` is true once the last tile arrived and the stitched page is stored |
| `POST /link/done` | `{ jobId, icao, error? }`: the bridge checks that every page is stored before it sends `chartReady` |
| `POST /link/log` | `{ level, msg }` for spike diagnostics |
