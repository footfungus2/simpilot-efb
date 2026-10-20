# Builds the SimPilot Link toolbar panel and installs it into the MSFS 2024 Community folder.
# Requirements: Node.js 20+, and the MSFS 2024 SDK (Dev Mode > Help > SDK Installer), which sets MSFS2024_SDK.
# Usage (PowerShell, from this folder):  ./build.ps1

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# 1. Bundle the panel script.
if (-not (Test-Path node_modules)) { npm install --no-audit --no-fund }
npm run build

# 2. Package with the SDK's fspackagetool.
$sdk = $env:MSFS2024_SDK
if (-not $sdk) { $sdk = $env:MSFS_SDK }
if (-not $sdk -or -not (Test-Path "$sdk\Tools\bin\fspackagetool.exe")) {
  throw "MSFS 2024 SDK not found. Install it from Dev Mode (Help > SDK Installer) and reopen PowerShell so MSFS2024_SDK is set."
}
& "$sdk\Tools\bin\fspackagetool.exe" "$PSScriptRoot\package.xml"
if (-not (Test-Path "$PSScriptRoot\Packages\simpilot-link\layout.json")) {
  # fspackagetool sometimes fails the very first build while it initialises; one retry is enough.
  & "$sdk\Tools\bin\fspackagetool.exe" "$PSScriptRoot\package.xml"
}
if (-not (Test-Path "$PSScriptRoot\Packages\simpilot-link\layout.json")) { throw "fspackagetool did not produce Packages\simpilot-link" }

# 3. Find the Community folder from UserCfg.opt (MS Store and Steam keep it in different places).
$cfgCandidates = @(
  "$env:LOCALAPPDATA\Packages\Microsoft.Limitless_8wekyb3d8bbwe\LocalCache\UserCfg.opt",
  "$env:LOCALAPPDATA\Packages\Microsoft.Limitless_8wekyb3d8bbwe\LocalState\UserCfg.opt",
  "$env:APPDATA\Microsoft Flight Simulator 2024\UserCfg.opt"
)
$community = $null
foreach ($cfg in $cfgCandidates) {
  if (Test-Path $cfg) {
    $line = Select-String -Path $cfg -Pattern '^InstalledPackagesPath\s+"(.+)"' | Select-Object -First 1
    if ($line) {
      $community = Join-Path $line.Matches[0].Groups[1].Value 'Community'
      Write-Host "MSFS 2024 settings: $cfg"
      break
    }
  }
}
if (-not $community -or -not (Test-Path $community)) {
  $community = Read-Host "Couldn't find your Community folder. Paste its full path"
}

# 4. Install (replace any previous copy).
$dest = Join-Path $community 'simpilot-link'
if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
Copy-Item -Recurse "$PSScriptRoot\Packages\simpilot-link" $dest
Write-Host "Installed SimPilot Link to $dest" -ForegroundColor Green
if (-not (Test-Path (Join-Path $dest 'layout.json')) -or -not (Test-Path (Join-Path $dest 'manifest.json'))) {
  Write-Host "Warning: layout.json/manifest.json missing in $dest - MSFS won't load the panel." -ForegroundColor Yellow
}
Write-Host "In a Free Flight: toolbar > gear icon > switch 'SimPilot Link' on, then open it."
Write-Host "Restart MSFS (or the flight) and open 'SimPilot Link' from the toolbar once per session."
