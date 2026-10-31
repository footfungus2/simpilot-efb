# Runs in Windows CI; all binaries and installs below are fixtures in a temporary directory.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('simpilot-pc-check-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $scratch 'project with spaces'
$oldSdk = $env:MSFS2024_SDK
$oldLocalAppData = $env:LOCALAPPDATA
$oldAppData = $env:APPDATA
$hostExe = (Get-Process -Id $PID).Path
function Assert-Check($condition, $message) { if (-not $condition) { throw $message } }
function Write-Fixture($relative, $text = 'fixture') {
  $file = Join-Path $fixture $relative
  New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
  [System.IO.File]::WriteAllText($file, $text)
}
$assetPaths = @('InGamePanels/SimPilotLink/SimPilotLink.html', 'InGamePanels/SimPilotLink/SimPilotLink.css', 'InGamePanels/SimPilotLink/link.js')
function Write-AssetManifest {
  $files = @(foreach ($path in $assetPaths) {
    @{ path = $path; sha256 = (Get-FileHash -LiteralPath (Join-Path $fixture ('sim-package/PackageSources/html_ui/' + $path)) -Algorithm SHA256).Hash.ToLowerInvariant() }
  })
  Write-Fixture 'sim-package\PackageSources\panel-assets.json' (@{ buildId = 'test-build'; files = $files } | ConvertTo-Json -Depth 5)
}
try {
  Write-Fixture 'scripts\placeholder'
  Copy-Item (Join-Path $PSScriptRoot 'package-pc.ps1') (Join-Path $fixture 'scripts\package-pc.ps1')
  Write-Fixture 'bridge\dist\app\node.exe'
  Write-Fixture 'bridge\dist\app\bridge.cjs'
  Write-Fixture 'bridge\dist\app\SimPilot Bridge.cmd'
  Write-Fixture 'bridge\dist\app\Source and notices\Node-LICENSE.txt'
  foreach ($path in $assetPaths) { Write-Fixture ('sim-package/PackageSources/html_ui/' + $path) ('new ' + $path) }
  Write-AssetManifest
  foreach ($file in 'install.bat', 'repair.bat', 'diagnose.bat', 'build.ps1', 'package.xml', 'PackageDefinitions\panel.xml') { Write-Fixture ('sim-package\' + $file) }
  $output = Join-Path $scratch 'output with spaces'
  New-Item -ItemType Directory -Path $output -Force | Out-Null
  Set-Content (Join-Path $output 'keep.txt') 'unrelated file'
  & (Join-Path $fixture 'scripts\package-pc.ps1') -OutDir $output
  Assert-Check (Test-Path (Join-Path $output 'keep.txt')) 'Packaging deleted unrelated output files.'
  $expanded = Join-Path $scratch 'expanded'
  Expand-Archive (Join-Path $output 'SimPilot-for-PC.zip') $expanded
  foreach ($file in 'node.exe', 'bridge.cjs', 'SimPilot Bridge.cmd', 'Read me.txt', 'Source and notices\Node-LICENSE.txt', 'Chart panel (optional)\Install SimPilot Link.bat', 'Chart panel (optional)\Repair SimPilot Link.bat', 'Chart panel (optional)\Diagnose SimPilot Link.bat', 'Chart panel (optional)\PackageSources\panel-assets.json') {
    Assert-Check (Test-Path (Join-Path $expanded ('SimPilot for PC\' + $file))) "Missing packaged file: $file"
  }
  Assert-Check (-not (Test-Path (Join-Path $expanded 'SimPilot for PC\SimPilot Bridge.exe'))) 'The modified standalone executable is still included.'
  Assert-Check (@(Get-ChildItem $output -Directory -Filter '.stage-*').Count -eq 0) 'Packaging left its temporary stage behind.'

  # A tiny SDK stand-in proves failed native commands cannot install a stale package.
  $sdk = Join-Path $scratch 'MSFS 2024 SDK'
  $tool = Join-Path $sdk 'Tools\bin\fspackagetool.exe'
  New-Item -ItemType Directory -Path (Split-Path -Parent $tool) -Force | Out-Null
  $source = Join-Path $scratch 'tool.cs'
  @'
using System;
using System.IO;
class Tool {
  static int Main(string[] args) {
    string calls = Environment.GetEnvironmentVariable("SIMPILOT_TEST_SDK_CALLS");
    if (!String.IsNullOrEmpty(calls)) File.AppendAllText(calls, "called\n");
    string mode = Environment.GetEnvironmentVariable("SIMPILOT_TEST_SDK_MODE");
    if (mode == "fail") return 1;
    string dest = Path.Combine(Path.GetDirectoryName(args[0]), "Packages", "simpilot-link");
    Directory.CreateDirectory(dest);
    File.WriteAllText(Path.Combine(dest, "layout.json"), "{}");
    if (mode != "partial") File.WriteAllText(Path.Combine(dest, "manifest.json"), "{}");
    string source = Path.Combine(Path.GetDirectoryName(args[0]), "PackageSources", "html_ui");
    foreach (string file in Directory.GetFiles(source, "*", SearchOption.AllDirectories)) {
      string target = Path.Combine(dest, "html_ui", file.Substring(source.Length + 1));
      Directory.CreateDirectory(Path.GetDirectoryName(target));
      File.Copy(file, target, true);
    }
    return 0;
  }
}
'@ | Set-Content $source
  $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  & $compiler /nologo "/out:$tool" $source
  Assert-Check ($LASTEXITCODE -eq 0) 'Could not build the SDK fixture.'
  $env:MSFS2024_SDK = $sdk
  Copy-Item (Join-Path $repo 'sim-package\build.ps1') (Join-Path $fixture 'sim-package\build.ps1') -Force
  Write-Fixture 'sim-package\Packages\simpilot-link\layout.json' '{}'
  Write-Fixture 'sim-package\Packages\simpilot-link\manifest.json' '{}'
  Write-Fixture 'Community2024\simpilot-link\keep.txt' 'installed version'
  $community = Join-Path $fixture 'Community2024'
  foreach ($mode in 'fail', 'partial') {
    $env:SIMPILOT_TEST_SDK_MODE = $mode
    & $hostExe -NoProfile -File (Join-Path $fixture 'sim-package\build.ps1') -Community $community
    Assert-Check ($LASTEXITCODE -ne 0) "Installer accepted a $mode SDK build."
    Assert-Check (Test-Path (Join-Path $community 'simpilot-link\keep.txt')) 'Failed install replaced the existing panel.'
  }
  $env:SIMPILOT_TEST_SDK_MODE = 'ok'
  & $hostExe -NoProfile -File (Join-Path $fixture 'sim-package\build.ps1') -Community $community
  Assert-Check ($LASTEXITCODE -eq 0) 'Fresh panel install failed.'
  Assert-Check (Test-Path (Join-Path $community 'simpilot-link\manifest.json')) 'Fresh panel is missing its manifest.'
  Assert-Check (-not (Test-Path (Join-Path $community 'simpilot-link\keep.txt'))) 'Fresh panel did not replace the old version.'

  # Repairs replace the whole verified web asset set without the SDK, retaining the compiled toolbar.
  $installed = Join-Path $community 'simpilot-link'
  $scriptPath = 'html_ui/InGamePanels/SimPilotLink/link.js'
  $compiledPath = 'InGamePanels/SimPilotLink.spb'
  $stylePath = 'html_ui/InGamePanels/SimPilotLink/keep.css'
  foreach ($path in $assetPaths) { Write-Fixture ('Community2024/simpilot-link/html_ui/' + $path) ('old ' + $path) }
  Write-Fixture ('Community2024\simpilot-link\' + $compiledPath) 'compiled toolbar'
  Write-Fixture ('Community2024\simpilot-link\' + $stylePath) 'unchanged style'
  $allPaths = @($assetPaths | ForEach-Object { 'html_ui/' + $_ }) + @($compiledPath, $stylePath)
  $content = @(foreach ($path in $allPaths) {
    $file = Get-Item -LiteralPath (Join-Path $installed $path)
    [ordered]@{ path = $path; size = $file.Length; date = $file.LastWriteTimeUtc.ToFileTimeUtc() }
  })
  Write-Fixture 'Community2024\simpilot-link\layout.json' (@{ content = $content } | ConvertTo-Json -Depth 5)
  Write-Fixture 'Community2024\simpilot-link\manifest.json' (@{
    title = 'SimPilot Link'; total_package_size = ([long]($content | Measure-Object -Property size -Sum).Sum).ToString('D20')
  } | ConvertTo-Json)
  $oldLayout = Get-Content -LiteralPath (Join-Path $installed 'layout.json') -Raw
  $env:SIMPILOT_TEST_SDK_MODE = 'fail'
  $sdkCalls = Join-Path $scratch 'repair-sdk-calls.txt'
  $env:SIMPILOT_TEST_SDK_CALLS = $sdkCalls
  & $hostExe -NoProfile -File (Join-Path $fixture 'sim-package\build.ps1') -Community $community -UpdateScript
  Assert-Check ($LASTEXITCODE -eq 0) 'Repair failed despite a complete existing panel.'
  Assert-Check (-not (Test-Path -LiteralPath $sdkCalls)) 'Repair invoked the SDK.'
  foreach ($path in $assetPaths) {
    $newFile = Get-Item -LiteralPath (Join-Path $installed ('html_ui/' + $path))
    $expected = Get-FileHash -LiteralPath (Join-Path $fixture ('sim-package/PackageSources/html_ui/' + $path)) -Algorithm SHA256
    Assert-Check ((Get-FileHash -LiteralPath $newFile.FullName -Algorithm SHA256).Hash -ceq $expected.Hash) "Repair did not install the expected bytes: $path"
  }
  Assert-Check ((Get-Content -LiteralPath (Join-Path $installed $compiledPath) -Raw) -ceq 'compiled toolbar') 'Repair changed the compiled toolbar.'
  Assert-Check ((Get-Content -LiteralPath (Join-Path $installed $stylePath) -Raw) -ceq 'unchanged style') 'Repair changed unrelated assets.'
  $updatedLayout = Get-Content -LiteralPath (Join-Path $installed 'layout.json') -Raw | ConvertFrom-Json
  foreach ($path in $assetPaths) {
    $newFile = Get-Item -LiteralPath (Join-Path $installed ('html_ui/' + $path))
    $entry = @($updatedLayout.content | Where-Object path -eq ('html_ui/' + $path))
    Assert-Check ($entry.Count -eq 1 -and $entry[0].size -eq $newFile.Length -and $entry[0].date -eq $newFile.LastWriteTimeUtc.ToFileTimeUtc()) "Repair left stale layout metadata: $path"
  }
  $oldEntries = ($oldLayout | ConvertFrom-Json).content
  foreach ($path in $compiledPath, $stylePath) {
    $before = $oldEntries | Where-Object path -eq $path | ConvertTo-Json -Compress
    $after = $updatedLayout.content | Where-Object path -eq $path | ConvertTo-Json -Compress
    Assert-Check ($before -ceq $after) "Repair changed unrelated layout metadata: $path"
  }
  $manifest = Get-Content -LiteralPath (Join-Path $installed 'manifest.json') -Raw | ConvertFrom-Json
  $expectedSize = ([long]($updatedLayout.content | Measure-Object -Property size -Sum).Sum).ToString('D20')
  Assert-Check ($manifest.title -ceq 'SimPilot Link' -and $manifest.total_package_size -ceq $expectedSize) 'Repair did not preserve manifest data and update its package size.'
  $backups = @(Get-ChildItem -LiteralPath $fixture -Directory -Filter 'simpilot-link-backup-*')
  Assert-Check ($backups.Count -eq 1) 'Repair did not retain its backup outside Community2024.'
  Assert-Check ((Get-Content -LiteralPath (Join-Path $backups[0].FullName $scriptPath) -Raw) -ceq ('old ' + ($scriptPath -replace '^html_ui/', ''))) 'Repair backup lost the original script.'
  Assert-Check ((Get-Content -LiteralPath (Join-Path $backups[0].FullName 'layout.json') -Raw) -ceq $oldLayout) 'Repair backup changed the original layout.'
  Assert-Check (@(Get-ChildItem -LiteralPath $community -Directory -Filter '*backup*').Count -eq 0) 'Repair left a duplicate backup panel inside Community2024.'
  $report = Get-Content -LiteralPath (Join-Path $fixture 'sim-package\SimPilot-Link-diagnostics.log') -Raw
  Assert-Check ($report.Contains('SHA256') -and $report.Contains($installed) -and $report.Contains('After verified installation')) 'Repair did not record installed hashes and path.'

  # Corrupted supplied bytes fail before replacing the installed package.
  $beforeHash = (Get-FileHash -LiteralPath (Join-Path $installed $scriptPath) -Algorithm SHA256).Hash
  Write-Fixture ('sim-package/PackageSources/' + $scriptPath) 'corrupted download'
  & $hostExe -NoProfile -File (Join-Path $fixture 'sim-package\build.ps1') -Community $community -UpdateScript
  Assert-Check ($LASTEXITCODE -ne 0) 'Repair accepted a payload that did not match its hash manifest.'
  Assert-Check ((Get-FileHash -LiteralPath (Join-Path $installed $scriptPath) -Algorithm SHA256).Hash -ceq $beforeHash) 'Corrupted payload changed the installed script.'
  Write-Fixture ('sim-package/PackageSources/' + $scriptPath) 'fixture-v2'
  Write-AssetManifest

  # A failed readback from the actual installed path must roll the replacement back.
  $env:SIMPILOT_TEST_INSTALLED_JS = Join-Path $installed $scriptPath
  $wrapper = Join-Path $scratch 'verify-failure.ps1'
  @'
function Get-FileHash([string]$LiteralPath, [string]$Algorithm) {
  if ([System.IO.Path]::GetFullPath($LiteralPath) -eq [System.IO.Path]::GetFullPath($env:SIMPILOT_TEST_INSTALLED_JS) -and (Get-Content -LiteralPath $LiteralPath -Raw) -ceq 'fixture-v2') {
    return [pscustomobject]@{ Hash = ('0' * 64) }
  }
  Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm
}
& $args[0] -Community $args[1] -UpdateScript
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $wrapper
  & $hostExe -NoProfile -File $wrapper (Join-Path $fixture 'sim-package\build.ps1') $community
  Assert-Check ($LASTEXITCODE -ne 0) 'Repair ignored a failed installed-file verification.'
  Assert-Check ((Get-FileHash -LiteralPath (Join-Path $installed $scriptPath) -Algorithm SHA256).Hash -ceq $beforeHash) 'Failed installed verification did not restore the old script.'
  Assert-Check ((Get-Content -LiteralPath (Join-Path $installed 'layout.json') -Raw) -ceq ($updatedLayout | ConvertTo-Json -Depth 20)) 'Failed installed verification did not restore the old layout.'

  # Diagnostic mode is read-only, even without a valid repair payload.
  Write-Fixture 'sim-package\PackageSources\panel-assets.json' '{malformed'
  & $hostExe -NoProfile -File (Join-Path $fixture 'sim-package\build.ps1') -Community $community -DiagnosticsOnly
  Assert-Check ($LASTEXITCODE -eq 0) 'Diagnostic mode required repair assets or the SDK.'
  Assert-Check ((Get-FileHash -LiteralPath (Join-Path $installed $scriptPath) -Algorithm SHA256).Hash -ceq $beforeHash) 'Diagnostic mode changed installed bytes.'
  Write-AssetManifest

  Write-Fixture 'Community2024\simpilot-link\layout.json' '{malformed'
  & $hostExe -NoProfile -File (Join-Path $fixture 'sim-package\build.ps1') -Community $community -UpdateScript
  Assert-Check ($LASTEXITCODE -ne 0) 'Repair accepted malformed installed metadata.'
  Assert-Check ((Get-Content -LiteralPath (Join-Path $installed 'layout.json') -Raw) -ceq '{malformed') 'Failed repair changed installed metadata.'
  Assert-Check ((Get-FileHash -LiteralPath (Join-Path $installed $scriptPath) -Algorithm SHA256).Hash -ceq $beforeHash) 'Failed repair changed the installed script.'
  & $hostExe -NoProfile -File (Join-Path $fixture 'sim-package\build.ps1') -Community (Join-Path $fixture 'EmptyCommunity2024') -UpdateScript
  Assert-Check ($LASTEXITCODE -ne 0) 'Repair accepted a missing installed panel.'
  Assert-Check (-not (Test-Path (Join-Path $fixture 'EmptyCommunity2024\simpilot-link'))) 'Failed repair created a partial installed panel.'
  Assert-Check (@(Get-ChildItem -LiteralPath $fixture -Directory -Filter 'simpilot-link-backup-*').Count -eq 1) 'Failed repairs moved or replaced an installed panel.'
  Assert-Check (-not (Test-Path -LiteralPath $sdkCalls)) 'A failed repair invoked the SDK.'
  # Multiple auto-detected installs must be reported rather than choosing one silently.
  $env:LOCALAPPDATA = Join-Path $scratch 'local-app-data'
  $env:APPDATA = Join-Path $scratch 'app-data'
  $config = Join-Path $env:APPDATA 'Microsoft Flight Simulator 2024\UserCfg.opt'
  New-Item -ItemType Directory -Path (Split-Path -Parent $config) -Force | Out-Null
  Set-Content -LiteralPath $config -Value ('InstalledPackagesPath "' + $fixture + '"')
  Write-Fixture 'Community\simpilot-link\keep.txt' 'second install'
  & $hostExe -NoProfile -File (Join-Path $fixture 'sim-package\build.ps1') -DiagnosticsOnly
  Assert-Check ($LASTEXITCODE -ne 0) 'Ambiguous auto-detection selected a package silently.'
  Assert-Check ((Get-Content -LiteralPath (Join-Path $fixture 'Community\simpilot-link\keep.txt') -Raw) -ceq 'second install') 'Ambiguous auto-detection changed another package.'
  Write-Host 'PC packaging and installer checks passed.'
} finally {
  $env:MSFS2024_SDK = $oldSdk
  $env:LOCALAPPDATA = $oldLocalAppData
  $env:APPDATA = $oldAppData
  Remove-Item Env:SIMPILOT_TEST_SDK_MODE -ErrorAction SilentlyContinue
  Remove-Item Env:SIMPILOT_TEST_SDK_CALLS -ErrorAction SilentlyContinue
  Remove-Item Env:SIMPILOT_TEST_INSTALLED_JS -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
