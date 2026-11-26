#!/usr/bin/env bash
# AISTVM: Windows VM power control.
# Runs unattended and prints nothing sensitive.
set -uo pipefail

STATUS_DIR=".aistvm"
CONTROL_FILE="${STATUS_DIR}/control.json"
POWER_FILE="${STATUS_DIR}/power.json"
LOG_FILE="${STATUS_DIR}/power.log"
LOCK_FILE="${STATUS_DIR}/power.lock"
POLL_SECONDS=10
RDP_WAIT_SECONDS=1800
CURRENT_POWER=""
# The last request this machine applied. Restored from its own report, so it
# survives a host restart.
LAST_REQUEST=""

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"${LOG_FILE}"; }

cd "$(dirname "$0")/.." || exit 1
mkdir -p "${STATUS_DIR}"
# The branch the app commits to. Resolved once: the workspace clone is on it,
# and asking the remote for "HEAD" fails when its default branch is unset.
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
LAST_REQUEST=$(sed -n 's/.*"requestId"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9-]*\)".*/\1/p' "${POWER_FILE}" 2>/dev/null)

# Only one watcher per machine: postStartCommand runs on every start.
exec 9>"${LOCK_FILE}"
if command -v flock >/dev/null 2>&1 && ! flock -n 9; then
  log "another power watcher is running; exiting"
  exit 0
fi

# Same lock file as the setup script's publish_status, so the two never push at
# the same time.
publish_power() {
  (
    if command -v flock >/dev/null 2>&1; then flock -x 8; fi
    git add "${POWER_FILE}" >/dev/null 2>&1 || return 0
    git -c user.email=aistvm@users.noreply.github.com -c user.name=AISTVM \
      commit -q -m "AISTVM: power $1" >/dev/null 2>&1 || return 0
    local attempt
    for attempt in 1 2 3 4 5; do
      # The app commits control.json straight to the branch, so this checkout is
      # usually behind. Only this machine writes power.json and status.json, so
      # replaying the local commit cannot conflict with the app's file.
      git pull --rebase -q origin "${BRANCH}" >>"${LOG_FILE}" 2>&1 \
        || git rebase --abort >>"${LOG_FILE}" 2>&1 || true
      git push -q origin "HEAD:refs/heads/${BRANCH}" >>"${LOG_FILE}" 2>&1 && return 0
      sleep 2
    done
    log "power push failed (will retry on the next write)"
  ) 8>"${STATUS_DIR}/git.lock"
}

write_power() {
  # $1 power state, $2 error token, $3 request id
  local tmp
  CURRENT_POWER="$1"
  [ -n "$3" ] && LAST_REQUEST="$3"
  tmp="${POWER_FILE}.tmp.$$"
  printf '{"power":"%s","requestId":"%s","error":"%s","updatedAt":"%s"}\n' \
    "$1" "$3" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${tmp}"
  mv -f "${tmp}" "${POWER_FILE}"
  publish_power "$1"
}

# Empty when the container does not exist yet (Windows is still being created).
container_state() {
  docker inspect -f '{{.State.Running}}' windows 2>/dev/null
}

rdp_ready() {
  # The probe runs in a subshell so the /dev/tcp connect error never reaches the
  # terminal: redirections are applied left to right, so "2>/dev/null" placed
  # after "3<>/dev/tcp/..." is too late to silence the failure itself.
  local reply
  reply=$(
    exec 2>/dev/null
    exec 3<>/dev/tcp/127.0.0.1/3389 || exit 1
    printf '\x03\x00\x00\x13\x0e\xe0\x00\x00\x00\x00\x00\x01\x00\x08\x00\x03\x00\x00\x00' >&3 || exit 1
    timeout 5 head -c 6 <&3 | od -An -tu1 | tr -s ' ' | tr -d '\n'
  ) || return 1
  [ "${reply}" = " 3 0 0 19 14 208" ]
}

# The container is up long before Windows answers, so a start is only reported
# "on" once a complete RDP handshake succeeds twice.
wait_for_windows() {
  local deadline
  deadline=$(( $(date -u +%s) + RDP_WAIT_SECONDS ))
  while [ "$(date -u +%s)" -lt "${deadline}" ]; do
    if rdp_ready; then
      sleep 10
      rdp_ready && return 0
    fi
    sleep 15
  done
  return 1
}

apply_action() {
  local action="$1" request="$2"
  case "${action}" in
    stop)
      write_power stopping "" "${request}"
      docker stop -t 120 windows >>"${LOG_FILE}" 2>&1 || {
        write_power on "docker:stop-failed" "${request}"
        return
      }
      write_power off "" "${request}"
      ;;
    start)
      write_power starting "" "${request}"
      docker start windows >>"${LOG_FILE}" 2>&1 || {
        write_power off "docker:start-failed" "${request}"
        return
      }
      if wait_for_windows; then
        write_power on "" "${request}"
      else
        write_power on "windows:not-answering" "${request}"
      fi
      ;;
    restart)
      write_power restarting "" "${request}"
      docker restart -t 120 windows >>"${LOG_FILE}" 2>&1 || {
        write_power on "docker:restart-failed" "${request}"
        return
      }
      if wait_for_windows; then
        write_power on "" "${request}"
      else
        write_power on "windows:not-answering" "${request}"
      fi
      ;;
  esac
}

# Publish the current state only when the container exists, so a machine that is
# still being created is never reported as switched off.
state=$(container_state)
case "${state}" in
  true) write_power on "" "${LAST_REQUEST}" ;;
  false) write_power off "" "${LAST_REQUEST}" ;;
  *) log "Windows container not created yet; waiting" ;;
esac

while true; do
  if git fetch -q origin "${BRANCH}" >>"${LOG_FILE}" 2>&1; then
    content=$(git show FETCH_HEAD:"${CONTROL_FILE}" 2>/dev/null)
    if [ -n "${content}" ]; then
      action=$(printf '%s' "${content}" | sed -n 's/.*"action"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')
      request=$(printf '%s' "${content}" | sed -n 's/.*"requestId"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9-]*\)".*/\1/p')
      # A request the machine already applied is never replayed, even after a
      # host restart; one the app sent while the host was stopped is still
      # applied once the watcher runs.
      if [ -n "${request}" ] && [ "${request}" != "${LAST_REQUEST}" ]; then
        case "${action}" in
          start|stop|restart)
            log "applying ${action} (${request})"
            apply_action "${action}" "${request}"
            ;;
          *) log "ignoring unknown power action" ;;
        esac
      fi
    fi
  fi
  # Reflect a container that changed outside the app (host restart, crash).
  case "${CURRENT_POWER}" in
    starting|stopping|restarting) ;;
    *)
      state=$(container_state)
      case "${state}" in
        true) [ "${CURRENT_POWER}" = "on" ] || write_power on "" "${LAST_REQUEST}" ;;
        false) [ "${CURRENT_POWER}" = "off" ] || write_power off "" "${LAST_REQUEST}" ;;
      esac
      ;;
  esac
  sleep "${POLL_SECONDS}"
done
