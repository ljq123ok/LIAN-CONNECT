#!/usr/bin/env bash

set -u
set -o pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INDEX="$APP_ROOT/entry/src/main/ets/pages/Index.ets"
SETTINGS="$APP_ROOT/entry/src/main/ets/pages/SettingsPage.ets"
LATENCY="$APP_ROOT/entry/src/main/ets/services/LatencyTester.ets"
CONFIG="$APP_ROOT/entry/src/main/ets/services/ConfigService.ets"
DNS_PAGE="$APP_ROOT/entry/src/main/ets/pages/DnsPage.ets"
VPN_ABILITY="$APP_ROOT/entry/src/main/ets/vpnability/LianVpnAbility.ets"
FAILURES=0

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

if ! grep -q "import { MockData }" "$INDEX" &&
  ! grep -q 'MockData\.' "$INDEX"; then
  pass 'Production state does not start with demo nodes or diagnostics'
else
  fail 'Production state still exposes MockData as real VPN data'
fi

if grep -q 'mihomo.*gVisor' "$SETTINGS" &&
  ! grep -q 'sing-box / libbox' "$SETTINGS"; then
  pass 'Settings identifies the actual embedded core'
else
  fail 'Settings still identifies the wrong proxy core'
fi

if ! grep -q '122 ms' "$INDEX" &&
  grep -q 'private async testConnection' "$INDEX" &&
  grep -q 'LatencyTester.testProxy' "$INDEX"; then
  pass 'Settings connectivity test uses a real proxy URL test'
else
  fail 'Settings connectivity test still returns a fabricated success'
fi

if grep -q "pasteboard" "$INDEX" &&
  grep -q "picker" "$INDEX" &&
  grep -q 'private async copyDiagnostics' "$INDEX" &&
  grep -q 'private async exportDiagnostics' "$INDEX" &&
  grep -q 'private clearDiagnostics' "$INDEX"; then
  pass 'Diagnostic copy, export and clear actions have real implementations'
else
  fail 'Diagnostic actions are still status-text placeholders'
fi

if grep -q 'static async testProxy' "$LATENCY" &&
  grep -q '/proxies/' "$LATENCY" &&
  ! grep -q 'LatencyTester.test(link)' "$INDEX"; then
  pass 'Node latency uses mihomo protocol-aware URL testing'
else
  fail 'Node latency still tests only the server TCP port'
fi

if grep -q 'dnsMode: string' "$CONFIG" &&
  grep -q 'dnsCache: boolean' "$CONFIG" &&
  grep -q 'fakeIp: boolean' "$CONFIG" &&
  grep -q 'sniff: boolean' "$CONFIG" &&
  grep -q 'onSettingsChange' "$DNS_PAGE"; then
  pass 'DNS controls are passed into generated mihomo configuration'
else
  fail 'DNS controls are still detached from generated configuration'
fi

if grep -q 'networkRecover' "$VPN_ABILITY" &&
  grep -q 'failClosed' "$VPN_ABILITY" &&
  grep -q 'logLevel' "$CONFIG"; then
  pass 'Runtime behavior consumes recovery, fail-closed and log settings'
else
  fail 'Persisted runtime settings are not consumed by the VPN runtime'
fi

if (( FAILURES > 0 )); then
  printf 'RESULT FAIL failures=%d\n' "$FAILURES"
  exit 1
fi

printf 'RESULT PASS\n'
