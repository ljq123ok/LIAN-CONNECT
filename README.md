# LIAN CONNECT v0.02

LIAN CONNECT 是一个面向 HarmonyOS 的原生 VPN 客户端。本仓库发布的是
`v0.02` 测试版源代码；应用清单版本为 `0.0.2`，`versionCode` 为 `2`。

> 当前代码已通过本地构建和稳定性静态回归，但尚未完成当前版本的锁屏、
> 网络切换和数小时连续运行真机验收，因此不能视为稳定版本。

## 1. 基于什么构建

- HarmonyOS Stage 模型、ArkTS 和 `VpnExtensionAbility`
- HarmonyOS SDK 6.1.1（API 24），最低兼容 API 22
- C++ N-API 动态桥接
- Go `c-shared` 原生核心
- [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo)，固定提交
  `8d7100815edf517bbf9c3e615e604db3a5963706`
- [MetaCubeX/gVisor](https://github.com/MetaCubeX/gvisor)，固定提交
  `5683e078dbc4b203062aff64a6c07b52c5a01d93`，应用仓库内的 OpenHarmony
  TUN 最小补丁
- [tailscale-harmony](https://github.com/binku87/tailscale-harmony)，固定提交
  `9d20b15855b8bf263fe51691b955dd8b18823c6b`，用于准备 OpenHarmony Go 工具链

依赖来源、许可证和本地修改见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
本项目整体按 GPL-3.0 发布。

## 2. 项目实现方案

```text
ArkTS UIAbility
    -> VpnExtensionAbility
    -> VpnConnection.create() 创建系统 TUN
    -> C++ N-API bridge
    -> Go libmihomo_ohos.so
    -> mihomo + gVisor TUN
    -> 代理节点或 DIRECT 网络
```

- `VpnConnection.create()` 创建 IPv4 系统级 TUN，系统 DNS 指向 TUN 网关。
- `protectProcessNet()` 让核心自身连接绕开 VPN，避免流量再次进入隧道形成环路。
- TUN 文件描述符通过 N-API 传入 Go/mihomo 核心，原生核心由 `dlopen` 动态加载。
- 支持 Clash/Mihomo YAML、Base64 订阅以及 `ss`、`vmess`、`vless`、
  `trojan`、`hysteria2`、`tuic` 分享链接。
- 支持全局、规则、直连模式，节点选择、连接查看、关闭连接和代理流量统计。
- DNS 使用 `redir-host`，mihomo 接管 `any:53`，加密 DNS 与业务流量使用一致出口。
- UI 进程和 VPN 扩展通过应用沙箱内的 JSON 文件交换运行状态、连接列表和命令。
- 健康检查由 Go 后台异步执行，避免阻塞 VPN 扩展主线程。
- 只有确认 TUN listener 失效时才创建新的 `VpnConnection` 和 TUN fd；普通节点、
  DNS 或上游网络故障不会触发 TUN 重建风暴，自动恢复次数也有上限。

## 3. 可能遇到的问题

- `v0.02` 是测试版，锁屏、网络切换和数小时连续运行尚未完成当前版本的真机验收。
- HarmonyOS 模拟器不能完成 VPN 授权和真实 TUN 数据面验证，必须使用真机。
- GitHub Release 提供经过脱敏检查的 arm64 **未签名 HAP**；它不能直接安装，
  必须使用自己的证书和调试/发布 Profile 签名。仓库不包含任何签名材料。
- 从源码构建时仍需自行准备固定版本依赖、编译原生核心并配置 DevEco 签名。
- 原生核心固定依赖特定 mihomo、gVisor 和工具链提交；升级任一依赖都可能改变
  编译结果或 TUN 行为。
- 厂商自定义 JSON、SIP008、OpenVPN 等未支持格式可能无法导入。
- 某些网络会屏蔽默认测速地址或 DoH，需要在设置中更换测速地址、DNS 或节点。
- 自动恢复只处理明确的 TUN listener 故障。订阅过期、节点失效、DNS 故障或上游
  网络异常可能仍需手动换节点或重连。
- 分应用代理依赖系统包信息权限，普通第三方应用可能无法枚举全部已安装应用；
  不同 HarmonyOS 版本的黑白名单语义仍需真机复核。
- 公开分发编译后的 HAP 时，必须同时满足 GPL-3.0 的对应源码、修改记录和构建输入要求。

## 构建

需要 DevEco Studio、HarmonyOS SDK 6.1.1，以及系统可用的 Git 和 Go：

```bash
# 1. 获取固定版本的 mihomo、gVisor 和工具链仓库，并应用 OpenHarmony 补丁
bash scripts/prepare-core-deps.sh

# 2. 构建 OpenHarmony Go 工具链，首次执行需要数分钟
bash .deps/tailscale-harmony/scripts/build-toolchain.sh

# 3. 构建并放置 libmihomo_ohos.so
bash scripts/build-core.sh

# 4. 仅在本机不存在签名配置时创建公开模板
cp build-profile.example.json5 build-profile.json5
```

随后在 DevEco Studio 中配置本机签名，或运行：

```bash
export DEVECO_SDK_HOME='/Applications/DevEco-Studio.app/Contents/sdk'
export JAVA_HOME='/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home'
export PATH="$JAVA_HOME/bin:/Applications/DevEco-Studio.app/Contents/tools/node/bin:$PATH"

node '/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js' \
  --mode module \
  -p module=entry@default \
  -p product=default \
  --no-daemon \
  assembleHap
```

## 验证

```bash
bash scripts/stability-regression-check.sh
bash scripts/release-preflight.sh
```

当前版本的完整真机验收还应覆盖：锁屏和前后台长时间运行、网络切换、真实 HTTPS
与 ChatGPT 流量、恢复次数、冻结日志，以及主动断开后 VPN 扩展进程退出。

下载 Release 中的未签名 HAP 后，请按 [自签与安装说明](docs/SELF_SIGNING.md)
使用自己的证书、Profile 和目标设备信息完成签名。发布页同时提供 SHA-256 校验文件。

## 安全与隐私

仓库和发布附件不包含内置订阅、代理账号、设备标识、签名证书、签名密码、本机
绝对路径或诊断导出。发布附件仅包含未签名 HAP 和校验文件；用户导入的配置只保存
在应用本地数据目录中。

安全问题请使用 GitHub Private Security Advisory，详见 [SECURITY.md](SECURITY.md)。

本项目与 Huawei、MetaCubeX 无隶属或官方合作关系。
