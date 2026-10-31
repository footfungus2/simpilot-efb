# Builds the SimPilot Link toolbar panel and installs it into the MSFS 2024 Community2024 folder.
# First installation needs the MSFS 2024 SDK (Settings > Advanced Options > Developer Mode, then Help > SDK Installer). The panel script comes prebuilt in
# SimPilot-for-PC.zip; a source checkout builds it first, which needs Node.js 20+.
# Double-click install.bat ("Install SimPilot Link.bat" in the zip), or run: powershell -ExecutionPolicy Bypass -File .\build.ps1
# To override auto-detection: .\build.ps1 -Community "D:\MSFS\Packages\Community2024"
# -UpdateScript repairs the panel HTML, CSS and script, retaining its compiled toolbar definition without the SDK.
param([string]$Community, [switch]$UpdateScript, [switch]$DiagnosticsOnly)

$ErrorActionPreference = 'Stop'
$assetPaths = @('InGamePanels/SimPilotLink/SimPilotLink.html', 'InGamePanels/SimPilotLink/SimPilotLink.css', 'InGamePanels/SimPilotLink/link.js')

function Assert-PanelAssets([string]$Root) {
  foreach ($entry in $assetManifest.files) {
    $file = Join-Path $Root $entry.path
    if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $entry.sha256) {
      throw "Panel file verification failed: $file. Download and extract the complete repair again."
    }
  }
}

function Write-LinkReport([string]$Folder, [string]$Phase, [switch]$Append) {
  $report = Join-Path $PSScriptRoot 'SimPilot-Link-diagnostics.log'
  $lines = [System.Collections.Generic.List[string]]::new()
  $lines.Add("SimPilot Link diagnostics - $Phase - $([DateTime]::UtcNow.ToString('o'))")
  $lines.Add("Installed package: $(Join-Path $Folder 'simpilot-link')")
  try {
    $expected = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'PackageSources\panel-assets.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $lines.Add("Supplied panel build: $($expected.buildId)")
  } catch { $expected = $null; $lines.Add('Supplied panel build manifest unavailable.') }
  foreach ($path in $assetPaths) {
    $file = Join-Path $Folder ('simpilot-link/html_ui/' + $path)
    try { $hash = if (Test-Path -LiteralPath $file -PathType Leaf) { (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash } else { 'MISSING' } }
    catch { $hash = 'UNREADABLE' }
    $lines.Add("SHA256 $path : $hash")
    $match = @($expected.files | Where-Object { $_.path -ceq $path })
    if ($match.Count -eq 1) { $lines.Add("Expected SHA256: $($match[0].sha256); matches installed: $($hash -ieq $match[0].sha256)") }
  }
  try {
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 8386 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique)
    if ($listeners.Count -eq 0) { $lines.Add('No listener found on port 8386.') }
    foreach ($listener in $listeners) {
      $process = Get-CimInstance Win32_Process -Filter "ProcessId=$listener" -ErrorAction Stop
      $lines.Add("Port 8386 listener PID $listener : $($process.ExecutablePath)")
      # Record only the executable and bridge script, excluding arguments that may contain credentials.
      $launch = [regex]::Match([string]$process.CommandLine, '(?i)("[^"]*(?:bridge\.cjs|bridge[/\\](?:src[/\\]index\.ts|dist[/\\]index\.js))"|\S*(?:bridge\.cjs|bridge[/\\](?:src[/\\]index\.ts|dist[/\\]index\.js)))')
      if ($launch.Success) {
        $lines.Add("Bridge launch: $($process.ExecutablePath) $($launch.Value)")
      }
    }
  } catch { $lines.Add('Could not inspect the port owner: ' + $_.Exception.Message) }
  try {
    $status = Invoke-RestMethod 'http://127.0.0.1:8386/api/status' -TimeoutSec 3 -ErrorAction Stop
    if ($null -eq $status.sim -or $null -eq $status.link) { throw 'The port answered with an unexpected status response.' }
    $lines.Add("Simulator connected: $($status.sim.connected); chart link connected: $($status.link.connected); last seen ms: $($status.link.lastSeenMs)")
    if ($status.bridge) {
      $lines.Add("Bridge identity: $($status.bridge.name) $($status.bridge.version); build $($status.bridge.buildId); protocol $($status.bridge.linkProtocol); port $($status.bridge.port)")
    }
    try {
      Invoke-RestMethod 'http://127.0.0.1:8386/api/status' -Headers @{ Origin = 'coui://html_ui' } -TimeoutSec 3 -ErrorAction Stop | Out-Null
      $lines.Add('Server accepted the in-sim Origin header (this does not test Coherent itself).')
    } catch { $lines.Add('Server Origin check: ' + $_.Exception.Message) }
    $logs = Invoke-RestMethod 'http://127.0.0.1:8386/api/diagnostics' -TimeoutSec 3 -ErrorAction Stop
    foreach ($entry in @($logs.entries | Select-Object -Last 60)) {
      $message = [string]$entry.message
      $lines.Add("$($entry.time) $($entry.level) $($entry.scope): " + $message.Substring(0, [Math]::Min(500, $message.Length)))
    }
  } catch { $lines.Add('Bridge probe: ' + $_.Exception.Message) }
  $lines.Add('For a stuck panel, also record its displayed build/startup/last-request rows and the first Coherent console error.')
  $lines.Add('Matching installed files do not prove that MSFS loaded them; compare the displayed panel build after restarting MSFS.')
  $lines.Add('')
  try {
    if ($Append) { Add-Content -LiteralPath $report -Value $lines -Encoding UTF8 }
    else { Set-Content -LiteralPath $report -Value $lines -Encoding UTF8 }
    Write-Host "Diagnostic report: $report (review before sharing)"
  } catch { Write-Warning "Could not save the diagnostic report: $($_.Exception.Message)" }
}

try {
Set-Location $PSScriptRoot
if (-not $DiagnosticsOnly) {
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

$assetManifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'PackageSources\panel-assets.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($assetManifest.buildId) -or @($assetManifest.files).Count -ne $assetPaths.Count) {
  throw 'The panel asset manifest is incomplete. Download and extract the full package again.'
}
foreach ($path in $assetPaths) {
  $entries = @($assetManifest.files | Where-Object { $_.path -ceq $path -and $_.sha256 -match '^[a-fA-F0-9]{64}$' })
  if ($entries.Count -ne 1) { throw "Invalid panel asset manifest entry: $path" }
}
Assert-PanelAssets (Join-Path $PSScriptRoot 'PackageSources\html_ui')
Write-Host "Panel build: $($assetManifest.buildId)"
}

function Wait-SimClosed([int]$Seconds) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while (Get-Process -Name 'FlightSimulator2024' -ErrorAction SilentlyContinue) {
    if ((Get-Date) -gt $deadline) { return $false }
    Start-Sleep -Seconds 2
  }
  return $true
}
if (-not $DiagnosticsOnly -and (Get-Process -Name 'FlightSimulator2024' -ErrorAction SilentlyContinue)) {
  Write-Host 'MSFS 2024 is open. Close it now before updating the panel. Waiting...' -ForegroundColor Yellow
  if (-not (Wait-SimClosed 300)) { throw 'MSFS 2024 is still open. Close it, then run this installer again.' }
}

# 2. Find InstalledPackagesPath in UserCfg.opt (MS Store and Steam keep it in different places).
Write-Host "== 2/4 Finding the MSFS 2024 package folder" -ForegroundColor Cyan
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

  $candidates = @()
  foreach ($cfg in $cfgCandidates | Select-Object -Unique) {
    if (-not (Test-Path -LiteralPath $cfg)) { continue }
    $line = Select-String -LiteralPath $cfg -Pattern '^\s*InstalledPackagesPath\s+"([^"]+)"' | Select-Object -First 1
    if (-not $line) { continue }
    $packagesPath = $line.Matches[0].Groups[1].Value.Trim()
    if (Test-Path -LiteralPath $packagesPath) {
      $existing = @('Community2024', 'Community') | ForEach-Object { Join-Path $packagesPath $_ } | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'simpilot-link') }
      if (@($existing).Count) { $candidates += $existing }
      elseif (-not $UpdateScript -and -not $DiagnosticsOnly) { $candidates += Join-Path $packagesPath 'Community2024' }
    }
  }
  $candidates = @($candidates | Select-Object -Unique)
  if ($candidates.Count -eq 1) { $community = $candidates[0] }
  elseif ($candidates.Count -gt 1) {
    Write-Host 'More than one SimPilot Link package location was found:' -ForegroundColor Yellow
    $candidates | ForEach-Object { Write-Host "  $_" }
    throw 'Choose the active folder explicitly: run build.ps1 -Community "full path to Community2024" with the same repair or diagnostic option.'
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
    if ($leaf -ieq 'Community2024' -or $leaf -ieq 'Community') { $community = $selected }
    elseif ($leaf -ieq 'simpilot-link') { $community = Split-Path -Parent $selected }
    else { $community = Join-Path $selected 'Community2024' }
  }
}

if (-not $community) { throw 'No MSFS 2024 package folder selected. Run Install SimPilot Link again and choose the Packages folder.' }
$community = [System.IO.Path]::GetFullPath($community)
$packagesPath = Split-Path -Parent $community
if (-not (Test-Path -LiteralPath $packagesPath)) {
  throw "Packages folder not found: $packagesPath. Run Install SimPilot Link again and choose the folder containing Community2024."
}
if (-not $DiagnosticsOnly -and -not (Test-Path -LiteralPath $community)) {
  New-Item -ItemType Directory -Path $community -Force | Out-Null
}

Write-LinkReport $community $(if ($DiagnosticsOnly) { 'Current installation' } else { 'Before installation' })
if ($DiagnosticsOnly) { return }

if (-not $UpdateScript) {
# 3. Package with the SDK's fspackagetool.
Write-Host "== 3/4 Packaging with the MSFS 2024 SDK" -ForegroundColor Cyan
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
$started = Get-Date
for ($attempt = 0; $attempt -lt 2; $attempt++) {
  if (Test-Path -LiteralPath $built) { Remove-Item -LiteralPath $built -Recurse -Force }
  & "$sdk\Tools\bin\fspackagetool.exe" "$PSScriptRoot\package.xml" -nopause
  # The output was deleted above, so these files mean this run built it (the tool's exit code isn't reliable).
  if ((Test-Path -LiteralPath (Join-Path $built 'layout.json')) -and (Test-Path -LiteralPath (Join-Path $built 'manifest.json'))) { break }
  Write-Host "The SDK build didn't finish (exit code $LASTEXITCODE). Waiting for MSFS to close before trying again..." -ForegroundColor Yellow
  if (-not (Wait-SimClosed 120) -or $attempt -eq 1) {
    $buildLog = Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -Include '*.log', '*.txt' -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -ge $started -and $_.FullName -notlike '*\node_modules\*' } |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($buildLog) {
      Write-Host "Last lines of the SDK build log ($($buildLog.FullName)):" -ForegroundColor Yellow
      Get-Content -LiteralPath $buildLog.FullName -Tail 30 | Write-Host
    }
    throw 'The MSFS SDK could not build the chart panel. Make sure MSFS 2024 is closed and the MSFS 2024 SDK is installed, then run this installer again. If it fails again, send a photo of this window.'
  }
}
Write-Host "Built $PSScriptRoot\Packages\simpilot-link"

} else {
  Write-Host '== 3/4 Reusing the installed panel (no SDK build)' -ForegroundColor Cyan
}

# 4. Install (stage and validate the new package before replacing the current copy).
Write-Host "== 4/4 Installing into $community" -ForegroundColor Cyan
$dest = Join-Path $community 'simpilot-link'
$source = if ($UpdateScript) { $dest } else { Join-Path $PSScriptRoot 'Packages\simpilot-link' }
if (-not (Test-Path -LiteralPath (Join-Path $source 'layout.json')) -or -not (Test-Path -LiteralPath (Join-Path $source 'manifest.json'))) {
  if ($UpdateScript) { throw "No complete installed panel found at $dest. Choose the Packages folder containing your existing SimPilot Link installation." }
  throw "Package is incomplete at $source; MSFS needs both layout.json and manifest.json."
}
if ($UpdateScript) {
  $layout = Get-Content -LiteralPath (Join-Path $source 'layout.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $manifest = Get-Content -LiteralPath (Join-Path $source 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $compiled = @(Get-ChildItem -LiteralPath (Join-Path $source 'InGamePanels') -File -Filter '*.spb')
  if ($manifest -isnot [pscustomobject] -or $compiled.Count -eq 0) { throw 'The installed panel is incomplete; no files were replaced.' }
  foreach ($path in $assetPaths) {
    $entries = @($layout.content | Where-Object { ($_.path -replace '\\', '/') -ieq ('html_ui/' + $path) })
    if ($entries.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $source ('html_ui/' + $path)) -PathType Leaf)) {
      throw "The installed panel is missing $path; no files were replaced. Choose the active SimPilot Link installation."
    }
  }
  Write-Host 'Updating the installed panel HTML, CSS and script; no SDK build is needed.'
}
$staging = Join-Path $community '.simpilot-link-staging'
$backup = if ($UpdateScript) {
  Join-Path $packagesPath ('simpilot-link-backup-' + [guid]::NewGuid().ToString('N'))
} else { Join-Path $community '.simpilot-link-backup' }
if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
Copy-Item -LiteralPath $source -Destination $staging -Recurse
if ($UpdateScript) {
  foreach ($path in $assetPaths) {
    $target = Join-Path $staging ('html_ui/' + $path)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('PackageSources/html_ui/' + $path)) -Destination $target -Force
    $updated = Get-Item -LiteralPath $target
    $entry = $layout.content | Where-Object { ($_.path -replace '\\', '/') -ieq ('html_ui/' + $path) }
    $entry.size = $updated.Length
    $entry.date = $updated.LastWriteTimeUtc.ToFileTimeUtc()
  }
  $utf8 = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText((Join-Path $staging 'layout.json'), ($layout | ConvertTo-Json -Depth 20), $utf8)
  if ($null -ne $manifest.total_package_size) {
    $manifest.total_package_size = ([long]($layout.content | Measure-Object -Property size -Sum).Sum).ToString('D20')
    [System.IO.File]::WriteAllText((Join-Path $staging 'manifest.json'), ($manifest | ConvertTo-Json -Depth 20), $utf8)
  }
}
Assert-PanelAssets (Join-Path $staging 'html_ui')
$hadInstalled = Test-Path -LiteralPath $dest
if ($hadInstalled) {
  if (-not $UpdateScript -and (Test-Path -LiteralPath $backup)) { Remove-Item -LiteralPath $backup -Recurse -Force }
  Move-Item -LiteralPath $dest -Destination $backup
}
try {
  Move-Item -LiteralPath $staging -Destination $dest
  Assert-PanelAssets (Join-Path $dest 'html_ui')
} catch {
  if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
  if ($hadInstalled -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $dest }
  throw
}
if (-not $UpdateScript -and (Test-Path -LiteralPath $backup)) { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction Continue }
Write-LinkReport $community 'After verified installation' -Append
Write-Host "Verified SimPilot Link build $($assetManifest.buildId) installed to $dest" -ForegroundColor Green
if ($UpdateScript) { Write-Host "Previous panel saved at $backup" }
Write-Host 'Next: start MSFS 2024 (restart it if it is open; new panels load only when the sim starts).'
Write-Host "In a flight: toolbar > gear icon > switch 'SimPilot Link' on, then open it once per flight."
} catch {
  Write-Host "SimPilot Link was not installed: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
