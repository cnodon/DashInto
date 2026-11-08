# 本地 iPhone / iPad 运行与验收

当前开发版本为 **0.5.3 (18)**。本版构建、签名与自动化范围见 [版本验证记录](validation/release-0.5.3.json)；各版本的真机测试不相互替代。早期 0.3.0 的通网实验保留在 [历史记录](RELEASE_0_3_0.md)。

## 配置签名与运行

在工程根目录创建 `Local.xcconfig`（已被 Git 忽略），使用自己的 Team 和唯一标识：

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
APP_BUNDLE_ID = app.yourname.dashinto
APP_GROUP_ID = group.app.yourname.dashinto
```

创建后重新运行 `python3 Scripts/generate_project.py`，再打开 `ClashDash.xcodeproj`。核心依赖首次通过 `python3 Scripts/bootstrap.py` 下载并校验。

在 Xcode 中确认主 App 与 Tunnel 扩展使用同一 Team，Packet Tunnel、App Groups 和 Keychain 权限与签名配置匹配。连接并解锁 iPhone 或 iPad，开启开发者模式，选择 **ClashDash** scheme 后运行。首次连接需要在手机允许添加 VPN 配置。更改 Bundle ID 或 App Group 会使用不同的数据容器；升级现有安装时保留原标识。

也可使用 `xcrun devicectl list devices` 查询设备 ID，再执行 `python3 Scripts/run_on_iphone.py --device <CoreDeviceID>` 完成构建、签名检查、安装与启动。

## 日常使用

1. 设置中确认版本为 0.5.3 (18)。现有订阅与密钥保留，不需要删除 App。
2. 添加订阅后直接点「使用并连接」，首次按系统提示允许添加 VPN 配置。不要再去配置详情寻找激活按钮。
3. 已有订阅可在订阅卡片上点「使用并连接」；首页也可通过订阅卡片的切换按钮选择。
4. 「仅保存」不会替换当前订阅。代理页可选择节点并连接；代理组详情也支持保存下次连接使用的选择。
5. 默认按订阅规则分流。复杂订阅按不同用途显示组，无需逐个选完才连接。
6. 首页「网络检查通过」表示两个 HTTPS 检查目标可达；只有「VPN 已建立」时可重试检查或更换线路。

## 仍需日常场景观察

- 锁屏 10 分钟、30 分钟后解锁，检查网络与状态一致性。
- Wi-Fi 与蜂窝切换、短暂断网后恢复，确认网页与 UDP 应用能恢复。
- 视频、下载、语音等长时间使用，观察内存、耗电、温度和稳定性。
- 正在连接时更新订阅，检查「更新待应用」及重连后的运行版本。
- 远程 provider 订阅的实际线路展开与大字体、VoiceOver 操作。

网络检查不能证明全部节点和协议可达。此前机场 Trojan UDP 未通过；本轮真机已验证 AnyTLS UDP。失败时请保留订阅，从连接页查看阶段和运行诊断，不必重置配置。

## 本机复现

- 共享包：`swift test --package-path Packages/ClashDashKit`。
- 模拟器使用 `UITests/ClashDashUITests.swift`；通过独立测试库隔离用户数据。
- 安装签名 Release：`python3 Scripts/run_on_iphone.py --device <CoreDeviceID>`。
- 物理 Release 界面用例仅显式设置 `CLASHDASH_PHYSICAL_RELEASE=1` 时运行，不导入或删除用户数据。
- `DeviceValidation.swift` 只在 Debug 且显式启动参数和一次性请求同时存在时运行。请求中的订阅 URL 从授权本地文件读取，不能硬编码进测试或启动参数。
