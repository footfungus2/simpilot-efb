# Runs in Windows CI; all binaries and installs below are fixtures in a temporary directory.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('simpilot-pc-check-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $scratch 'project with spaces'
$oldSdk = $env:MSFS2024_SDK
$hostExe = (Get-Process -Id $PID).Path
function Assert-Check($condition, $message) { if (-not $condition) { throw $message } }
function Write-Fixture($relative, $text = 'fixture') {
  $file = Join-Path $fixture $relative
  New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
  [System.IO.File]::WriteAllText($file, $text)
}
try {
  Write-Fixture 'scripts\placeholder'
  Copy-Item (Join-Path $PSScriptRoot 'package-pc.ps1') (Join-Path $fixture 'scripts\package-pc.ps1')
  Write-Fixture 'bridge\dist\app\SimPilot Bridge.exe'
  Write-Fixture 'bridge\dist\app\Source and notices\Node-LICENSE.txt'
  Write-Fixture 'sim-package\PackageSources\html_ui\InGamePanels\SimPilotLink\link.js'
  foreach ($file in 'install.bat', 'build.ps1', 'package.xml', 'PackageDefinitions\panel.xml') { Write-Fixture ('sim-package\' + $file) }
  $output = Join-Path $scratch 'output with spaces'
  New-Item -ItemType Directory -Path $output -Force | Out-Null
  Set-Content (Join-Path $output 'keep.txt') 'unrelated file'
  & (Join-Path $fixture 'scripts\package-pc.ps1') -OutDir $output
  Assert-Check (Test-Path (Join-Path $output 'keep.txt')) 'Packaging deleted unrelated output files.'
  $expanded = Join-Path $scratch 'expanded'
  Expand-Archive (Join-Path $output 'SimPilot-for-PC.zip') $expanded
  foreach ($file in 'SimPilot Bridge.exe', 'Read me.txt', 'Source and notices\Node-LICENSE.txt', 'Chart panel (optional)\Install SimPilot Link.bat') {
    Assert-Check (Test-Path (Join-Path $expanded ('SimPilot for PC\' + $file))) "Missing packaged file: $file"
  }
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
    string mode = Environment.GetEnvironmentVariable("SIMPILOT_TEST_SDK_MODE");
    if (mode == "fail") return 1;
    string dest = Path.Combine(Path.GetDirectoryName(args[0]), "Packages", "simpilot-link");
    Directory.CreateDirectory(dest);
    File.WriteAllText(Path.Combine(dest, "layout.json"), "{}");
    if (mode != "partial") File.WriteAllText(Path.Combine(dest, "manifest.json"), "{}");
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
  Write-Host 'PC packaging and installer checks passed.'
} finally {
  $env:MSFS2024_SDK = $oldSdk
  Remove-Item Env:SIMPILOT_TEST_SDK_MODE -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
