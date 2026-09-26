# Third-Party Components

LIAN CONNECT uses the following external projects when building its native VPN
core. Their source is fetched by `scripts/prepare-core-deps.sh`; no third-party
binary is stored in this repository.

## MetaCubeX/mihomo

- Repository: https://github.com/MetaCubeX/mihomo
- Pinned commit: `8d7100815edf517bbf9c3e615e604db3a5963706`
- License: GNU General Public License v3.0

## MetaCubeX/gVisor

- Repository: https://github.com/MetaCubeX/gvisor
- Pinned commit: `5683e078dbc4b203062aff64a6c07b52c5a01d93`
- License: Apache License 2.0
- Local change: `patches/gvisor-openharmony.patch` permits the OpenHarmony VPN
  TUN descriptor to proceed when the platform denies `fstat(2)` with `EPERM` or
  `EACCES`. Other errors remain failures.

## tailscale-harmony and ohos_golang_go

- Repository: https://github.com/binku87/tailscale-harmony
- Pinned commit: `9d20b15855b8bf263fe51691b955dd8b18823c6b`
- Purpose: prepares the OpenHarmony Go toolchain used for the arm64 c-shared
  native library.

Review the license files included by each fetched dependency before
redistributing a compiled HAP.
