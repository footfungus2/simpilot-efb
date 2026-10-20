#!/usr/bin/env bash
# Rebuild the app and offer it to the iPad over Wi-Fi for a one-tap TrollStore update (keeps app data).
#
#   ./scripts/dev-install.sh        build + (re)start the local install page
#   ./scripts/dev-install.sh stop   stop the install page server
#
# On the iPad, open the printed http://<mac-ip>:8090 page once and "Add to Home Screen".
# After each rebuild, tap "Install update" there; TrollStore installs it over the old version.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-8090}"
DIST="$ROOT/ios/build/dist"
PIDFILE="$DIST/.server.pid"

stop_server() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill "$(cat "$PIDFILE")" && echo "Stopped install page server."
  fi
  rm -f "$PIDFILE"
}

if [ "${1:-}" = "stop" ]; then stop_server; exit 0; fi

"$ROOT/scripts/build-ipa.sh"

IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo localhost)"
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DIST"
cp "$ROOT/SimPilotEFB.ipa" "$DIST/SimPilotEFB.ipa"

# TrollStore installs from a URL via its apple-magnifier:// scheme; the ?v= stops a cached IPA being reused.
IPA_URL="http://$IP:$PORT/SimPilotEFB.ipa?v=$STAMP"
INSTALL="apple-magnifier://install?url=$(python3 -I -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$IPA_URL")"
cat > "$DIST/index.html" <<HTML
<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="apple-mobile-web-app-capable" content="yes">
<title>SimPilot EFB dev</title>
<style>
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#22252B;color:#fff;
font:17px -apple-system,system-ui,sans-serif}
.card{background:#2B2E34;border:1px solid #3A3D44;border-radius:16px;padding:28px 32px;max-width:420px;text-align:center}
h1{font-size:22px;margin:0 0 6px} p{color:#9EA3AB;margin:4px 0 22px}
a.btn{display:block;background:#2F6FE4;color:#fff;text-decoration:none;font-weight:600;padding:16px;border-radius:12px}
small{display:block;margin-top:16px;color:#6B7079}
</style></head><body><div class="card">
<h1>SimPilot EFB</h1><p>Build $STAMP</p>
<a class="btn" href="$INSTALL">Install update in TrollStore</a>
<small>Reload this page after each rebuild. Mac: $IP</small>
</div></body></html>
HTML

stop_server
python3 -I -m http.server "$PORT" --bind 0.0.0.0 --directory "$DIST" >/dev/null 2>&1 &
echo $! > "$PIDFILE"

echo
echo "Ready. On the iPad (same Wi-Fi) open:  http://$IP:$PORT"
echo "Tap 'Install update in TrollStore'. If macOS asks whether Python may accept incoming connections, click Allow."
