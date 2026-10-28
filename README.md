# DashInto

原生 SwiftUI iOS 代理客户端，当前开发版本 **DashInto 0.4.4 (8)**。五个标签为首页、订阅、代理、本机信息、设置。首页用实时曲线、额度环、节点速率和网站状态展示核心信息；更新入口连接公共仓库 `cnodon/DashInto`。

0.4.4 完成操作与视觉收敛：首页直接打开节点选择面板，选完返回；常用操作与详情分层；同一运行订阅避免重复重连。界面以流量面积图、剩余额度环、延迟质量条和网站状态块展示数据，压缩重复标题、段落和时间说明，保留单位与异常状态。48 项 Release 单元测试、5 项模拟器 UI 测试通过；Release 构建和签名检查通过，深浅色及辅助功能大字体已人工检查。2026-10-28 已按用户要求覆盖安装到 PKR 并成功启动，设备版本回读为 0.4.4 (8)。此次仅安装与启动，未运行真机自动化或切换 VPN；批量测速完整真机验收仍待完成。见 [交互记录](docs/INTERACTION_REDESIGN.md) 和 [本版验证](docs/validation/release-0.4.4.json)。

输入一次 HTTPS Clash/mihomo 订阅地址，自动准备节点、策略组、规则、DNS、provider 和所需地理数据库。也支持分享链接、Base64 节点订阅、Shadowrocket 等客户端的部分节点导出格式；节点集合会生成手动选择策略，不承诺迁移原客户端的专有路由和脚本。

## 已实现

- 首页、订阅、代理、本机信息、设置五个原生页面；紧凑布局、原生 List、深浅色、Dynamic Type 与 VoiceOver 标签。
- 核心总速率和 60 秒曲线、节点名称和速率估算、剩余额度环、请求检测出口、Google / YouTube / OpenAI / Claude 一键检查。
- GitHub Release 版本检查、前台节流、系统调度后台刷新和可选本地通知；TestFlight 安装入口预留，云端发布暂未配置。
- 真实 VPN 状态、节点选择、规则/全局/直连模式、延迟测试、实时流量、活动连接、单连接关闭和脱敏诊断。
- HTTPS 订阅、客户端安装链接、本地文件、直接粘贴节点或配置；导入预览、核心语义检查、更新、本地版本保留与额度/到期信息。
- 远程 provider 与 GeoIP/GeoSite 等资源在导入时准备、校验并随版本保存，失败保留旧配置；扩展无需在首次启动时下载地理库。
- 配置、订阅凭据、provider 使用 AES-GCM 加密，共享 Keychain；文件保护、排除备份、旧版本资源清理。公共地理数据库以带哈希的文件保存。
- 公开 NEPacketTunnelFlow ↔ socket pair ↔ 核心数据通路；物理网络监听、退出清理和会话隔离。

“Clash”和“Shadowrocket”是客户端/配置格式名称；实际协议包括 Shadowsocks、Trojan、VMess、VLESS、AnyTLS、Hysteria2、TUIC 等。导入兼容性与协议联网测试分别记录，不能把 macOS 实验当成 iPhone VPN 已验证。

## 验证记录（区分版本）

| 验证层 | 结果 |
| --- | --- |
| 共享包 | 0.4.4：48 项 Release 测试通过，含批量测速优化构建回归、订阅命名与重命名 |
| 原生导入兼容性 | 47 项检查通过；SDK 报告 28 种可识别分享 scheme（含别名） |
| 独立协议服务端 | 12 组通过；覆盖 SS/SS2022、Trojan、VMess、VLESS、Hysteria2、TUIC、AnyTLS、SOCKS5、HTTP CONNECT；除 HTTP 外均测 TCP 与 UDP |
| 用户授权的真实订阅 | 36 节点、31 组、6454 条 iOS 可用规则；核心预检、数据库准备和加密存储往返通过 |
| 真实节点联网 | HTTPS 全部曾通过，Trojan 出现一次瞬时失败后复测恢复；AnyTLS UDP DNS 通过，机场 Trojan UDP 未通过（macOS 用户态） |
| 模拟器 UI | 0.4.4：5 项通过，含首页节点面板选择、三模式持久化、命名/重命名、仅保存保持选择及显式示例数据预览 |
| iOS 构建与签名 | 0.4.4 Release App/Extension、VPN/App Group/Keychain 权限校验通过 |
| iPhone | 0.4.4 (8) 已覆盖安装并启动，未清空应用数据。此次未运行真机自动化或切换 VPN，完整批量测速回归尚待完成。历史 0.3.0 的 VPN 证据保留 |

当前模拟器交互测试、证据位置和限制见[实施与验证记录](docs/IMPLEMENTATION_STATUS.md)。真实订阅只用于本机实验，未写入源码；没有修改 Mac 上 Clash Verge 的运行配置。

## 打开与运行

需要 macOS、Xcode（iOS 18 或更新 SDK）、Python 3 和具备 Packet Tunnel 能力的 Apple Developer Team。当前工具链为 Xcode 26.6 / iOS SDK 26.5；最低 iOS 18。Yams 5.4.0 已随源码提供。

```sh
python3 Scripts/bootstrap.py
python3 Scripts/generate_project.py
open ClashDash.xcodeproj
```

选择 **ClashDash** scheme 和自己的 iPhone，按 ⌘R。第一次点击连接时，在手机允许系统添加 VPN 配置。App 的桌面名称为 DashInto；工程和 scheme 暂保留 ClashDash，签名标识及数据容器不变。

本机 `Local.xcconfig` 已被忽略，可配置 Team 和配套标识；创建或删除后重新生成工程：

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
APP_BUNDLE_ID = app.yourname.clashdash
APP_GROUP_ID = group.app.yourname.clashdash
```

也可以在接回手机后使用安装脚本；设备 ID 来自 `xcrun devicectl list devices`：

```sh
python3 Scripts/run_on_iphone.py --device YOUR_COREDEVICE_ID
```

脚本构建 Release、检查签名、安装并打开 App；VPN 授权在手机完成。详细操作和验收顺序见[本地真机验收](docs/LOCAL_ACCEPTANCE.md)。

## 开发验证

```sh
swift test --package-path Packages/ClashDashKit
python3 Scripts/test_imports.py
python3 Scripts/test_core.py
python3 Scripts/test_protocols.py
python3 Scripts/verify_signing.py
```

核心实验需要独立 mihomo 服务端，默认使用已安装的 Clash Verge 可执行文件作为单独进程，也可设置 `CLASHDASH_REFERENCE_CORE=/path/to/mihomo`。只使用临时配置和 loopback 端口，不更改系统代理。

模拟器测试保留本地 ad-hoc 签名，以便 Keychain 正常工作；以下适用于 Apple Silicon：

```sh
xcodebuild -project ClashDash.xcodeproj -scheme ClashDash \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 test
```

## 工程与文档

| 路径 | 内容 |
| --- | --- |
| `ClashDashApp/` | SwiftUI、VPN 管理/IPC、原生导入器、导入阶段核心预检 |
| `ClashDashTunnel/` | Packet Tunnel、公开包流桥接、物理网络与核心生命周期 |
| `Packages/ClashDashKit/` | 规范化、下载、资源事务、版本与加密存储、共享模型 |
| `Vendor/` | 固定 SDK、Adapter、Yams 与完整上游许可 |
| `Scripts/`、`Fixtures/`、`UITests/` | 恢复/构建/安装、合成样本、兼容性和交互验证 |

- [使用逻辑与交互重构方案（P0 已实施）](docs/INTERACTION_REDESIGN.md)
- [实施状态和验证证据](docs/IMPLEMENTATION_STATUS.md) · [本地真机验收](docs/LOCAL_ACCEPTANCE.md) · [后续 Agent 接续](docs/AGENT_HANDOFF.md)
- [原始详细规划](docs/CLASH_DASH_PLAN.md) · [Word 版规划](docs/ClashDash-产品设计与技术实施规划.docx)
- [浅色概览](docs/screenshots/overview-light.png) · [深色概览](docs/screenshots/overview-dark.png)

源码使用 GPL-3.0-or-later；依赖来源见 [Dependencies.lock.json](Dependencies.lock.json) 和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。没有提交、推送或公开发布，没有 App Store/TestFlight 分发。
