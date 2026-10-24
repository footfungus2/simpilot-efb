# Stages SimPilot-for-PC.zip for the GitHub release: SimPilot Bridge.exe (runs without Node.js), the ready-made
# chart panel with its one-click installer, and a short read-me. CI runs it on Windows after
# `npm run package:exe` (bridge) and `npm run build` (sim-package).
#   pwsh ./scripts/package-pc.ps1 -OutDir release-pc
param([string]$OutDir = 'release-pc')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = if ([System.IO.Path]::IsPathRooted($OutDir)) { [System.IO.Path]::GetFullPath($OutDir) } else { [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $OutDir)) }
$temporary = Join-Path $out ('.stage-' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $temporary 'SimPilot for PC'
$panel = Join-Path $stage 'Chart panel (optional)'

$exe = Join-Path $root 'bridge\dist\app\SimPilot Bridge.exe'
$sim = Join-Path $root 'sim-package'
$linkJs = Join-Path $sim 'PackageSources\html_ui\InGamePanels\SimPilotLink\link.js'
if (-not (Test-Path -LiteralPath $exe)) { throw "Missing $exe - run 'npm run package:exe' in bridge first." }
if (-not (Test-Path -LiteralPath $linkJs)) { throw "Missing $linkJs - run 'npm run build' in sim-package first." }
$notices = Join-Path $root 'bridge\dist\app\Source and notices'
if (-not (Test-Path -LiteralPath $notices)) { throw 'Source and license notices are missing. Rebuild SimPilot Bridge before packaging.' }

try {
New-Item -ItemType Directory -Path $panel -Force | Out-Null

Copy-Item -LiteralPath $exe -Destination $stage
Copy-Item -LiteralPath $notices -Destination $stage -Recurse
Copy-Item -LiteralPath (Join-Path $sim 'install.bat') -Destination (Join-Path $panel 'Install SimPilot Link.bat')
foreach ($item in 'build.ps1', 'package.xml', 'PackageDefinitions', 'PackageSources') {
  Copy-Item -LiteralPath (Join-Path $sim $item) -Destination $panel -Recurse
}

$readme = @'
SimPilot for PC
===============

Open the "SimPilot for PC" folder after choosing Extract All.

1. Double-click "SimPilot Bridge" (SimPilot Bridge.exe) and leave its window open while you fly.
   - If Windows says "Windows protected your PC": click "More info", then "Run anyway".
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

Not connecting?
- Windows: Settings > Network & internet > Wi-Fi (or Ethernet) > your home network > Private network.
- If the firewall prompt was cancelled: Windows Security > Firewall & network protection >
  Allow an app through firewall > Change settings. Tick Private for Node.js JavaScript Runtime.
- iPad: Settings > Privacy > Local Network > switch SimPilot EFB on.
- Avoid guest networks. In Settings > Bridge, try the PC's Wi-Fi or Ethernet address shown
  in the bridge window, rather than a VPN or virtual adapter's address.
- If selecting text pauses the bridge window, press Esc to resume.

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
