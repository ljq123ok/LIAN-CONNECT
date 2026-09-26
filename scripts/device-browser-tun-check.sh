#!/usr/bin/env bash

set -u
set -o pipefail

HDC_BIN="${HDC_BIN:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"
CONTROLLER_PORT="${CONTROLLER_PORT:-19091}"
DEVICE_LAYOUT="/data/local/tmp/lian-browser-tun-$$.json"
LOCAL_DIR="$(mktemp -d)"
LOCAL_LAYOUT="$LOCAL_DIR/$(basename "$DEVICE_LAYOUT")"
FAILURES=0

cleanup() {
  "$HDC_BIN" shell "rm -f '$DEVICE_LAYOUT'" >/dev/null 2>&1 || true
  rm -rf "$LOCAL_DIR"
}
trap cleanup EXIT

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

iface_bytes() {
  "$HDC_BIN" shell 'ifconfig vpn-tun' 2>/dev/null |
    awk '/RX bytes:/ {gsub(/bytes:/, "", $2); gsub(/bytes:/, "", $4); print $2, $4; exit}'
}

if [[ ! -x "$HDC_BIN" ]]; then
  fail "hdc executable is unavailable"
  exit 1
fi

if ! "$HDC_BIN" list targets 2>/dev/null | grep -q '[^[:space:]]'; then
  fail "no HarmonyOS device is connected"
  exit 1
fi

PROCESS_LIST="$("$HDC_BIN" shell 'ps -ef | grep com.lianconnect.app | grep -v grep' 2>/dev/null || true)"
if grep -q 'com\.lianconnect\.app:vpn$' <<<"$PROCESS_LIST"; then
  pass "LIAN VPN extension is alive"
else
  fail "LIAN VPN extension is missing"
  exit 1
fi

read -r RX_BEFORE TX_BEFORE <<<"$(iface_bytes)"
if [[ -z "${RX_BEFORE:-}" || -z "${TX_BEFORE:-}" ]]; then
  fail "vpn-tun byte counters are unavailable"
  exit 1
fi

"$HDC_BIN" fport "tcp:${CONTROLLER_PORT}" tcp:9090 >/dev/null 2>&1 || true
"$HDC_BIN" shell 'aa force-stop com.huawei.hmos.browser' >/dev/null 2>&1 || true
sleep 1
"$HDC_BIN" shell \
  'aa start -a MainAbility -b com.huawei.hmos.browser -m entry -A ohos.want.action.viewData -U "https://www.google.com/?lian_tun_acceptance=1" -e entity.system.browsable' \
  >/dev/null
sleep 12

"$HDC_BIN" shell "uitest dumpLayout -p '$DEVICE_LAYOUT' >/dev/null 2>&1"
"$HDC_BIN" file recv "$DEVICE_LAYOUT" "$LOCAL_DIR/" >/dev/null

ERROR_COUNT="$(jq '[.. | objects | .attributes? | select(. != null) |
  (.originalText // .text // "") |
  select(test("ERR_SOCKET_NOT_CONNECTED|\u7f51\u7ad9\u6682\u65f6\u65e0\u6cd5\u6253\u5f00|\u7f51\u7ad9\u6682\u65e0\u54cd\u5e94"))] | length' "$LOCAL_LAYOUT")"
RENDER_MARKERS="$(jq '[.. | objects | .attributes? | select(. != null) |
  (.originalText // .text // "") |
  select(. == "Google \u641c\u7d22" or . == "Google" or . == "Google Search")] | length' "$LOCAL_LAYOUT")"

if [[ "$ERROR_COUNT" == "0" ]]; then
  pass "Huawei Browser has no socket-disconnected error page"
else
  fail "Huawei Browser rendered a socket-disconnected error page"
fi

if (( RENDER_MARKERS > 0 )); then
  pass "Huawei Browser rendered the Google page"
else
  fail "Huawei Browser did not expose Google page content"
fi

read -r RX_AFTER TX_AFTER <<<"$(iface_bytes)"
RX_DELTA=$((RX_AFTER - RX_BEFORE))
TX_DELTA=$((TX_AFTER - TX_BEFORE))
if (( RX_DELTA > 10000 && TX_DELTA > 10000 )); then
  pass "vpn-tun carried browser traffic rx_delta=${RX_DELTA} tx_delta=${TX_DELTA}"
else
  fail "vpn-tun browser traffic was too small rx_delta=${RX_DELTA} tx_delta=${TX_DELTA}"
fi

CONNECTIONS="$(curl -fsS --max-time 5 "http://127.0.0.1:${CONTROLLER_PORT}/connections" 2>/dev/null || true)"
GOOGLE_TUN_COUNT="$(jq '[.connections[]? |
  select(.metadata.host == "www.google.com") |
  select(.metadata.type == "Tun" and .metadata.network == "tcp") |
  select(.metadata.sourceIP == "10.6.0.2" and .download > 10000)] | length' <<<"$CONNECTIONS" 2>/dev/null || printf '0')"
if (( GOOGLE_TUN_COUNT > 0 )); then
  pass "mihomo recorded a real Google TCP connection from vpn-tun"
else
  fail "mihomo did not record a usable Google TCP connection from vpn-tun"
fi

if (( FAILURES > 0 )); then
  printf 'RESULT FAIL failures=%d\n' "$FAILURES"
  exit 1
fi

printf 'RESULT PASS\n'
