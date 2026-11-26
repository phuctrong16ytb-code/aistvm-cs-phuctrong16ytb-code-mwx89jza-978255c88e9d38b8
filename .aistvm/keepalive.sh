#!/usr/bin/env bash
# AISTVM: best-effort idle-timeout keepalive.
# Prints a line to a pseudo-terminal so GitHub counts it as terminal activity.
set -uo pipefail

INTERVAL=180
STATUS_DIR=".aistvm"
LOG_FILE="${STATUS_DIR}/keepalive.log"
mkdir -p "${STATUS_DIR}"

# Inner mode: this branch runs inside the pty and is the only thing that emits
# output. It is started below, never executed directly by the app.
if [ "${1:-}" = "--loop" ]; then
  while true; do
    printf '[%s] aistvm keepalive\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sleep "${INTERVAL}"
  done
fi

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
QUOTED_SELF="$(printf '%q' "${SELF}")"

# Keep the Windows power watcher running as well. It is started here because the
# keepalive runs on every codespace start, before the long Windows setup, so the
# machine can still be switched off/on when setup itself fails early.
POWER_SCRIPT="$(cd "$(dirname "$0")" && pwd)/power.sh"
if [ -f "${POWER_SCRIPT}" ]; then
  nohup setsid -f bash "${POWER_SCRIPT}" </dev/null >/dev/null 2>&1 || true
fi

# Clear any keepalive left over from a previous start so they do not stack up.
pkill -f "${SELF} --loop" >/dev/null 2>&1 || true

if ! command -v script >/dev/null 2>&1; then
  exit 1
fi

# script(1) allocates the pty; setsid -f detaches it from the caller's process
# group so the devcontainer CLI cannot reap it when postStartCommand returns.
setsid -f script -qfc "bash ${QUOTED_SELF} --loop" /dev/null \
  >>"${LOG_FILE}" 2>&1
exit 0
