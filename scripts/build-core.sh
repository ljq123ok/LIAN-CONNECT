#!/bin/sh
# Build the embedded mihomo core for HarmonyOS arm64.
#
# Prerequisites:
#   - DevEco Studio installed at /Applications/DevEco-Studio.app
#   - OpenHarmony Go fork built in .deps/tailscale-harmony/toolchain/ohos-go
#     (scripts/build-toolchain.sh in tailscale-harmony)
#   - pinned mihomo and gVisor sources prepared by prepare-core-deps.sh
set -e

APP_ROOT=$(cd "$(dirname -- "$0")/.." && pwd)
DEPS_ROOT="${DEPS_ROOT:-$APP_ROOT/.deps}"
MIHOMO_SRC="${MIHOMO_SRC:-$DEPS_ROOT/mihomo}"
TS_ROOT="${TS_ROOT:-$DEPS_ROOT/tailscale-harmony}"
GVISOR_SRC="${GVISOR_SRC:-$DEPS_ROOT/gvisor-ohos}"
GVISOR_REPLACE="${GVISOR_REPLACE:-../$(basename "$GVISOR_SRC")}"

if [ ! -d "$MIHOMO_SRC" ]; then
  echo "[core] ERROR: mihomo source not found at $MIHOMO_SRC" >&2
  echo "[core] Run: sh scripts/prepare-core-deps.sh" >&2
  exit 1
fi
if [ ! -f "$GVISOR_SRC/go.mod" ]; then
  echo "[core] ERROR: patched gVisor source not found at $GVISOR_SRC" >&2
  echo "[core] Run: sh scripts/prepare-core-deps.sh" >&2
  exit 1
fi
if [ ! -f "$MIHOMO_SRC/$GVISOR_REPLACE/go.mod" ]; then
  echo "[core] ERROR: relative gVisor module path is not reachable from mihomo" >&2
  echo "[core] Set GVISOR_REPLACE to a relative path from $MIHOMO_SRC" >&2
  exit 1
fi
if [ ! -x "$TS_ROOT/toolchain/ohos-go/bin/go" ]; then
  echo "[core] ERROR: OHOS Go toolchain not found" >&2
  echo "[core] Build it with: sh $TS_ROOT/scripts/build-toolchain.sh" >&2
  exit 1
fi
if [ ! -f "$TS_ROOT/scripts/ohos-env.sh" ]; then
  echo "[core] ERROR: tailscale-harmony scripts not found" >&2
  exit 1
fi

MIHOMO_MEMORY_PATCH="$APP_ROOT/patches/mihomo-memory.patch"
if git -C "$MIHOMO_SRC" apply --reverse --check "$MIHOMO_MEMORY_PATCH" >/dev/null 2>&1; then
  echo "[core] mihomo memory patch already applied"
else
  git -C "$MIHOMO_SRC" apply --check "$MIHOMO_MEMORY_PATCH"
  git -C "$MIHOMO_SRC" apply "$MIHOMO_MEMORY_PATCH"
  echo "[core] applied mihomo memory patch"
fi

mkdir -p "$MIHOMO_SRC/lianbridge"
cp "$APP_ROOT/core/bridge.go" "$MIHOMO_SRC/lianbridge/bridge.go"

export ROOT="$TS_ROOT"
. "$TS_ROOT/scripts/ohos-env.sh"

OUT="$MIHOMO_SRC/lianbridge/libmihomo_ohos.so"
cd "$MIHOMO_SRC"
# Keep the replacement relative so Go build metadata cannot leak a workstation path.
go mod edit -replace "github.com/metacubex/gvisor=$GVISOR_REPLACE"
go build -tags with_gvisor,with_low_memory -buildmode=c-shared -trimpath -o "$OUT" ./lianbridge

APP_LIBS="$APP_ROOT/entry/libs/arm64-v8a"
mkdir -p "$APP_LIBS"
cp "$OUT" "$APP_LIBS/libmihomo_ohos.so"
"$OHOS_READELF" -h "$APP_LIBS/libmihomo_ohos.so" | grep -E 'Class|Machine|Type'
if "$OHOS_READELF" -r "$APP_LIBS/libmihomo_ohos.so" | grep -qE 'TPREL'; then
  echo "[core] ERROR: initial-exec TLS relocation found, dlopen will fail" >&2
  exit 1
fi
"$OHOS_BIN/llvm-strip" --strip-unneeded "$APP_LIBS/libmihomo_ohos.so"
ls -lh "$APP_LIBS/libmihomo_ohos.so"
echo "[core] staged $APP_LIBS/libmihomo_ohos.so"
