#!/usr/bin/env bash
# Build the app and prepare the IPA for a trusted local transfer to the iPad.
#
#   ./scripts/dev-install.sh        build and copy the IPA into ios/build/dist
#   ./scripts/dev-install.sh stop   stop an install server left by an older version of this script
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/ios/build/dist"
PIDFILE="$DIST/.server.pid"

stop_server() {
  [ -f "$PIDFILE" ] || return 0
  local pid process_args process_pid
  pid="$(cat "$PIDFILE")"
  if [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )); then
    if ! kill -0 "$pid" 2>/dev/null; then
      if ! process_pid="$(ps -p "$pid" -o pid= 2>/dev/null)"; then
        echo "The old install server PID could not be verified; left it running and kept its PID file." >&2
        return 1
      fi
      if [[ -z "$process_pid" ]]; then
        rm -f "$PIDFILE"
        return $?
      fi
      echo "The old install server is still running but cannot be signaled; kept its PID file." >&2
      return 1
    fi
    process_args="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$process_args" != *"-m http.server "* || "$process_args" != *"--directory $DIST" ]]; then
      echo "The old install server PID no longer matches; left it running and kept its PID file." >&2
      return 1
    fi
    if ! kill "$pid"; then
      echo "Could not stop the old install server; kept its PID file." >&2
      return 1
    fi
    echo "Stopped the old install page server."
  fi
  rm -f "$PIDFILE"
}

if [ "${1:-}" = "stop" ]; then stop_server || exit $?; exit 0; fi

"$ROOT/scripts/build-ipa.sh"
mkdir -p "$DIST"
stop_server
cp "$ROOT/SimPilotEFB.ipa" "$DIST/SimPilotEFB.ipa"

echo
echo "Built: $DIST/SimPilotEFB.ipa"
echo "Transfer it to the iPad with AirDrop, then open it in TrollStore or import it into SideStore."
echo "The former one-tap HTTP install page is disabled because it could install a substituted IPA over Wi-Fi."
