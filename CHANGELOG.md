# 更新记录

## v0.01 测试版 - 2026-09-26

- 基于 `VpnExtensionAbility`、mihomo 和 gVisor 的 HarmonyOS 原生 VPN 隧道。
- 支持 Clash/Mihomo YAML、Base64 订阅和常见分享链接。
- 支持节点选择、路由模式、DNS、连接管理、诊断和分应用代理。
- 健康检查改为非阻塞后台探测，并限制 TUN 自动恢复条件和次数。
- 增加可复现的第三方依赖固定版本和 OpenHarmony gVisor 补丁。
- 增加发布前脱敏检查和 GitHub Actions。

已知限制：当前版本尚未完成锁屏和数小时连续运行下的真机断连验收。
