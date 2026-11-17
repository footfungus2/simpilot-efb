#!/usr/bin/env bash
# Build a verified launcher-preview archive on the Mac and run it on the Windows PC without committing.
#
#   ./scripts/launcher-preview.sh        start serving (rerun after edits to print a fresh archive hash)
#   ./scripts/launcher-preview.sh stop   stop serving
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-8091}"
DIST="$ROOT/bridge/dist/launcher-preview"
SERVE="$DIST/serve"
PIDFILE="$DIST/.server.pid"

stop_server() {
  [ -f "$PIDFILE" ] || return 0
  local pid process_args process_pid
  pid="$(cat "$PIDFILE")"
  if [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )); then
    if ! kill -0 "$pid" 2>/dev/null; then
      if ! process_pid="$(ps -p "$pid" -o pid= 2>/dev/null)"; then
        echo "The launcher preview PID could not be verified; left it running and kept its PID file." >&2
        return 1
      fi
      if [[ -z "$process_pid" ]]; then
        rm -f "$PIDFILE"
        return $?
      fi
      echo "The launcher preview server is still running but cannot be signaled; kept its PID file." >&2
      return 1
    fi
    process_args="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$process_args" != *"-m http.server $PORT"* || ( "$process_args" != *"--directory $SERVE"* && "$process_args" != *"--directory $DIST"* ) ]]; then
      echo "The launcher preview PID no longer matches; left it running and kept its PID file." >&2
      return 1
    fi
    if ! kill "$pid"; then
      echo "Could not stop the launcher preview server; kept its PID file." >&2
      return 1
    fi
    echo "Stopped launcher preview server."
  fi
  rm -f "$PIDFILE"
}

if [ "${1:-}" = "stop" ]; then stop_server || exit $?; exit 0; fi
if [[ ! "$PORT" =~ ^[0-9]{1,5}$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "PORT must be an integer from 1 to 65535." >&2
  exit 2
fi

IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo localhost)"
mkdir -p "$DIST" "$SERVE"
STAGE="$(mktemp -d "$DIST/stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp "$ROOT/bridge/launcher/SimPilotBridge.cs" "$ROOT/bridge/launcher/logo.png" "$ROOT/bridge/launcher/simpilot.ico" "$STAGE/"
cp "$ROOT"/bridge/launcher/fonts/*.ttf "$STAGE/"

FONTS=""
for f in "$STAGE"/*.ttf; do FONTS="$FONTS, '$(basename "$f")'"; done
FONTS="${FONTS#, }"
cat > "$STAGE/preview.ps1" <<PS1
& {
\$ErrorActionPreference = 'Stop'
\$dir = Split-Path -Parent \$PSCommandPath
Get-Process 'SimPilot Bridge Preview' -ErrorAction SilentlyContinue | Stop-Process -Force
\$fonts = @($FONTS)
\$fw = Join-Path \$env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
\$exe = Join-Path \$dir 'SimPilot Bridge Preview.exe'
\$fontArgs = \$fonts | ForEach-Object { '/resource:' + (Join-Path \$dir \$_) + ',' + \$_ }
\$compiler = Join-Path \$fw 'csc.exe'
\$icon = Join-Path \$dir 'simpilot.ico'
\$logo = Join-Path \$dir 'logo.png'
\$source = Join-Path \$dir 'SimPilotBridge.cs'
\$compileArgs = @('/nologo', '/target:winexe', '/optimize+', '/platform:anycpu', "/out:\$exe", "/win32icon:\$icon", "/resource:\$logo,logo.png")
\$compileArgs += \$fontArgs
\$compileArgs += @('/r:System.dll', '/r:System.Windows.Forms.dll', '/r:System.Drawing.dll', '/r:System.Web.Extensions.dll', '/r:System.Xaml.dll',
  ('/r:' + (Join-Path \$fw 'WPF\PresentationFramework.dll')), ('/r:' + (Join-Path \$fw 'WPF\PresentationCore.dll')), ('/r:' + (Join-Path \$fw 'WPF\WindowsBase.dll')), \$source)
& \$compiler @compileArgs
if (\$LASTEXITCODE -eq 0) { Start-Process -FilePath \$exe -ArgumentList '--preview'; Write-Host 'Preview open. Space switches the sample state.' -ForegroundColor Green }
else { Write-Host 'The launcher did not compile, see above.' -ForegroundColor Red }
}
PS1

rm -f "$SERVE/preview.zip"
zip -q -j "$SERVE/preview.zip" "$STAGE"/*
HASH="$(shasum -a 256 "$SERVE/preview.zip" | cut -d ' ' -f 1)"
stop_server
python3 -I -m http.server "$PORT" --bind "$IP" --directory "$SERVE" >"$DIST/server.log" 2>&1 &
echo $! > "$PIDFILE"

echo
echo "Serving a launcher preview archive at http://$IP:$PORT. On the Windows PC, paste this command:"
echo
echo "  \$tag = [guid]::NewGuid().ToString('N'); \$zip = Join-Path \$env:TEMP \"SimPilotLauncherPreview-\$tag.zip\"; \$dir = Join-Path \$env:TEMP \"SimPilotLauncherPreview-\$tag\"; Invoke-WebRequest -Uri 'http://$IP:$PORT/preview.zip' -OutFile \$zip -UseBasicParsing; if ((Get-FileHash -LiteralPath \$zip -Algorithm SHA256).Hash -ne '$HASH') { Remove-Item -LiteralPath \$zip -Force; throw 'Preview archive hash mismatch. Stop.' }; Expand-Archive -LiteralPath \$zip -DestinationPath \$dir; Remove-Item -LiteralPath \$zip -Force; & (Join-Path \$dir 'preview.ps1')"
echo
echo "The hash comes from this Mac's terminal and protects the downloaded source and fonts from network changes."
echo "The preview stays in a unique folder under %TEMP%; remove it after closing the preview."
echo "Rerun this script after each edit to build a fresh archive and print its hash. Stop with: ./scripts/launcher-preview.sh stop"
