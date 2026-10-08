#!/usr/bin/env bash

set -u
set -o pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="$APP_ROOT/core/bridge.go"
CONFIG="$APP_ROOT/entry/src/main/ets/services/ConfigService.ets"
VPN_ABILITY="$APP_ROOT/entry/src/main/ets/vpnability/LianVpnAbility.ets"
INDEX_PAGE="$APP_ROOT/entry/src/main/ets/pages/Index.ets"
STATUS_STORE="$APP_ROOT/entry/src/main/ets/services/CoreStatusStore.ets"
BUILD_CORE="$APP_ROOT/scripts/build-core.sh"
PREPARE_CORE_DEPS="$APP_ROOT/scripts/prepare-core-deps.sh"
MIHOMO_PATCH="$APP_ROOT/patches/mihomo-memory.patch"
FAILURES=0

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

START_BODY="$(sed -n '/func LianCoreStart(/,/^}/p' "$BRIDGE")"
if grep -q 'geodata.ClearGeoSiteSourceCache()' <<<"$START_BODY" &&
  ! grep -q 'geodata.ClearGeoSiteCache()' <<<"$START_BODY" &&
  ! grep -q 'geodata.ClearGeoIPCache()' <<<"$START_BODY" &&
  grep -q 'debug.FreeOSMemory()' <<<"$START_BODY"; then
  pass 'Raw Geo source data is released without dropping compiled matchers'
else
  fail 'Geo cleanup still drops compiled matchers or keeps raw source data'
fi

if [[ -f "$MIHOMO_PATCH" ]] &&
  grep -q 'func ClearGeoSiteSourceCache()' "$MIHOMO_PATCH" &&
  grep -q 'mihomo-memory.patch' "$BUILD_CORE" &&
  grep -q 'mihomo-memory.patch' "$PREPARE_CORE_DEPS"; then
  pass 'Pinned mihomo dependency carries the source-cache-only cleanup API'
else
  fail 'Pinned mihomo dependency lacks the source-cache-only cleanup patch'
fi

if grep -Eq -- '-tags[[:space:]]+with_gvisor,with_low_memory' "$BUILD_CORE"; then
  pass 'mihomo core is built with the low-memory buffer profile'
else
  fail 'mihomo core still uses standard relay buffers'
fi

if grep -q 'coreMemoryLimitBytes.*112.*1024.*1024' "$BRIDGE" &&
  grep -q 'coreGCPercent.*50' "$BRIDGE" &&
  grep -q 'debug.SetMemoryLimit(coreMemoryLimitBytes)' "$BRIDGE" &&
  grep -q 'debug.SetGCPercent(coreGCPercent)' "$BRIDGE"; then
  pass 'Go heap uses the 112 MiB soft limit and a more aggressive GC target'
else
  fail 'Go runtime memory tuning is missing or outside the 8 GB device budget'
fi

if grep -q "cache-max-size:.*1024" "$CONFIG" && grep -q "dnsCacheForConfig" "$CONFIG"; then
  pass 'DNS cache is user-controlled and never exceeds 1024 entries per resolver'
else
  fail 'DNS cache keeps the unbounded project default'
fi

POLL_BODY="$(sed -n '/private startPolling(/,/^  }/p' "$VPN_ABILITY")"
if grep -q 'CONNECTION_SNAPSHOT_MIN_INTERVAL_MS = 5000' "$VPN_ABILITY" &&
  grep -q 'CONNECTION_SNAPSHOT_BACKGROUND_INTERVAL_MS = 60000' "$VPN_ABILITY" &&
  grep -q 'now - this.lastConnectionsSnapshotAt >= this.connectionSnapshotIntervalMs' <<<"$POLL_BODY" &&
  grep -q 'connectionSnapshotIntervalMs' "$STATUS_STORE" &&
  grep -q 'CONNECTIONS_VISIBLE_SNAPSHOT_INTERVAL_MS = 5000' "$INDEX_PAGE" &&
  grep -q 'FOREGROUND_SNAPSHOT_INTERVAL_MS = 30000' "$INDEX_PAGE" &&
  grep -q 'BACKGROUND_SNAPSHOT_INTERVAL_MS = 60000' "$INDEX_PAGE" &&
  grep -q '}, 1000);' <<<"$POLL_BODY"; then
  pass 'One-second heartbeat is retained with page-aware connection snapshots'
else
  fail 'Heartbeat or page-aware snapshot cadence does not match the memory plan'
fi

if [[ -x "$APP_ROOT/scripts/device-memory-check.sh" ]]; then
  pass 'Device memory sampler is executable'
else
  fail 'Device memory sampler is missing or not executable'
fi

if (( FAILURES > 0 )); then
  printf 'RESULT FAIL failures=%d\n' "$FAILURES"
  exit 1
fi

printf 'RESULT PASS\n'
