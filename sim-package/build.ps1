# Builds the SimPilot Link toolbar panel and installs it into the MSFS 2024 Community2024 folder.
# Requirements: Node.js 20+, and the MSFS 2024 SDK (Dev Mode > Help > SDK Installer), which sets MSFS2024_SDK.
# Double-click install.bat, or run: powershell -ExecutionPolicy Bypass -File .\build.ps1
# To override auto-detection: .\build.ps1 -Community "D:\MSFS\Packages\Community2024"
param([string]$Community)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
Write-Host "== 1/4 Building the panel script" -ForegroundColor Cyan
if (-not (Get-Command node -ErrorAction SilentlyContinue) -or [int](node -p "process.versions.node.split('.')[0]") -lt 20) {
  throw 'Node.js 20 or newer is required. Install the LTS version from https://nodejs.org, then run install.bat again.'
}

# 1. Bundle the panel script.
if (-not (Test-Path node_modules)) { npm ci --no-audit --no-fund }
npm run build

# 2. Package with the SDK's fspackagetool.
Write-Host "== 2/4 Packaging with the MSFS 2024 SDK" -ForegroundColor Cyan
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
  Write-Host "Couldn't find UserCfg.opt. Select the folder containing Community2024 (usually the MSFS Packages folder)." -ForegroundColor Yellow
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

if (-not $community) { throw 'No MSFS 2024 package folder selected. Run install.bat again and choose the Packages folder.' }
$community = [System.IO.Path]::GetFullPath($community)
$packagesPath = Split-Path -Parent $community
if (-not (Test-Path -LiteralPath $packagesPath)) {
  throw "Packages folder not found: $packagesPath. Choose the folder containing Community2024, or pass -Community with its full path."
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
Write-Host "In a Free Flight: toolbar > gear icon > switch 'SimPilot Link' on, then open it."
Write-Host "Restart MSFS (or the flight) and open 'SimPilot Link' from the toolbar once per session."
