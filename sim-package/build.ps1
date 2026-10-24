# Builds the SimPilot Link toolbar panel and installs it into the MSFS 2024 Community2024 folder.
# Needs the MSFS 2024 SDK (Settings > Advanced Options > Developer Mode, then Help > SDK Installer). The panel script comes prebuilt in
# SimPilot-for-PC.zip; a source checkout builds it first, which needs Node.js 20+.
# Double-click install.bat ("Install SimPilot Link.bat" in the zip), or run: powershell -ExecutionPolicy Bypass -File .\build.ps1
# To override auto-detection: .\build.ps1 -Community "D:\MSFS\Packages\Community2024"
param([string]$Community)

$ErrorActionPreference = 'Stop'
try {
Set-Location $PSScriptRoot
Write-Host "== 1/4 Preparing the panel" -ForegroundColor Cyan
$linkJs = Join-Path $PSScriptRoot 'PackageSources\html_ui\InGamePanels\SimPilotLink\link.js'
$hasNode = [bool](Get-Command node -ErrorAction SilentlyContinue)
if ($hasNode) { $hasNode = [int](node -p "process.versions.node.split('.')[0]") -ge 20 }
if ((Test-Path (Join-Path $PSScriptRoot 'src\link.ts')) -and $hasNode) {
  # Source checkout: bundle the panel script.
  if (-not (Test-Path node_modules)) {
    npm ci --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the panel. Check your internet connection and run the installer again.' }
  }
  npm run build
  if ($LASTEXITCODE -ne 0) { throw 'Could not build the panel. Download SimPilot-for-PC.zip again and use its ready-made files.' }
} elseif (Test-Path $linkJs) {
  Write-Host "Using the ready-made panel files."
} elseif (Test-Path (Join-Path $PSScriptRoot 'src\link.ts')) {
  throw 'This is the source code version, which needs Node.js 20+ to build the panel. Easier: download SimPilot-for-PC.zip from the latest release and run "Install SimPilot Link.bat" from its "Chart panel (optional)" folder.'
} else {
  throw 'The panel files are incomplete. Download SimPilot-for-PC.zip again from the latest release and unzip all of it.'
}

# 2. Package with the SDK's fspackagetool.
Write-Host "== 2/4 Packaging with the MSFS 2024 SDK" -ForegroundColor Cyan
# The SDK installer sets MSFS2024_SDK; a window opened before the install doesn't see it yet, so also read it from
# the registry, then try the default install folders.
$sdkCandidates = @(
  $env:MSFS2024_SDK,
  [Environment]::GetEnvironmentVariable('MSFS2024_SDK', 'User'),
  [Environment]::GetEnvironmentVariable('MSFS2024_SDK', 'Machine'),
  'C:\MSFS 2024 SDK',
  (Join-Path $env:SystemDrive 'MSFS 2024 SDK')
) | Where-Object { $_ }
$sdk = $sdkCandidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'Tools\bin\fspackagetool.exe') } | Select-Object -First 1
if (-not $sdk) {
  throw 'The MSFS 2024 SDK is not installed yet (it is free and needed once to add the panel). In MSFS 2024 open Settings > Advanced Options and switch Developer Mode on, then choose Help > SDK Installer in the menu bar at the top and install it. Then double-click this installer again.'
}
$built = Join-Path $PSScriptRoot 'Packages\simpilot-link'
for ($attempt = 0; $attempt -lt 2; $attempt++) {
  if (Test-Path -LiteralPath $built) { Remove-Item -LiteralPath $built -Recurse -Force }
  & "$sdk\Tools\bin\fspackagetool.exe" "$PSScriptRoot\package.xml"
  if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $built 'layout.json')) -and (Test-Path -LiteralPath (Join-Path $built 'manifest.json'))) { break }
  if ($attempt -eq 1) { throw 'The MSFS SDK could not build the chart panel. Close MSFS, check that the MSFS 2024 SDK is installed, then run this installer again.' }
}
Write-Host "Built $PSScriptRoot\Packages\simpilot-link"

# 3. Find InstalledPackagesPath in UserCfg.opt (MS Store and Steam keep it in different places).
Write-Host "== 3/4 Finding the MSFS 2024 package folder" -ForegroundColor Cyan
$community = $Community
if (-not $community) {
  $cfgCandidates = @()
  if ($env:LOCALAPPDATA) {
    $packages = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path -LiteralPath $packages) {
      $installs = Get-ChildItem -LiteralPath $packages -Directory -Filter 'Microsoft.Limitless_*' -ErrorAction SilentlyContinue
      foreach ($install in $installs) {
        $cfgCandidates += Join-Path $install.FullName 'LocalCache\UserCfg.opt'
        $cfgCandidates += Join-Path $install.FullName 'LocalState\UserCfg.opt'
      }
    }
  }
  if ($env:APPDATA) { $cfgCandidates += Join-Path $env:APPDATA 'Microsoft Flight Simulator 2024\UserCfg.opt' }

  foreach ($cfg in $cfgCandidates | Select-Object -Unique) {
    if (-not (Test-Path -LiteralPath $cfg)) { continue }
    $line = Select-String -LiteralPath $cfg -Pattern '^\s*InstalledPackagesPath\s+"([^"]+)"' | Select-Object -First 1
    if (-not $line) { continue }
    $packagesPath = $line.Matches[0].Groups[1].Value.Trim()
    if (Test-Path -LiteralPath $packagesPath) {
      $community = Join-Path $packagesPath 'Community2024'
      Write-Host "Found MSFS 2024 package location in $cfg"
      break
    }
  }
}

if (-not $community) {
  Write-Host "Couldn't find the sim's package folder. Choose the MSFS Packages folder (the one containing Community2024)." -ForegroundColor Yellow
  $selected = $null
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select the MSFS 2024 Packages folder, or Community2024 if it already exists.'
    $dialog.ShowNewFolderButton = $false
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $selected = $dialog.SelectedPath }
  } catch {
    Write-Host 'Folder picker unavailable; enter the folder path below.' -ForegroundColor Yellow
  }
  if (-not $selected) { $selected = Read-Host 'Enter the MSFS 2024 Packages folder or Community2024 folder' }
  if ($selected) {
    $selected = $selected.TrimEnd([char[]]@('\', '/'))
    $leaf = Split-Path -Leaf $selected
    if ($leaf -ieq 'Community2024') { $community = $selected }
    elseif ($leaf -ieq 'Community') { $community = Join-Path (Split-Path -Parent $selected) 'Community2024' }
    else { $community = Join-Path $selected 'Community2024' }
  }
}

if (-not $community) { throw 'No MSFS 2024 package folder selected. Run Install SimPilot Link again and choose the Packages folder.' }
$community = [System.IO.Path]::GetFullPath($community)
$packagesPath = Split-Path -Parent $community
if (-not (Test-Path -LiteralPath $packagesPath)) {
  throw "Packages folder not found: $packagesPath. Run Install SimPilot Link again and choose the folder containing Community2024."
}
if (-not (Test-Path -LiteralPath $community)) {
  New-Item -ItemType Directory -Path $community -Force | Out-Null
}

# 4. Install (stage and validate the new package before replacing the current copy).
Write-Host "== 4/4 Installing into $community" -ForegroundColor Cyan
$dest = Join-Path $community 'simpilot-link'
$source = Join-Path $PSScriptRoot 'Packages\simpilot-link'
if (-not (Test-Path -LiteralPath (Join-Path $source 'layout.json')) -or -not (Test-Path -LiteralPath (Join-Path $source 'manifest.json'))) {
  throw "Package is incomplete at $source; MSFS needs both layout.json and manifest.json."
}
$staging = Join-Path $community '.simpilot-link-staging'
$backup = Join-Path $community '.simpilot-link-backup'
if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
Copy-Item -LiteralPath $source -Destination $staging -Recurse
if (Test-Path -LiteralPath $dest) {
  if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
  Move-Item -LiteralPath $dest -Destination $backup
}
try {
  Move-Item -LiteralPath $staging -Destination $dest
  if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
} catch {
  if ((Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $dest)) { Move-Item -LiteralPath $backup -Destination $dest }
  throw
}
Write-Host "Installed SimPilot Link to $dest" -ForegroundColor Green
Write-Host 'Next: start MSFS 2024 (restart it if it is open; new panels load only when the sim starts).'
Write-Host "In a flight: toolbar > gear icon > switch 'SimPilot Link' on, then open it once per flight."
} catch {
  Write-Host "SimPilot Link was not installed: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
