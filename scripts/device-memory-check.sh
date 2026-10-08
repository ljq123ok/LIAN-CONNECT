#!/usr/bin/env bash

# Sample LIAN's main process and VPN extension memory on a connected device.
# The output is TSV so before/after runs can be compared without extra tools.

set -u
set -o pipefail

HDC_BIN="${HDC_BIN:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-60}"
SAMPLE_COUNT="${SAMPLE_COUNT:-31}"
CONTROLLER_PORT="${CONTROLLER_PORT:-19091}"
OUTPUT_FILE="${OUTPUT_FILE:-}"
APP_PROCESS='com.lianconnect.app'
VPN_PROCESS='com.lianconnect.app:vpn'

if [[ ! -x "$HDC_BIN" ]]; then
  printf 'ERROR hdc executable is unavailable: %s\n' "$HDC_BIN" >&2
  exit 1
fi

TARGETS="$($HDC_BIN list targets 2>/dev/null | sed '/^[[:space:]]*$/d')"
if [[ -z "$TARGETS" ]]; then
  printf 'ERROR no HarmonyOS device is connected\n' >&2
  exit 1
fi

if ! [[ "$SAMPLE_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] ||
  ! [[ "$SAMPLE_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  printf 'ERROR SAMPLE_INTERVAL_SECONDS and SAMPLE_COUNT must be integers\n' >&2
  exit 1
fi

emit() {
  if [[ -n "$OUTPUT_FILE" ]]; then
    printf '%s\n' "$1" | tee -a "$OUTPUT_FILE"
  else
    printf '%s\n' "$1"
  fi
}

process_pid() {
  local process_name="$1"
  local process_list="$2"
  awk -v name="$process_name" '$NF == name { print $2; exit }' <<<"$process_list"
}

status_value() {
  local status_text="$1"
  local key="$2"
  awk -v wanted="$key" '$1 == wanted ":" { print $2; exit }' <<<"$status_text"
}

pss_kb() {
  local pid="$1"
  local rollup
  rollup="$($HDC_BIN shell "cat /proc/$pid/smaps_rollup" 2>/dev/null || true)"
  status_value "$rollup" 'Pss'
}

fd_count() {
  local pid="$1"
  local count
  count="$($HDC_BIN shell "ls /proc/$pid/fd" 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  printf '%s' "${count:-0}"
}

sample_process() {
  local timestamp="$1"
  local role="$2"
  local pid="$3"
  local core_inuse_bytes="$4"
  local connections="$5"
  local controller_ok="$6"
  local status_text rss_kb threads pss row

  if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    printf -v row '%s\t%s\tmissing\t0\t0\t0\t0\t%s\t%s\t%s' \
      "$timestamp" "$role" "$core_inuse_bytes" "$connections" "$controller_ok"
    emit "$row"
    return
  fi

  status_text="$($HDC_BIN shell "cat /proc/$pid/status" 2>/dev/null || true)"
  rss_kb="$(status_value "$status_text" 'VmRSS')"
  threads="$(status_value "$status_text" 'Threads')"
  pss="$(pss_kb "$pid")"
  printf -v row '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$timestamp" "$role" "$pid" "${rss_kb:-0}" "${pss:-0}" "${threads:-0}" \
    "$(fd_count "$pid")" "$core_inuse_bytes" "$connections" "$controller_ok"
  emit "$row"
}

if [[ -n "$OUTPUT_FILE" ]]; then
  : > "$OUTPUT_FILE"
fi

$HDC_BIN fport "tcp:${CONTROLLER_PORT}" tcp:9090 >/dev/null 2>&1 || true
emit $'timestamp\trole\tpid\trss_kb\tpss_kb\tthreads\tfds\tcore_inuse_bytes\tconnections\tcontroller_ok'

for ((sample = 1; sample <= SAMPLE_COUNT; sample++)); do
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  process_list="$($HDC_BIN shell 'ps -ef' 2>/dev/null || true)"
  app_pid="$(process_pid "$APP_PROCESS" "$process_list")"
  vpn_pid="$(process_pid "$VPN_PROCESS" "$process_list")"

  controller_ok=0
  core_inuse_bytes=0
  connections=0
  if curl -fsS --max-time 3 "http://127.0.0.1:${CONTROLLER_PORT}/version" >/dev/null 2>&1; then
    controller_ok=1
    if command -v jq >/dev/null 2>&1; then
      connections_json="$(curl -fsS --max-time 3 "http://127.0.0.1:${CONTROLLER_PORT}/connections" 2>/dev/null || true)"
      connections="$(jq -r '.connections | length // 0' <<<"$connections_json" 2>/dev/null || printf '0')"
      memory_stream="$(curl -sS --max-time 2 "http://127.0.0.1:${CONTROLLER_PORT}/memory" 2>/dev/null || true)"
      core_inuse_bytes="$(jq -rs 'map(select(.inuse != null)) | last | .inuse // 0' <<<"$memory_stream" 2>/dev/null || printf '0')"
    fi
  fi

  sample_process "$timestamp" 'main' "$app_pid" '0' '0' "$controller_ok"
  sample_process "$timestamp" 'vpn' "$vpn_pid" "$core_inuse_bytes" "$connections" "$controller_ok"

  if (( sample < SAMPLE_COUNT )); then
    sleep "$SAMPLE_INTERVAL_SECONDS"
  fi
done
