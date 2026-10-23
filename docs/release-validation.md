# Release validation — 23 October 2026

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
