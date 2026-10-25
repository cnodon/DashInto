# DashInto 0.4.0 (4)

2026-10-25 本地交付。App 名称统一为 **DashInto**；黑底、白色动感图标已进入 AppIcon。桌面主程序与 VPN 扩展分别显示 DashInto、DashInto Tunnel。包标识、App Group、Keychain 和已有数据路径保留，覆盖安装可继续读取订阅。工程目录和 scheme 保留 ClashDash，避免把产品改名变成数据迁移。

## 使用方式与页面分工

| 页面 | 核心内容 |
| --- | --- |
| 首页 | 顶部状态与连接按钮；60 秒上下行曲线、会话流量和活跃连接；当前策略组/节点、节点速率估算；本次请求出口 IP；订阅剩余额度环；四站连通性与一次刷新 |
| 订阅 | 原生 List；全新安装不预装订阅；仅右上角添加。导入后可使用并连接或仅保存，保存不会暗中替换当前选择 |
| 代理 | 模式、代理组和节点选择；离线选择保存在本机，下一次连接应用 |
| 本机信息 | iPhone/系统/App 版本、接入网络、IPv4/IPv6、低数据模式、本机接口地址、VPN/核心状态与诊断入口 |
| 设置 | 外观、说明、隐私、许可、GitHub 更新 |

根页面去掉重复的大标题；详情保留原生返回导航。没有复制桌面代理端口、系统代理开关或本机进程列表。

旧的“我的订阅”与“已验证订阅”仅在解密后的订阅地址完全相同、且均为订阅时合并；保留当前使用 UUID、选中版本、历史版本、远程资源及节点选择。原加密目录和迁移前索引保留供恢复。地址不同时不自动合并。

## 数据含义

- 总流量取核心真实采样，最多保留最近 60 秒；无采样显示空值。
- 当前节点由策略组递归解析实际选择。节点速率来自连续连接快照的字节差，属于估算，不等于节点最大带宽；新建/已关闭连接会造成漏计，首页明确标注“节点估算”。
- 订阅额度只有上传、下载、总量均存在时才绘图；缺失显示“未提供额度”，超额剩余为 0。额度由订阅响应头提供，与当前 VPN 流量分开统计。
- 出口 IP 是当前路由下访问 Cloudflare trace 的结果。规则模式下，各网站可能使用不同策略，不能代表所有网站统一出口。
- 网站检测区分正常响应、验证码、HTTP 限制、超时、失败；网页可达不证明账号、地域或模型 API 可用。四站和出口检测并行执行，每个请求有超时、响应体上限；切节点、切模式、断线时作废旧结果。
- 本机页只读取接口与路径信息；不申请定位、不读取 SSID 或硬件唯一标识。

## 软件更新：当前完成范围

默认公共仓库为 `cnodon/DashInto`，读取 GitHub Releases。支持 `v0.4.1` 或 `v0.4.0-build.5`，按三段版本号和构建号比较，过滤草稿、错误仓库和无效版本；可选择是否包含开发版本。

前台自动检查间隔 6 小时，也能手动检查。后台注册 BGAppRefresh，运行时机由 iOS 决定；可选通知需要用户允许。无 Release 显示“尚无已发布版本”，网络错误不会伪装成“已是最新版”。切换仓库或渠道清除旧缓存。

**未接通 TestFlight**：当前仓库没有发布版本，App Store Connect 浏览器停在登录页；用户明确选择稍后处理 TestFlight。真机本地安装已于 2026-10-25 完成。尚未上传构建、创建测试分发、配置 GitHub Actions 发布或推送代码。只有上传代码本身不会产生 App 更新。

后续接通顺序：

1. 登录 App Store Connect，为现有 bundle ID 确认 DashInto 应用记录、发行签名与 Packet Tunnel/App Group 权限。
2. 准备发行证书、App/Extension 的发行描述文件以及 App Store Connect API 凭据；仅保存在本机 Keychain 或 GitHub Secrets，不能加入源码。
3. 给默认分支的构建流水线加入测试、归档、签名、上传和 Apple 处理状态检查。每次成功构建递增 CFBundleVersion；两目标使用相同版本。
4. 先开通内部 TestFlight；外部用户需要测试组及必要的 Beta 审核。出口合规信息需账户持有人确认，不预填未知结论。
5. 确认测试构建已可安装后再发布对应 GitHub Release，避免用户收到不能安装的版本通知。
6. 通过构建设置 `DASH_TESTFLIGHT_URL=https://testflight.apple.com/join/实际邀请码` 写入安装入口；TestFlight 管理自动安装，App 不自行覆盖可执行代码。

参考：[Apple 上传构建](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)、[TestFlight](https://developer.apple.com/testflight/)、[GitHub Releases API](https://docs.github.com/en/rest/releases/releases)。

## 验收证据

- 36 项 Swift 包测试通过：新增额度缺失/超额、递归节点解析、循环防护、节点差分速率、网站状态分类、IP 解析、仓库与版本边界、合并后的资源和选择保留、不同订阅不合并。
- 4 项模拟器 UI 测试通过：五个标签/空订阅/更新入口、导入连接与离线选择持久化、仅保存不替换当前选择、无效输入保留。模拟器不会伪装 VPN 已连接。
- Release 构建成功；主 App 与扩展的签名、VPN、App Group、Keychain、版本一致性通过检查。1024 × 1024 图标无透明通道。
- 已启动模拟器并检查实际首页布局；首页核心区域在标准 iPhone 屏幕内完整展示。手动执行 GitHub 检查，时间戳更新、按钮恢复可用，真实返回“尚无已发布版本”。
- 2026-10-25 11:05（北京时间）：最新 Release 已覆盖安装至 iPhone 并成功启动，设备回读版本为 0.4.0 (4)，含最新 D+i 速度感图标；未卸载或清空应用数据。安装版本证据：`.build/installed-release-0.4.0.json`；签名证据：`.build/release-signing-verification.json`。
- 2026-10-25 11:11（北京时间）：新增 iPhone 17 Pro（iOS 26.6.2）首次安装并启动通过，回读版本为 0.4.0 (4)。用户已开启开发者模式；主 App 与扩展描述文件均已包含新设备。证据：`.build/new-iphone-signing.json`、`.build/new-iphone-install.json`、`.build/new-iphone-launch.json`、`.build/new-iphone-app-installed.json`。未导入私人订阅或测试 VPN。
- 本版真机通网、后台唤醒、长时间锁屏、网络切换与耗电尚未验证。0.3.0 的真机连接证据属于历史基线。

本地详细日志在 `.build/UICompact/`；UI 结果为 `.build/SignedSimulator/Logs/Test/Test-ClashDash-2026.10.25_10-27-11-+0800.xcresult`。可安装构建为 `.build/ReleaseDevice/Build/Products/Release-iphoneos/DashInto.app`，后续运行 `python3 Scripts/run_on_iphone.py --device <CoreDevice ID>`。

没有提交、推送、创建 Release 或上传 TestFlight。公开仓库中不要包含 `.build`、Local.xcconfig、订阅地址、密钥、证书或描述文件。
