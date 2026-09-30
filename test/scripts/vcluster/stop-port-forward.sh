#!/usr/bin/env bash
# Stop the port-forward loop started by up.sh and the kubectl it is running.
#
# Usage: test/scripts/vcluster/stop-port-forward.sh <state-dir> <local-port>
set -euo pipefail

STATE_DIR="$1"
PORT="$2"

if [[ -f "${STATE_DIR}/port-forward.pid" ]]; then
  kill "$(cat "${STATE_DIR}/port-forward.pid")" 2>/dev/null || true
  rm -f "${STATE_DIR}/port-forward.pid"
fi
pkill -f "port-forward svc/[^ ]* ${PORT}:443" 2>/dev/null || true
