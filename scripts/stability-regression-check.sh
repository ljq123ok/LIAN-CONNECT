#!/usr/bin/env bash

set -u
set -o pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="$APP_ROOT/core/bridge.go"
CONFIG="$APP_ROOT/entry/src/main/ets/services/ConfigService.ets"
ENTRY="$APP_ROOT/entry/src/main/ets/entryability/EntryAbility.ets"
MODULE="$APP_ROOT/entry/src/main/module.json5"
VPN_ABILITY="$APP_ROOT/entry/src/main/ets/vpnability/LianVpnAbility.ets"
FAILURES=0

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

HEALTH_BODY="$(sed -n '/func LianCoreHealth()/,/^}/p' "$BRIDGE")"
if grep -q 'triggerHealthCheck' <<<"$HEALTH_BODY" && ! grep -q 'runHealthCheck' <<<"$HEALTH_BODY"; then
  pass "N-API health call schedules a non-blocking probe"
else
  fail "N-API health call can block the VPN extension main thread"
fi

CONVERTED_BODY="$(sed -n '/private buildConvertedYaml(/,/private dnsTag(/p' "$CONFIG")"
if grep -q 'appendDns(lines, MANUAL_GROUP' <<<"$CONVERTED_BODY"; then
  pass "AI DNS follows the same selector as AI traffic"
else
  fail "AI DNS and AI traffic can use different exits"
fi

if ! grep -q 'startBackgroundRunning' "$ENTRY" && ! grep -q '"dataTransfer"' "$MODULE"; then
  pass "UI process does not claim a cancellable data-transfer task"
else
  fail "UI process still claims a cancellable data-transfer task"
fi

if ! grep -R -q '\[DEBUG-' "$VPN_ABILITY" "$BRIDGE"; then
  pass "temporary debug instrumentation is absent"
else
  fail "temporary debug instrumentation remains"
fi

if grep -q 'raw.Tun.FileDescriptor = int(fd)' "$BRIDGE" &&
  ! grep -q 'unix.Dup' "$BRIDGE"; then
  pass "HarmonyOS TUN uses the original platform descriptor"
else
  fail "HarmonyOS TUN descriptor is duplicated or not passed through"
fi

RECOVERY_BODY="$(sed -n '/private async recoverCore(/,/^  }/p' "$VPN_ABILITY")"
if grep -q 'this.currentTunFd = -1' <<<"$RECOVERY_BODY" &&
  grep -q 'await this.createTun()' <<<"$RECOVERY_BODY"; then
  pass "self-heal creates a fresh system TUN instead of reusing a closed fd"
else
  fail "self-heal can reuse a closed HarmonyOS TUN descriptor"
fi

CREATE_TUN_BODY="$(sed -n '/private async createTun(/,/^  }/p' "$VPN_ABILITY")"
if grep -q 'this.conn = undefined' <<<"$CREATE_TUN_BODY" &&
  grep -q 'vpnExtension.createVpnConnection(this.context)' <<<"$CREATE_TUN_BODY"; then
  pass "TUN rebuild uses a new VpnConnection object after destroy"
else
  fail "TUN rebuild can reuse a destroyed VpnConnection object"
fi

WATCHDOG_BODY="$(sed -n '/private tickHealthWatchdog(/,/^  }/p' "$VPN_ABILITY")"
if grep -q "detail !== 'tun listener disabled'" <<<"$WATCHDOG_BODY" &&
  grep -q 'TUN_RECOVER_MAX_ATTEMPTS' <<<"$WATCHDOG_BODY" &&
  grep -q 'nextTunRecoverAt' <<<"$WATCHDOG_BODY"; then
  pass "ordinary DNS or node failures cannot trigger a TUN recovery storm"
else
  fail "watchdog can repeatedly rebuild TUN for ordinary network failures"
fi

MAIN_GROUP_BODY="$(sed -n '/func mainGroup()/,/^}/p' "$BRIDGE")"
CURRENT_NODE_BODY="$(sed -n '/func currentOutboundName()/,/^}/p' "$BRIDGE")"
GROUP_OF_BODY="$(sed -n '/func groupOf(/,/^}/p' "$BRIDGE")"
if grep -q 'tunnel.Proxies()\["手动选择"\]' <<<"$MAIN_GROUP_BODY" &&
  grep -q 'largestRoutingGroup' <<<"$MAIN_GROUP_BODY" &&
  grep -q 'g.Adapter().(groupNow)' <<<"$CURRENT_NODE_BODY" &&
  grep -q 'p.Adapter().(groupMembers)' <<<"$GROUP_OF_BODY"; then
  pass "health checks the real routing selector rather than built-in GLOBAL"
else
  fail "health can probe a group that does not carry application traffic"
fi

if (( FAILURES > 0 )); then
  printf 'RESULT FAIL failures=%d\n' "$FAILURES"
  exit 1
fi

printf 'RESULT PASS\n'
