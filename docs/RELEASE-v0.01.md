# LIAN CONNECT v0.01（测试版）

这是首次公开测试版本，包含可复现源码以及经过脱敏检查的 arm64 未签名 HAP。

## 下载说明

- `LIAN-CONNECT-v0.01-unsigned.hap`：未签名测试包，不能直接安装。
- `SHA256SUMS.txt`：发布附件的 SHA-256 校验值。

安装前必须使用自己的 HarmonyOS 证书和 Profile 对 HAP 签名，包名为
`com.lianconnect.app`。具体步骤见仓库中的 `docs/SELF_SIGNING.md`。发布内容不包含
私钥、证书、Profile、密码、订阅、代理账号、设备标识或本机路径。

## 构建与实现

项目基于 HarmonyOS Stage 模型、ArkTS、`VpnExtensionAbility`、C++ N-API、mihomo
和 gVisor 构建。第三方依赖均固定到明确提交，OpenHarmony TUN 适配以最小补丁公开。
详细实现、依赖版本和构建步骤见 README 与 `THIRD_PARTY_NOTICES.md`。

## 已知问题

- 本版本尚未完成锁屏、网络切换和数小时连续运行下的真机断连验收。
- 模拟器不能替代真实 VPN 授权和 TUN 数据面验证。
- 分应用代理受系统包信息权限限制，不同系统版本的行为仍需真机复核。
- 节点失效、订阅过期、DNS 或上游网络异常可能需要手动换节点或重连。

本版本按 GPL-3.0 发布。请将它视为测试构建，不要用于关键网络环境。
