# Stages SimPilot-for-PC.zip for the GitHub release: a bundled signed Node.js runtime and SimPilot Bridge launcher, the ready-made
# chart panel with its one-click installer, and a short read-me. CI runs it on Windows after
# `npm run package:portable` (bridge) and `npm run build` (sim-package).
#   pwsh ./scripts/package-pc.ps1 -OutDir release-pc
param([string]$OutDir = 'release-pc')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = if ([System.IO.Path]::IsPathRooted($OutDir)) { [System.IO.Path]::GetFullPath($OutDir) } else { [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $OutDir)) }
$temporary = Join-Path $out ('.stage-' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $temporary 'SimPilot for PC'
$panel = Join-Path $stage 'Chart panel (optional)'

$runtime = Join-Path $root 'bridge\dist\app\node.exe'
$bundle = Join-Path $root 'bridge\dist\app\bridge.cjs'
$launcher = Join-Path $root 'bridge\dist\app\SimPilot Bridge (console).cmd'
$launcherExe = Join-Path $root 'bridge\dist\app\SimPilot Bridge.exe'
$sim = Join-Path $root 'sim-package'
$linkJs = Join-Path $sim 'PackageSources\html_ui\InGamePanels\SimPilotLink\link.js'
foreach ($file in @($runtime, $bundle, $launcher, $launcherExe)) {
  if (-not (Test-Path -LiteralPath $file)) { throw "Missing $file - run 'npm run package:portable' in bridge first." }
}
foreach ($file in @($linkJs, (Join-Path $sim 'PackageSources\panel-assets.json'))) {
  if (-not (Test-Path -LiteralPath $file)) { throw "Missing $file - run 'npm run build' in sim-package first." }
}
$notices = Join-Path $root 'bridge\dist\app\Source and notices'
if (-not (Test-Path -LiteralPath $notices)) { throw 'Source and license notices are missing. Rebuild SimPilot Bridge before packaging.' }

try {
New-Item -ItemType Directory -Path $panel -Force | Out-Null

foreach ($file in @($runtime, $bundle, $launcher, $launcherExe)) { Copy-Item -LiteralPath $file -Destination $stage }
Copy-Item -LiteralPath $notices -Destination $stage -Recurse
Copy-Item -LiteralPath (Join-Path $sim 'install.bat') -Destination (Join-Path $panel 'Install SimPilot Link.bat')
Copy-Item -LiteralPath (Join-Path $sim 'repair.bat') -Destination (Join-Path $panel 'Repair SimPilot Link.bat')
Copy-Item -LiteralPath (Join-Path $sim 'diagnose.bat') -Destination (Join-Path $panel 'Diagnose SimPilot Link.bat')
foreach ($item in 'build.ps1', 'package.xml', 'PackageDefinitions', 'PackageSources') {
  Copy-Item -LiteralPath (Join-Path $sim $item) -Destination $panel -Recurse
}

$readme = @'
SimPilot for PC
===============

Open the "SimPilot for PC" folder after choosing Extract All.

1. Double-click "SimPilot Bridge" (the one with the SimPilot icon) and leave it running while you fly.
   Its window shows whether the iPad, MSFS and the chart panel are connected. Closing the window
   keeps it running in the tray (next to the clock); right-click the tray icon to quit.
   "Check for updates" in the window installs newer versions by itself.
   (If it won't open, "SimPilot Bridge (console).cmd" runs the same bridge in a plain text window.)
   - If Windows Firewall asks: tick "Private networks" and click "Allow access".
     Windows may call it "Node.js JavaScript Runtime"; that is SimPilot Bridge.
   Keep the iPad and PC on the same local network (Wi-Fi or Ethernet).
   On the iPad, tap OK when SimPilot EFB asks to find devices on your local network.
   The app's status icon turns orange when the PC is found, and green once MSFS and
   the optional SimPilot Link chart panel are connected too.

2. Optional - the sim's charts on the iPad (one-time setup):
   a. In MSFS 2024 open Settings > Advanced Options and switch Developer Mode on.
      In the menu bar that appears at the top, choose Help > SDK Installer and install the SDK.
   b. Close MSFS 2024. Open "Chart panel (optional)" and double-click "Install SimPilot Link".
      It may be shown as "Install SimPilot Link.bat". Choose the Packages folder if asked.
   c. Start MSFS 2024 again: new panels load only when the sim starts.
      In a flight, click the gear icon in the toolbar, switch "SimPilot Link" on and open it.
      Open the panel once per flight.
   d. Keep the panel open and fully visible (not minimised or covered). An airport's chart list
      appears on the iPad at once; a chart is exported the first time you open it, which takes a
      few seconds: the panel shows each chart page and SimPilot Bridge copies it from the screen.
      A bigger panel (or one popped out into its own window) is faster and gives sharper charts.
      MSFS must run in windowed or borderless mode, or the bridge can't see the panel.

Not connecting?
- If SimPilot Link is installed but stays on "Bridge searching", close MSFS and run
  "Repair SimPilot Link.bat" from "Chart panel (optional)". It updates the installed
  panel HTML, CSS and script without an SDK build, verifies the installed file hashes,
  and keeps a backup beside Community2024. Check the panel's displayed build after restarting MSFS.
- While the panel is still stuck, run "Diagnose SimPilot Link.bat" from that same folder.
  Review its local SimPilot-Link-diagnostics.log before sharing it. It records installed
  file hashes, the port owner and read-only bridge status; it does not impersonate the panel.
- Windows: Settings > Network & internet > Wi-Fi (or Ethernet) > your home network > Private network.
- If the firewall prompt was cancelled: Windows Security > Firewall & network protection >
  Allow an app through firewall > Change settings. Tick Private for Node.js JavaScript Runtime.
- iPad: Settings > Privacy > Local Network > switch SimPilot EFB on.
- Avoid guest networks. In Settings > Bridge, try the PC's Wi-Fi or Ethernet address shown
  in the bridge window, rather than a VPN or virtual adapter's address.

More help: https://github.com/footfungus2/simpilot-efb#connect-to-msfs-2024
'@
# Notepad-friendly line endings.
Set-Content -LiteralPath (Join-Path $stage 'Read me.txt') -Value ($readme -replace "`r?`n", "`r`n") -NoNewline -Encoding UTF8

$zip = Join-Path $out 'SimPilot-for-PC.zip'
Compress-Archive -Path $stage -DestinationPath $zip -Force
Write-Host "Built $zip ($([math]::Round((Get-Item -LiteralPath $zip).Length / 1MB)) MB)"
} finally {
  if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
