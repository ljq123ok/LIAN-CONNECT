#!/usr/bin/env bash

set -u
set -o pipefail

HDC_BIN="${HDC_BIN:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"
CONTROLLER_PORT="${CONTROLLER_PORT:-19091}"
PROXY_PORT="${PROXY_PORT:-17890}"
FAILURES=0

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

if [[ ! -x "$HDC_BIN" ]]; then
  fail "hdc executable is unavailable"
  exit 1
fi

TARGETS="$($HDC_BIN list targets 2>/dev/null | sed '/^[[:space:]]*$/d')"
if [[ -z "$TARGETS" ]]; then
  fail "no HarmonyOS device is connected"
  exit 1
fi
pass "HarmonyOS device is connected"

PROCESS_LIST="$($HDC_BIN shell 'ps -ef | grep com.lianconnect.app | grep -v grep' 2>/dev/null || true)"
if grep -q 'com\.lianconnect\.app$' <<<"$PROCESS_LIST"; then
  pass "LIAN main process is alive"
else
  fail "LIAN main process is missing"
fi

if grep -q 'com\.lianconnect\.app:vpn$' <<<"$PROCESS_LIST"; then
  pass "LIAN VPN extension process is alive"
else
  fail "LIAN VPN extension process is missing"
fi

TUN_STATE="$($HDC_BIN shell 'ifconfig vpn-tun' 2>/dev/null || true)"
if grep -q 'UP .*RUNNING' <<<"$TUN_STATE"; then
  pass "vpn-tun is UP and RUNNING"
else
  fail "vpn-tun is not UP and RUNNING"
fi

$HDC_BIN fport "tcp:${CONTROLLER_PORT}" tcp:9090 >/dev/null 2>&1 || true
$HDC_BIN fport "tcp:${PROXY_PORT}" tcp:7890 >/dev/null 2>&1 || true

VERSION_JSON="$(curl -fsS --max-time 5 "http://127.0.0.1:${CONTROLLER_PORT}/version" 2>/dev/null || true)"
if jq -e '.version | type == "string" and length > 0' >/dev/null 2>&1 <<<"$VERSION_JSON"; then
  pass "mihomo controller is responsive"
else
  fail "mihomo controller is unresponsive"
fi

check_url() {
  local label="$1"
  local url="$2"
  local expected="$3"
  local result
  local code
  local duration

  result="$(curl -sS -o /dev/null \
    --proxy "http://127.0.0.1:${PROXY_PORT}" \
    --connect-timeout 8 --max-time 15 \
    -w '%{http_code} %{time_total}' "$url" 2>/dev/null || true)"
  code="${result%% *}"
  duration="${result#* }"

  if [[ "$code" == "$expected" ]]; then
    pass "${label} returned ${code} in ${duration}s"
  else
    fail "${label} expected HTTP ${expected}, got ${code:-no-response} in ${duration:-unknown}s"
  fi
}

check_url "Baidu" "http://www.baidu.com/" "200"
check_url "Google" "https://www.google.com/generate_204" "204"
check_url "OpenAI API" "https://api.openai.com/v1/models" "401"

if (( FAILURES > 0 )); then
  printf 'RESULT FAIL failures=%d\n' "$FAILURES"
  exit 1
fi

printf 'RESULT PASS\n'
