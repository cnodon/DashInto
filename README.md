# DashInto

基于 SwiftUI 与 mihomo 派生核心的原生 iOS 代理客户端，支持 Clash/mihomo 订阅、规则分流和实时网络监测。

**iOS 18+ · SwiftUI · GPL-3.0-or-later**

## 功能

- **订阅管理**：导入链接、文件或节点文本；自动更新、额度与到期信息；更新失败保留原配置。
- **节点选择**：规则、全局、直连模式；手动策略组切换；按名称或延迟排序并保存偏好。
- **批量测延迟**：进度与结果报告、取消、失败重测；可选择 Cloudflare / Google 测试目标。
- **网络面板**：实时流量曲线、当前节点、出口 IP，以及 Google、YouTube、OpenAI、Claude 连通性检查。
- **本地保护**：配置与订阅凭据加密保存，密钥存储于 Keychain；提供脱敏运行诊断。
- **原生交互**：深浅色外观、动态字体、VoiceOver 与减少动态效果支持。

兼容 Shadowsocks、Trojan、VMess、VLESS、AnyTLS、Hysteria2、TUIC 等协议。部分客户端导出格式按节点集合导入，不迁移其专有脚本和路由。节点测速表示响应延迟，不是下载带宽。

## 构建与运行

需要 macOS、Xcode（iOS 18 或更新 SDK）、Python 3，以及具备 Packet Tunnel 和 App Groups 签名能力的 Apple Developer Team。

```sh
git clone https://github.com/cnodon/DashInto.git
cd DashInto
python3 Scripts/bootstrap.py
python3 Scripts/generate_project.py
open ClashDash.xcodeproj
```

在 Xcode 配置签名，选择 **ClashDash** scheme 和 iPhone 后运行；首次连接需允许系统添加 VPN 配置。模拟器可验证界面，VPN 通网需要真机。

自定义 Team、Bundle ID 和 App Group 的方式见[本地运行指南](docs/LOCAL_ACCEPTANCE.md)。依赖版本与校验值固定在 [Dependencies.lock.json](Dependencies.lock.json)。

## 开发与验证

```sh
swift test --package-path Packages/ClashDashKit -c release
python3 Scripts/test_imports.py
python3 Scripts/test_delay_probes.py
```

核心实验使用独立服务端和本地端口；可通过 `CLASHDASH_REFERENCE_CORE` 指定 mihomo 可执行文件。

| 目录 | 用途 |
| --- | --- |
| `ClashDashApp/` | SwiftUI 界面、订阅与 VPN 管理 |
| `ClashDashTunnel/` | Packet Tunnel 扩展与核心桥接 |
| `Packages/ClashDashKit/` | 配置解析、加密存储、连接与测速逻辑 |
| `Scripts/` · `Fixtures/` · `UITests/` | 构建工具、测试样本与交互回归 |

当前开发版本为 **0.5.2（17）**，通过 Mac / Xcode 安装，尚未提供 App Store 或 TestFlight 分发。GitHub Releases 用于检查版本，不直接覆盖安装；订阅后台更新由 iOS 调度。

详细测试范围与已知限制见[版本验证记录](docs/validation/release-0.5.2.json)，产品流程见[交互设计](docs/INTERACTION_REDESIGN.md)。

## 许可证

本项目采用 [GPL-3.0-or-later](LICENSE)。第三方组件及其许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
