# Clash Dash 实施与验证记录

记录日期：2026-10-25。当前工程 **0.3.0 (3)**。目标是用户自己的 iPhone；未提交、推送、公开发布、购买服务或修改 Mac 上 Clash Verge 的运行配置。

**使用流程 P0 已落地，实际 iPhone 订阅通网实验通过。** 已修复内部 Unix socket 路径超长导致核心启动失败的问题。导入流程明确区分「使用并连接」「仅保存」，支持离线预选，连接页区分隧道与网络检查，保留运行版本信息。详见 [0.3.0 实现与验证](RELEASE_0_3_0.md)；下文协议互操作等旧实验仍按其原平台解释。

## 已实现的使用链路

1. 输入 HTTPS 订阅、粘贴客户端订阅安装链接、选择 YAML/JSON/文本文件，或直接粘贴节点分享链接/配置。
2. 用固定核心的原生导入器识别、构建和校验节点；完整 Clash/mihomo 配置保留策略组、规则和 DNS。对节点集合生成“节点选择”手动策略与 MATCH 规则，并明确说明其他客户端的路由/DNS/脚本不迁移。
3. 完整配置先做有界 YAML 检查：5 MB、深度/别名展开限制、重复键、重名节点、缺失引用和策略组循环。iOS 无法执行的 PROCESS/UID 规则明确提示后跳过；原文完整保留，其余规则顺序不变。
4. 下载 HTTPS proxy/rule providers（最多 16 项、单项 5 MB、总计 20 MB），保留合法自定义请求头，跨域重定向清除敏感头。以原生核心校验内容，转换为不可变的 file provider 快照。
5. 调用核心资源计划，提前下载、验证所需 GeoIP/GeoSite 等公共数据库；单文件 64 MB 上限，流式落盘、24 小时缓存，带哈希随配置版本保存。iOS 核心要求预先准备地理库，不能依赖扩展首次启动下载。
6. 在独立 App 校验工作目录调用核心完整编译检查，不启动服务、TUN 或监听器。所有资源和语义检查通过后才显示可保存预览；失败保持旧版本。
7. AES-GCM 加密原文、运行配置、订阅地址和 provider 快照；写入文件后原子更新索引。元数据有系统文件保护，含节点名/规则摘要；公共地理库是受保护的未加密数据文件，校验后才复制给扩展。
8. 连接时只将 profile ID/version 放入系统 VPN 配置。扩展解密指定版本、准备资源、启动核心，经公开 NEPacketTunnelFlow ↔ socket pair ↔ gVisor 承载 IP 包。
9. 页面显示实际系统 VPN 状态与扩展回执；支持手动组选节点、三个并发延迟测试、规则/全局切换、流量与连接、关闭单连接。选择和模式按配置记忆。
10. 更新不会替换正在运行的版本，重连后应用新版本；支持手动恢复。保留最近三版及所选/已启动版，清理过期 blob 时额外保护系统当前配置的 generation。

没有账号体系、节点销售、云同步、广告统计、后台剪贴板读取或脚本执行。

## 导入格式与联网范围

Clash、Shadowrocket、Surge 是客户端或配置格式，Shadowsocks、Trojan 等才是连接协议。“ShadowRocks / Rocket”按用户意图落实为 Shadowsocks 协议及 Shadowrocket 常见导入格式。

| 输入 | 当前行为 |
| --- | --- |
| Clash/mihomo YAML/JSON 完整配置 | 保留节点、组、规则和 DNS，接管桌面监听/TUN/控制器配置 |
| 分享链接、Base64 订阅 | 原生解析；SDK 报告 28 种 scheme，含协议别名，不代表 28 个独立协议均已联网验收 |
| Shadowrocket JSON、SIP008/SSD | 导入可识别节点；对无法解析的记录和未映射字段明确提示 |
| sing-box/V2Ray JSON 出站、Surge Proxy 节点、WireGuard INI | 节点集合导入；不迁移完整专有规则、DNS、脚本和其他客户端功能 |
| 客户端订阅安装链接 | 解包常见 clash/shadowrocket/surge/sing-box/sub 链接，最终仅下载 HTTPS |
| Loon/Quantumult X 等专有完整配置 | 没有承诺完整兼容；可使用服务商的 Clash 或常见节点订阅版本 |

混合节点集合会显示跳过数量；完整 Clash 策略若包含不能解析的节点会拒绝保存，避免悄悄破坏引用。能导入不等于节点可用，也不代表对应协议已在 iPhone 验收。

## 验证证据

日志和产物在被忽略的 `.build/`。合成测试只使用公开样本、保留地址和本机临时密钥；真实订阅测试使用用户明确授权的 `~/.clashdash`，报告只留类型、数量、格式、延迟和结果。

| 检查 | 结果与证据 | 证明范围 |
| --- | --- | --- |
| 共享包 | 28 项通过；`UXClosure/package-tests.log` | 有界解析、安装链接、HTTPS 边界、usage、加密认证/篡改、回滚、资源事务、偏好、GeoIP 哈希和运行版本保留 |
| 原生格式导入 | 47 项通过；`import-compatibility-latest.log`、`ImportLab/result.json` | 固定 SDK Shadowrocket 合成导出语料及拒绝项、Base64、混合记录提示、完整 Clash 策略、sing-box、Surge、VMess WS/TLS |
| 原始 SS 实验 | 通过；`core-integration.log`、`CoreLab/result.json` | 内联和 file provider 两条链路，真实 TCP HTTP204、代理 UDP DNS 返回预期地址 |
| 多协议独立服务端 | 12 组通过；`protocol-integration.log`、`ProtocolLab/result.json` | 见下表；错误 TLS 证书指纹确实被拒绝 |
| 真实订阅及变体 | 4 份读取均通过；`LiveValidation/validation-report.json` | 36 节点、31 组、6454 条可用规则、GeoIP、完整核心预检、加密存储往返；18 条桌面进程规则按提示跳过 |
| 真实节点联网 | HTTPS 全部曾通过；最新批次35/36，Trojan 单独复测恢复；`LiveValidation/network-report*.json` | AnyTLS 35/35 及无缓存代理 UDP DNS 通过；Trojan HTTPS 通过，机场节点 UDP 未通过；模式读回通过 |
| Release 构建和签名 | 0.3.0 通过；`UXClosure/release-build.log`、`UXClosure/release-signing.json` | App/Extension 代码签名、匹配描述文件、Packet Tunnel、App Groups、共享 Keychain |
| 模拟器交互 | 3 项全部通过；`ui-tests-simulator-final.log`、`SignedSimulator/Logs/Test/Test-ClashDash-2026.10.25_00-39-29-+0800.xcresult` | URL 入口/导航、诊断配置持久化、实际原生分享节点导入/预览/保存/原文 |
| 旧版 iPhone 安装与启动 | 0.1.0 成功；`device-install.json`、`device-launch.json` | 真机 App 可安装和启动，不证明 VPN 可用 |
| 旧版 iPhone UI | 2 项通过；`ui-tests-iphone.log`、`UITests-iPhone.xcresult` | 四 Tab、URL 入口、无凭据样本保存和重启恢复；没有替用户授权或启动 VPN |
| 固定 SDK 恢复 | 通过；`bootstrap-validation.log` | SHA-256、Adapter 固定文件哈希、framework 符号链接和重复恢复 |

不同 User-Agent（Shadowrocket、sing-box、Surge）从同一授权 URL 得到的实际内容都仍是 Clash YAML。没有把这些响应冒称为机场的对应专有格式；其他格式由固定核心的公开合成语料覆盖。

独立 mihomo 服务端互操作矩阵（macOS 用户态、临时 loopback、合成凭据）：

| 协议/传输 | TCP | UDP DNS | 备注 |
| --- | --- | --- | --- |
| Shadowsocks AEAD / SS2022 | 通过 | 通过 | 两组 |
| Trojan TLS / WebSocket TLS | 通过 | 通过 | 两组；另测错误证书 pin 拒绝 |
| VMess TCP / WebSocket TLS | 通过 | 通过 | 两组 |
| VLESS TLS | 通过 | 通过 | 未声称覆盖所有 Reality/XHTTP 参数组合 |
| Hysteria2 | 通过 | 通过 | QUIC |
| TUIC v5 | 通过 | 通过 | QUIC |
| AnyTLS | 通过 | 通过 | 独立服务端及真实订阅均测过 |
| SOCKS5 | 通过 | 通过 | 本机参考服务端 |
| HTTP CONNECT | 通过 | 不适用 | 不虚构 UDP 支持 |

真实订阅的 Trojan 节点未声明 `udp: true`，按上游默认并未启用 UDP；保持原配置时无缓存 DNS 请求失败。另做仅限实验的 UDP 开启对照，向 1.1.1.1、223.5.5.5 和 8.8.8.8 均超时，不能声称该机场节点支持 UDP。原订阅和 App 导入配置未被改写。受控独立 Trojan 服务端的 UDP 已通过，暂不能把机场节点失败归因为客户端协议缺失。首轮复用 DNS 查询曾产生缓存命中，已改为每次新建 DNS 客户端、直接指定节点并检查 `fromCache == false`；以无缓存结果为准。需要 UDP 时优先选择本次已通过的 AnyTLS 节点。

真实订阅实验的进程内存读数约 17 MB，仅为 macOS 用户态某一时刻，**不是 iPhone 扩展峰值或长期存活数据**。真实节点探测访问 HTTPS 204 目标及 UDP DNS，没有浏览个人内容或向其他人发送消息。

脱敏、可交付的机器可读结果同时保存在 `docs/validation/`：`import-compatibility.json`、`protocol-integration.json`、`subscription-import.json`、`subscription-network.json`。其中机场 Trojan UDP 失败保留为失败，未合并成全部通过。

## 架构与隐私边界

- SwiftUI App、Packet Tunnel Extension、本地 Swift Package。App 和扩展各自链接固定静态核心：App 仅做离线导入/资源计划/预检，只有扩展启动网络服务。没有外部控制器或本地 HTTP 控制接口。
- 共享 Keychain 密钥为 AfterFirstUnlockThisDeviceOnly；App Group 文件保护并排除备份。公共地理库不含订阅凭据，采用流式 SHA-256 和文件复制，避免扩展把整个库读入 Swift Data。
- 原始配置保留；iOS 接管桌面端口、外部控制器、listeners、tunnels、TUN 和 DNS 监听。默认 gVisor、MTU1400；未提供 DNS 上游时预览提示使用阿里/Cloudflare DNS。
- 资源更新按整份订阅快照进行，不执行 provider 自带的周期刷新；旧版本运行期间不被改写。
- 正常停止/启动失败清除明文运行目录和临时目录；下次启动重建 Runtime，清除系统强杀遗留。密文清理保留当前运行 generation。
- 物理网络监听和接口绑定采用固定 Adapter 的公开接口；没有私有 utun/KVC 技巧。
- IPC 有版本、request/session/generation、大小/超时、测速并发和变更回执缓存；重连可发现新会话。只留自有生命周期事件，丢弃原始核心日志。
- 真实 URL/节点凭据不进入源码、UI 自动化输入、截图、对话或脱敏报告。实验原始下载、运行配置和临时加密密钥在完成后清理，用户原文件不变。

实际界面截图：`screenshots/overview-light.png`、`overview-dark.png`、`node-import-preview.png`、`profile-detail.png`、`settings.png`；无个人凭据。`iphone-*-010.png` 是旧版 0.1.0 真机截图，不能当作新版手机验收。

## 本轮真机结果与剩余验收

0.3.0 的 PacketFlow、核心响应、默认 HTTPS、AnyTLS UDP、测速、规则/全局切换、断开后路由恢复和重连均通过；采样核心峰值 16.7 MB。正式 Release 界面连接/线路页/断开用例通过。具体报告与截图见 [本版记录](RELEASE_0_3_0.md)。

仍需验证：长时间锁屏与后台、Wi-Fi/蜂窝切换、断网恢复、重启、持续内存和耗电；IPv6 及 SSR、WireGuard、Snell、SSH、Hysteria1、Reality/XHTTP 等全部组合。本轮不将解析支持扩大为这些组合已经真机通过。

当前没有自动重连/On Demand、周期订阅更新、二维码、Widgets/App Intents、自定义规则编辑、按 App 分流、脚本增强和云同步。启动失败可手动恢复历史版本，尚无自动回退；`lastKnownGood` 仅表示收到运行快照，不代表 Internet 健康检查通过。未进行发布二进制审计或准备完整分发源码包。

安装与逐项验收见 [LOCAL_ACCEPTANCE.md](LOCAL_ACCEPTANCE.md)。原始产品规划是目标规格，当前是否完成以本记录及可复现测试为准。
