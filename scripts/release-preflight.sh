#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'FAIL not a Git work tree: %s\n' "$ROOT" >&2
  exit 1
fi

failures=0

fail() {
  printf 'FAIL %s\n' "$1" >&2
  failures=$((failures + 1))
}

pass() {
  printf 'PASS %s\n' "$1"
}

tracked_files="$(git ls-files)"

forbidden_files="$(printf '%s\n' "$tracked_files" | grep -E '^(build-profile\.json5|local\.properties)$|\.(hap|p12|p7b|cer|jks|keystore|pem|key|so|dylib)$' || true)"
if [ -n "$forbidden_files" ]; then
  printf '%s\n' "$forbidden_files" >&2
  fail 'tracked files include signing material, packages, or native binaries'
else
  pass 'no forbidden binary or signing files are tracked'
fi

personal_paths="$(git grep -Il -E '(/Users/[^/]+/|/home/[^/]+/|[A-Za-z]:\\\\Users\\\\[^\\\\]+\\\\)' -- . ':(exclude)scripts/release-preflight.sh' || true)"
if [ -n "$personal_paths" ]; then
  printf '%s\n' "$personal_paths" >&2
  fail 'tracked files contain personal absolute paths'
else
  pass 'no personal absolute paths found'
fi

signing_values="$(git grep -Il -E '(keyPassword|storePassword)[[:space:]]*[:=]' -- . ':(exclude)scripts/release-preflight.sh' || true)"
if [ -n "$signing_values" ]; then
  printf '%s\n' "$signing_values" >&2
  fail 'tracked files contain signing password fields'
else
  pass 'no signing password fields found'
fi

private_keys="$(git grep -Il -E 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' -- . ':(exclude)scripts/release-preflight.sh' || true)"
if [ -n "$private_keys" ]; then
  printf '%s\n' "$private_keys" >&2
  fail 'tracked files contain private keys'
else
  pass 'no private keys found'
fi

device_traces="$(git grep -Il -E 'VOL-AL00|Pura X|callingUid|uid[ =][0-9]{6,}|8BBUT[0-9A-Z]+' -- . ':(exclude)scripts/release-preflight.sh' || true)"
if [ -n "$device_traces" ]; then
  printf '%s\n' "$device_traces" >&2
  fail 'tracked files contain device-specific diagnostic traces'
else
  pass 'no device-specific diagnostic traces found'
fi

personal_emails="$(git grep -Il -E '[A-Za-z0-9._%+-]+@(outlook|gmail|qq|163|126)\.[A-Za-z]{2,}' -- . ':(exclude)scripts/release-preflight.sh' || true)"
if [ -n "$personal_emails" ]; then
  printf '%s\n' "$personal_emails" >&2
  fail 'tracked files contain personal email addresses'
else
  pass 'no personal email addresses found'
fi

share_links="$(git grep -Il -E 'ss://[A-Za-z0-9+/_=-]{12,}|(ssr|vmess|vless|trojan|hysteria2?|tuic)://[A-Za-z0-9%._~:/?#@!$&*+,;=-]{12,}' -- . ':(exclude)scripts/release-preflight.sh' || true)"
if [ -n "$share_links" ]; then
  printf '%s\n' "$share_links" >&2
  fail 'tracked files may contain live proxy share links'
else
  pass 'no credential-bearing proxy share links found'
fi

oversized="$(git ls-files -z | xargs -0 -I{} sh -c 'test -f "$1" && test "$(wc -c < "$1")" -gt 52428800 && printf "%s\n" "$1"' sh {} || true)"
if [ -n "$oversized" ]; then
  printf '%s\n' "$oversized" >&2
  fail 'tracked files exceed 50 MiB'
else
  pass 'no tracked file exceeds 50 MiB'
fi

if (( failures > 0 )); then
  printf 'RESULT FAIL failures=%d\n' "$failures" >&2
  exit 1
fi

printf 'RESULT PASS\n'
