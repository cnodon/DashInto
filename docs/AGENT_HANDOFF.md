# Clash Dash 接续说明

先读 [实施与验证记录](IMPLEMENTATION_STATUS.md)、[本地真机验收](LOCAL_ACCEPTANCE.md) 和根目录 README，沿用现有工程。原始 [产品技术规划](CLASH_DASH_PLAN.md) 是目标规格，不能把其验收门槛当成已经通过。

## 当前接续点（0.4.1）

最新版本是 **DashInto 0.4.1 (5)**，请以根目录 README、[首页交互调整](INTERACTION_REDESIGN.md) 和 [验证记录](validation/release-0.4.1.json) 为准。五个 Tab 为首页、订阅、代理、本机信息、设置；已实现 GitHub Release 检查入口，TestFlight 尚未接入。未连接首页突出连接、订阅和线路，已连接保留实时数据布局。启动与前台轮询共享在途核心快照，旧轮询回调不得更新新状态。

39 项共享测试、4 项模拟器 UI 用例通过，Release 和签名校验通过；0.4.1 已覆盖安装到 iPhone 15 Pro Max 并启动，未重新进行本版 VPN 通网或耗时基准测试。用户本轮明确授权将代码提交并推送到 `https://github.com/cnodon/DashInto`，不包含创建 GitHub Release、上传 TestFlight 或修改私人订阅的授权。

## 历史接续点（0.3.0）

用户已要求把核心需求落代码、部署并测试。**0.3.0 (3)** 已实现使用流程 P0；继续工作前读 [0.3.0 记录](RELEASE_0_3_0.md)。不要把旧 0.2.0 的失败或未验证状态当成当前结论。

真机实际阻断点为核心内部 socket 路径 176 字节超过 Darwin 103 字节限制。`TunnelPaths.controlDirectory` 将 BasePath 放到 App Group 的 Core 短目录；配置工作目录仍按版本隔离。真实订阅 36 节点、31 组、6454 规则已成功启动；默认 HTTPS、AnyTLS HTTPS/UDP、实际流量、测速、断开和重连均通过，脱敏报告为 `docs/validation/iphone-0.3.0.json`。

Debug 专用 `DeviceValidation.swift` 已实际运行，显式参数与一次性 Caches 文件触发；Release 无此入口。它调用生产导入、存储和连接协调器，但不等同于 Release UI 验收。物理 Release UI 的连接、网络检查、线路页和断开用例已通过，结果包 `.build/UXClosure/ReleaseUIRetest.xcresult`。用例在 `UITests/PhysicalReleaseTests.swift`，只在设置 `CLASHDASH_PHYSICAL_RELEASE=1` 时运行，保留手机已有配置。

订阅地址来源 `~/.clashdash` 当前是带键名的一行赋值，需要提取其中唯一 HTTPS URL，不能直接将整行当 URL。只在测试中读取，不输出秘密、不写入源码。手机已有用户订阅和本轮添加的「已验证订阅」，不要删 App 或重置数据。

此前 macOS 47 项导入、12 组协议互操作证据仍有效；机场 Trojan UDP 原配置未启用且实验启用后也超时，仍不能泛称所有节点 UDP 均通过。长期锁屏、网络切换、耗电尚未验收。

## 授权与隐私

用户明确允许读 `~/.clashdash`，以及查看已登录 Chrome 的机场页面用于协议实验；未授权购买、重置订阅/密钥、公开发布、发消息给他人或提交推送。不要修改 Mac 上 Clash Verge 的运行配置，不读取浏览器底层凭据/cookie。Chrome UI 后来不可达，不必为此阻塞独立工作。

真实 URL、原始下载、标准化运行配置和实验加密密钥在实验收尾清理，只保留脱敏报告；原始 `~/.clashdash` 不改不删。要复测必须从用户授权文件在受限临时目录读取，禁止输出 URL/token/节点密码或写进源码。自动化 UI 仅使用无个人凭据样本。

## 固定依赖和运行

`Dependencies.lock.json` 固定 SDK `v1.19.33-clash.3` 与对应源码/适配器 SHA；Yams5.4.0 本地依赖。先检查依赖存在，缺失才用 `Scripts/bootstrap.py` 恢复，随后 `generate_project.py`。`Local.xcconfig` 已被忽略，保留现有 Team/标识，别覆盖用户设置。

```sh
swift test --package-path Packages/ClashDashKit
python3 Scripts/test_imports.py
python3 Scripts/test_protocols.py
python3 Scripts/verify_signing.py
# 手机接回后，按用户要求执行安装；ID 来自 devicectl list devices
python3 Scripts/run_on_iphone.py --device YOUR_COREDEVICE_ID
```

模拟器必须保留 ad-hoc 签名，否则 Keychain -34018。日志及派生数据都在 `.build/`。不要无故重复跑已经通过的宽泛矩阵；改动、失败或未解决风险才重跑相关检查。

## 后续重点

1. 真机实际 TCP/UDP/DNS/IPv6、规则/组选节点、断开路由恢复、Wi-Fi/蜂窝、锁屏/后台/重启。
2. Release 真实规模扩展内存峰值、jetsam、耗电和长时间稳定性。
3. 冷缓存资源下载在手机环境的体验；不以跳过必需 GeoIP 库处理失败。
4. 按实际需求再做自动重连、On Demand、自动更新、二维码和规则编辑。当前版本没有这些功能，也不承诺其他客户端专有配置等价迁移。

保留已有改动，不自动提交或推送。交付时分别说明实现、测试平台、结果和仍待手机验证的部分。
