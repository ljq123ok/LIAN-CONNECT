#!/usr/bin/env bash

set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS_ROOT="${DEPS_ROOT:-$APP_ROOT/.deps}"
MIHOMO_REPO='https://github.com/MetaCubeX/mihomo.git'
MIHOMO_COMMIT='8d7100815edf517bbf9c3e615e604db3a5963706'
GVISOR_REPO='https://github.com/MetaCubeX/gvisor.git'
GVISOR_COMMIT='5683e078dbc4b203062aff64a6c07b52c5a01d93'
TOOLCHAIN_REPO='https://github.com/binku87/tailscale-harmony.git'
TOOLCHAIN_COMMIT='9d20b15855b8bf263fe51691b955dd8b18823c6b'

clone_pinned() {
  local repo="$1"
  local commit="$2"
  local target="$3"

  if [ -e "$target" ]; then
    if [ ! -d "$target/.git" ]; then
      printf 'ERROR existing path is not a Git checkout: %s\n' "$target" >&2
      exit 1
    fi
    if [ "$(git -C "$target" rev-parse HEAD)" != "$commit" ]; then
      printf 'ERROR checkout is not pinned to %s: %s\n' "$commit" "$target" >&2
      exit 1
    fi
    return
  fi

  git clone --filter=blob:none --no-checkout "$repo" "$target"
  git -C "$target" checkout --detach "$commit"
}

mkdir -p "$DEPS_ROOT"
clone_pinned "$MIHOMO_REPO" "$MIHOMO_COMMIT" "$DEPS_ROOT/mihomo"
clone_pinned "$GVISOR_REPO" "$GVISOR_COMMIT" "$DEPS_ROOT/gvisor-ohos"
clone_pinned "$TOOLCHAIN_REPO" "$TOOLCHAIN_COMMIT" "$DEPS_ROOT/tailscale-harmony"

PATCH="$APP_ROOT/patches/gvisor-openharmony.patch"
if git -C "$DEPS_ROOT/gvisor-ohos" apply --reverse --check "$PATCH" >/dev/null 2>&1; then
  printf 'gVisor OpenHarmony patch already applied\n'
else
  git -C "$DEPS_ROOT/gvisor-ohos" apply --check "$PATCH"
  git -C "$DEPS_ROOT/gvisor-ohos" apply "$PATCH"
fi

MIHOMO_MEMORY_PATCH="$APP_ROOT/patches/mihomo-memory.patch"
if git -C "$DEPS_ROOT/mihomo" apply --reverse --check "$MIHOMO_MEMORY_PATCH" >/dev/null 2>&1; then
  printf 'mihomo memory patch already applied\n'
else
  git -C "$DEPS_ROOT/mihomo" apply --check "$MIHOMO_MEMORY_PATCH"
  git -C "$DEPS_ROOT/mihomo" apply "$MIHOMO_MEMORY_PATCH"
fi

printf 'Dependencies prepared in %s\n' "$DEPS_ROOT"
printf 'Next: sh %s/scripts/build-toolchain.sh\n' "$DEPS_ROOT/tailscale-harmony"
printf 'Then: sh scripts/build-core.sh\n'
