# SimPilot EFB

An mPilot-style electronic flight bag for **MSFS 2024** that runs on an iPad (iOS 15+). It shows the sim's built-in
Lido charts, a Lido-style enroute map with your aircraft, the SimBrief flight folder, a vertical profile and weather.

Unofficial, personal-use tool. It doesn't use Lido or Lufthansa names or logos, and chart data comes from your own MSFS 2024 installation. Don't redistribute the extracted charts.

```
 MSFS 2024 ──SimConnect──►┐
                          │   bridge (Node, on the sim PC) ◄── Wi-Fi ──► iPad app (SwiftUI)
 SimPilot Link panel ─HTTP┘   • ownship 10 Hz   • chart cache   • SimBrief / weather proxy
 (in-sim, exports Lido charts)
```

| folder | what |
|---|---|
| `bridge/` | Node + TypeScript server on the sim PC (`start-bridge.bat`) |
| `sim-package/` | MSFS 2024 toolbar panel "SimPilot Link" that exports the Lido charts (`build.ps1`) |
| `ios/` | the iPad app (SwiftUI, iOS 15 target, XcodeGen project) |
| `shared/protocol.md` | bridge ⇄ app ⇄ link protocol |
| `docs/design-reference.md` | mPilot UI notes used to match the look |

## Install on the iPad (no Mac needed)
Every push to `main` is built by GitHub Actions. Open the [latest release](../../releases/latest), download
**SimPilotEFB.ipa** on the iPad and open it with **TrollStore** (iPad on iOS 15+ with TrollStore installed).
To update, install the newer IPA the same way; TrollStore keeps your settings.

## Setup

### On the Windows PC (MSFS 2024)
1. Install **Node.js 20+** from nodejs.org.
2. Copy this repo to the PC and double-click **`bridge/start-bridge.bat`**. If Windows Firewall asks, allow *private networks*.
   The window prints the PC's address (e.g. `192.168.1.20:8380`).
3. Install the **MSFS 2024 SDK** (in the sim: Dev Mode → Help → SDK Installer). Then in PowerShell:
   `cd sim-package; ./build.ps1`. This builds the panel and copies it into your Community folder.
4. In a flight, open **SimPilot Link** from the toolbar once. It says *Bridge: connected* and exports charts when the iPad asks for them.

### On the Mac (building the iPad app)
1. Install **Xcode** from the App Store, then `sudo xcode-select -s /Applications/Xcode.app`.
2. `brew install xcodegen`
3. Optional, for running on "My Mac (Designed for iPad)" from Xcode: create `ios/Local.xcconfig` with
   `DEVELOPMENT_TEAM = <your team ID>` (Xcode → Settings → Accounts). Not needed for the IPA.
4. `./scripts/vendor-maplibre.sh` (downloads the map library into `ios/Vendor/`; `build-ipa.sh` also does this if it's missing)
5. `./scripts/build-ipa.sh` → `SimPilotEFB.ipa`. AirDrop it to the iPad and install it with **TrollStore**.

### Updating the iPad without re-sideloading
Xcode 27 can't install on iOS 15 devices, so updates go through TrollStore's install link instead:
1. `./scripts/dev-install.sh` — builds the IPA and serves an install page on your Wi-Fi (port 8090).
2. On the iPad, open the printed `http://<mac-ip>:8090` once and *Add to Home Screen*.
3. After every rebuild, open that page and tap **Install update in TrollStore**. It installs over the old version and keeps your settings.

In TrollStore → Settings, make sure **URL Scheme Enabled** is on. `./scripts/dev-install.sh stop` stops the page.

### On the iPad
The app finds the bridge automatically (Bonjour). If it doesn't, open Settings (✓ button) and enter the address the bridge printed.
Enter your SimBrief username there as well and tap *Load latest OFP*.

## Development
- Bridge: `cd bridge && npm install && npm test && npm run dev`. To run the bridge on the Mac against the sim PC, enable
  remote SimConnect on the PC (`SimConnect.xml`, address `0.0.0.0`, port 5111) and start with `SIMPILOT_SIMCONNECT=<pc-ip>:5111`.
- Panel: `cd sim-package && npm install && npm run build` (bundles `src/` into the panel's `link.js`).
- iOS: `cd ios && xcodegen && open SimPilotEFB.xcodeproj`.

## Status
See `CLAUDE.md` for the current state, decisions and next steps.

## Map data
- FIR/UIR boundaries: [VATSpy Data Project](https://github.com/vatsimnetwork/vatspy-data-project), CC BY-SA 4.0
- Coastlines, lakes, country labels: Natural Earth (public domain)
- Airports: OurAirports (public domain)
- Airport moving maps: © OpenStreetMap contributors (ODbL), fetched per airport via the Overpass API and cached
- Debug charts (`ios/SimPilotEFB/Resources/TestCharts`): UK AIP charts, © NATS / Crown copyright — personal use only,
  so the PDFs are **not in this repo** (only `manifest.json` with their georeferencing). To use them, download the
  EGSS SID charts CLN 5S/9R and DET 2D from the UK AIP (NATS) and save them under the file names in `manifest.json`;
  without them the app simply skips those charts.
- VATSIM layer: live data from data.vatsim.net; approach areas from the SimAware TRACON Project (CC BY-SA 4.0);
  real sector ownership from the VATGlasses Data Project (CC BY-NC-SA 4.0, non-commercial use only)

Rebuild the bundled layers with `python3 -I scripts/build-basemap.py`.
