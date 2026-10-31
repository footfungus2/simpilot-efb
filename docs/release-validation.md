# Release validation

## Lido viewer and panel diagnostics — 29 October 2026

Implemented locally; not published or installed on the user's devices.

- Panel startup is reported independently of the main bundle. Its build, target and last request remain visible;
  `/api/status` checks identity without marking the chart link connected or dispatching jobs.
- Wrong link protocols return HTTP 409 without renewing link liveness. Existing app status fields and chart caches remain compatible.
- Repair verifies the supplied, staged and actual installed HTML/CSS/JS against a SHA256 manifest, preserving the compiled
  toolbar and a backup outside Community. Failed installed verification restores the old package.
- Diagnostics records expected/installed hashes, package path, bridge listener, read-only status and bounded logs locally.
  It does not call `/link/poll`; a matching disk hash still does not prove MSFS loaded that package.

### Local checks

- Unsigned iOS Release build succeeded; production IPA validation passed for **0.1.4 build 22**.
- Generic iOS device test build succeeded. XCTest runtime execution is not counted as passed.
- Panel and bridge identity/compatibility tests and TypeScript checks pass; exact counts are recorded with the delivered artifacts.
- IPA packaging regression tests pass. Windows installer fixtures were added and reviewed, but PowerShell is unavailable on this Mac.
- The socket-based bridge round-trip test is blocked by sandbox `listen EPERM`. An in-process test exercises the real panel's
  status preflight and poll through the real server request handler without claiming TCP or MSFS validation.
- Xcode's nested macro sandbox could not start inside the workspace sandbox. The local retry used Swift's
  `-disable-sandbox` compiler option; the outer workspace restrictions remained in force. No project setting was changed.

### Device and native-chart gates

- [ ] Run **Diagnose SimPilot Link** before another repair and retain the local report. Close MSFS, apply the verified repair,
      restart, and compare the displayed panel build with `PackageSources/panel-assets.json`.
- [ ] Confirm connection within seven seconds, separate simulator/link status, bridge stop/restart recovery and link expiry
      after closing the panel. Retain the first Coherent error and failed request if startup still fails.
- [ ] First real-sim chart test, in order (each gates the next; the panel log and bridge window show the numbers):
  1. The chart page appears in the panel (the LiveView shows in the `<img>`).
  2. The bridge captures it: not a black frame (MSFS windowed or borderless). If black or covered, try `PrintWindow`
     with `PW_RENDERFULLCONTENT`, then Windows.Graphics.Capture on a popped-out panel.
  3. Bridge log `capture scale=… page=…`: scale 1.000 means one screen pixel per chart pixel. Panel log shows the image
     size, its source (image / page size / assumed), the tile grid and the page URL names (needed for night charts).
  4. Export EGSS CLN 5S: readable text, no seams or repeated tiles, correct crop, ownship lines up on the georeferenced page.
  5. Load the EZY128W OFP with the panel open: CLN 5S, the LIRA STAR and runway approaches export on their own; open
     another chart meanwhile and it goes first. A prefetched chart that fails shows no error until you open it.
  Also check annotations and offline reopening of a pinned chart.


## Earlier release candidate — 23 October 2026

Status: release candidate. Local code, automated checks and packaging have been checked; physical-device and
MSFS checks below still gate calling this production verified. CI publishes only after the build and test jobs pass.

## Changes included

- First-launch app walkthrough with a skip option and concise setup steps for SimBrief, the bridge and app sections.
- Optional update checks, build-aware comparisons, installer detection with a manual override, and immutable release downloads.
- Settings → Help → Diagnostics / debug console: current connection status, aircraft-data age, bounded session logs,
  explicit PC-log loading, clear and copy-report actions. No automatic log upload or persistent log files.
- Release excludes demo flight and generated/bundled test charts. Saved real flight charts remain available offline.
- Chart packs only appear saved after all pages and the manifest are written. Failed writes preserve existing entries.
- Bridge connection timeouts, send errors, stale state and pending commands are handled explicitly.
- Weather, VATSIM and SimBrief reject failed/malformed responses and report failures without account or flight-plan contents.
- Bridge validates inbound messages, contains request failures, cancels commands across reconnects and only exposes completed chart exports.
- CI validates app/bridge/panel changes and packaging before making a complete release visible.

## Verified locally

- Unsigned iOS Release build and IPA packaging succeeded; packaged production ID is `com.simpilot.efb`.
- IPA validator confirmed device build, executable and numeric version/build; no bundled TestCharts or development/signing files.
- Eight executable Swift tests passed for update ordering/URLs, installer markers, bridge addresses, diagnostic bounds/redaction
  and repeated PC-log imports retaining the original app failure.
- All native XCTest sources compiled in a generic iOS test build and an ad-hoc-signed simulator test build.
- Five packaging tests passed, including rejection of development assets and wrong bundle/platform metadata.
- Bridge: 61 regression tests, TypeScript check/build, compiled startup and HTTP/WebSocket/diagnostics smoke checks passed.
- In-sim panel: eight regression tests, TypeScript check and bundle build passed.
- Runtime bridge dependency audit reported zero known vulnerabilities.
- Focused service checks passed with mocked HTTP errors/recovery, malformed numeric/geometry data and diagnostic privacy checks.
- Live METAR and VATSIM feeds returned HTTP 200 and the expected JSON structure; no personal SimBrief account was queried.
- Release-publication script passed mocked new/resumed draft, already-published, stale-commit and upload-failure cases.

## Simulator execution limit

The first simulator launch exposed unsigned embedded MapLibre code; simulator builds now use ad-hoc signing and
signature verification passes. The retry stalled before any XCTest case started. The installed iOS 27.1 runtime also
failed bounded boot-status and screenshot queries, so the stalled test was stopped. Native test execution is **not**
counted as passed. CI uses an ad-hoc-signed iPad simulator build and must pass before publication.

## Required device checks

- [ ] Install the release IPA on the iPad running iPadOS 15.3.1; verify map/globe rendering and sustained performance.
      The vendored MapLibre pre-release has a lowered deployment declaration, so a successful build does not establish compatibility.
- [ ] Import a real SimBrief OFP; verify route, charts, annotations, split view and saved FLIGHT pack through an app restart without Wi-Fi.
- [ ] Start the Windows bridge and SimPilot Link in MSFS 2024; verify live position, complete chart export and reconnection after Wi-Fi/bridge loss.
      Panel requests must reach bridge-PC loopback with no Origin or a `coui://…` Origin; rejected requests appear in PC diagnostics.
- [ ] Exercise Fenix radio, squawk, FCU and lights, including rapid input, partial squawk entry and simulator readback.
- [ ] Install consecutive published builds using both SideStore and TrollStore; verify installer detection, optional update flow and retained data.
- [ ] Reproduce a connection failure on the iPad, load PC logs and inspect a copied report before sharing it.

Only an iPhone simulator runtime is installed on the development Mac. Simulator test builds use a temporary device-family
override to run code tests; they cannot establish iPad layout, iPadOS 15 or physical-installer compatibility.
