# Clash Dash 接续说明

先读 [实施与验证记录](IMPLEMENTATION_STATUS.md)、[本地真机验收](LOCAL_ACCEPTANCE.md) 和根目录 README，沿用现有工程。原始 [产品技术规划](CLASH_DASH_PLAN.md) 是目标规格，不能把其验收门槛当成已经通过。

## 首页连接与代理节点选择回归修复（2026-11-04，0.5.2）

当前 **0.5.2 (17)**。用户报告首页无法连接、代理页无法选节点。代码确认 0.5.1 的自动订阅 refresh 设置全局 busy=true，在下载/校验期间禁用首页连接与 canEditRoutes；此外代理页节点总表从来只有测速动作。修复：自动 refresh 不写 busy；perform/useAndConnect/toggleConnection 优先取消自动请求，refreshEpoch 拦截迟到的 UI library 赋值。自动 cleanup 不得清除正在执行的用户 busy 状态。手动更新仍采用独立忙碌反馈。

节点列表新增按钮和选择面板。ProxySelection.manualPath 遍历手动 selector 链、跳过自动组、防循环，优先当前分支。useNode 在单次用户操作中先设置叶子再设置父组，在线逐步 IPC 读回，离线持久化后启动连接。不能在当前策略固定节点时显示明确的全局模式按钮，必须用户点击才改模式；不会把所有分流组都改到一个节点。原组详情仍可单独配置该组，离线组选择仍保存到下次连接。

DEBUG 模拟器增加 --ui-test-blocked-refresh，必须配独立 UUID 库，订阅名显式标为测试；模拟 prepare 挂起并可取消，不访问来源、不伪造 VPN 成功。Release 字符串检查确认无该入口。验收通过需要看到：更新中按钮可用；点击连接进入真实驱动并显示模拟器限制；节点切换取消自动更新、持久化选择；节点列表明确模式处理。93 项 Release 单测和 4 项模拟器 UI 回归通过，构建及签名通过。已覆盖安装到 PKR 并回读 0.5.2 (17)，启动因手机 Locked 被 iOS 拒绝，尚未确认真机启动或 VPN 通网；未卸载/重置/手动切 VPN。未提交或推送。日志和最终状态见 `docs/validation/release-0.5.2.json`。

## 自动更新订阅与节点名称排序（2026-11-04，0.5.1）

当前 **0.5.1 (16)**。新增 `SubscriptionRefresh.swift`（间隔、状态、可取消刷新事务）与 `SubscriptionUpdates.swift`（iOS 后台调度和频率）。默认每天；前台分钟级到期检查，后台由 iOS 安排。共用原有下载/NativeConfigImporter/NativeResourcePreparer，完成前不发布。失败保留配置，退避 30 分钟；90 秒期限仅限制准备阶段。Profile 新增 optional refreshState，旧库兼容。ProfileStore expectedVersion 校验阻止迟到更新覆盖删除/新版本；不自动选择未选中的订阅、不重连 VPN，保留运行版本。无内容/资源变化只更新额度/时间。关闭或改频率取消自动在途任务。

节点排序新增 `.name`，自然名称排序；与默认/延迟顺序共用既有 AppStorage 并记住偏好，不改路由。用户确认只做节点排序，不做订阅列表拖动。

90 项 Release 单测、2 项模拟器用例、Release 构建与签名通过，设置截图已检查。实际后台调度时机、手机自动更新真实源尚未验收，不能把调度注册或合成事务测试当成这些证据。已覆盖安装到 PKR 并启动，回读确认 0.5.1 (16)，未卸载或清空数据、未手动切换 VPN；未回读实际订阅自动更新完成情况。证据见 `docs/validation/release-0.5.1.json`；本轮没有提交或推送。

## 测速结果与连接稳定性（2026-11-04，0.5.0）

0.5.0 (15) 在后续用户要求安装时已覆盖安装到 PKR、启动并回读确认；未切换 VPN、提交或推送。继承此前全部未提交改动，不能覆盖或丢弃。

新增 DelayResultsView / LatencyTestEndpoint；报告保留当前批次每节点结果与时间，支持仅重测失败、继续未完成、取消；重试开始新批次。DelayTestRunner 继续使用三固定 worker，不能改回曾在真机 Release 崩溃的 TaskGroup。准备失败保留旧报告，测速中冻结延迟排序。设置切换测速目标、扩展物理路径变化会清理节点当前延迟并标记旧报告失效。

ConnectionCoordinator 的启动就绪阶段总限 60 秒，网络检查总限 15 秒；检查超时保留 VPN。networkChanged 清除健康结论，同会话恢复也重查，取消/超时后的迟到结果不可覆盖新状态。RuntimeInfo 新增 optional networkRevision 保持旧载荷兼容；扩展以接口/可用性/IP 能力/网关变化更新它。首页下拉只刷新运行与网络数据，普通网站刷新保留旧值直到新结果抵达。

界面用例仅 DEBUG 模拟器支持 --ui-test-delay-results，要求独立库 UUID，显示“界面测试 · 示例数据”，不运行 VPN；Release 不含入口。79 项 Release 单测、2 项针对性 UI 回归（分次通过）、真实固定核心本地批量/超时/取消重试以及 Release 构建和签名通过。界面测试修正了弹窗背景重名查询和 iOS 26 嵌套 Switch 点击定位，最终截图已检查。最终验证与已知范围见 `docs/validation/release-0.5.0.json`。同类产品来源、缺口、优先级与真机验收待办在 `docs/INTERACTION_REDESIGN.md` 最新段落；不要把按需连接/订阅自动更新/备份当成已实现。

## 代理节点延迟排序（2026-11-02，0.4.10）

当前工作区 **0.4.10 (14)**。代理页搜索栏右侧和代理组详情导航栏新增排序菜单：默认顺序、延迟从低到高。`proxyNodeSortOrder` AppStorage 共享并记住偏好；搜索过滤可叠加，实时结果更新后自动重排。`ProxyNodeSortOrder` 以有效非负延迟升序，同值保持原序，负值和未知结果排后且稳定；AppModel 用实际节点集合过滤排序用延迟，避免 DIRECT=0 或组别名冒充最快节点。仅显示顺序，不改变配置、组选中项、测速目标或默认连接节点。

用户随后明确要求安装：已将 Release 0.4.10 (14) 覆盖安装到 PKR，成功启动并回读确认版本，保留现有数据；未切换 VPN 或运行真机测速。未提交或推送。71 项 Release 单测、1 项模拟器 UI 回归（切换延迟排序、组详情共享偏好、恢复默认以及原节点流程）通过；Release 构建和签名通过。详见 `docs/validation/release-0.4.10.json` 与 `.build/sort-0410-*`。

## 代理页测速入口反馈（2026-11-02，0.4.9）

当前工作区 **0.4.9 (13)**。用户在 0.4.8 上反馈“点全部测速没有反应”，对是否已连接的追问未提供明确状态。代码确认入口在 disconnected/runtime nil/空节点时被 disabled，因此无法触发任何说明；不能据此声称已确认用户手机当时就是未连接。

入口不再被这些条件静默禁用。未连接时展示持久的行内原因和“前往首页连接”，不会自行开启 VPN。已连接先进入可见、可取消的准备状态，刷新 runtime、同步首次采样会话、获取最新节点，再启动原有三固定 worker 队列。全部测速延后取得完整节点目录，组测速按组名延后展开，以支持远程节点刚刚加载的情形。同步 lastSampleSession 避免首次轮询 reset 清除已启动的测速。保留订阅/会话变化检查。

新增共享 DelayTestPreparation，准备阶段限制 20 秒；取消/超时/重复点击/迟到完成受 token 保护，空列表和错误不再无反馈。挂起和切换订阅会取消准备。DeviceValidation 等待条件同步包含准备阶段。核心网络测试/三并发/单节点超时实现未改。

用户随后明确回复“现在安装并打开”，已将 Release **0.4.9 (13)** 覆盖安装到 PKR、成功打开并回读确认版本。只完成安装和启动，未切换 VPN 或进行真机延迟复测；现有数据未卸载/重置。以后操作手机仍须按用户授权范围执行。本轮没有提交/推送。69 项 Release 单测和真实本地核心 12 节点的准备→批量/超时/取消重试通过；Release 构建及签名通过。模拟器离线点击与导航回归首轮只有一处新断言错误：测试中重启后状态是“未连接”，而不是重启前“连接未完成”；改正后复跑通过。结果见 `docs/validation/release-0.4.9.json` 与 `.build/delay-049-ui-retry.log`，截图为 `docs/screenshots/delay-needs-connection-049.png`。

## 首页居中与安装（2026-11-02，0.4.8）

当前工作区 **0.4.8 (12)**，承接 0.4.7 所有未提交变更。首页顶部取消左对齐的卡片/图标，改为居中状态、订阅名、节点名、模式和主按钮。黑白按钮随系统外观变化，连接后红色断开；新增按压、节点名称淡入及连接状态布局过渡，减少动态效果开启时取消这些动画。未改核心连接、数据采样或订阅逻辑。

用户明确要求安装，已覆盖安装到数据线连接的 **PKR**，回读版本 0.4.8 (12)。初次启动被系统 Locked 拒绝；用户回复“已解锁，继续”后，已成功启动正式版，证据 `.build/home-048-launch-unlocked.json`。没有卸载、重置、切换 VPN 或运行真机自动化。本轮无提交/推送。

3 项相关模拟器 UI 回归通过：仅保存/选择订阅、首页选节点与三种模式/重启持久化、标注示例数据的连接后视觉预览。Release 构建及 App/Extension 签名通过。截图已人工查看：`docs/screenshots/home-centered-048.png` 为生产界面合成订阅，`home-preview-048.png` 是明确标注的示例数据。Pinterest 参考链接标题可访问，但图片未加载；不能声称按该图还原。

证据见 `docs/validation/release-0.4.8.json` 与 `.build/home-048-*`。只改 UI，未重复此前已通过的核心/协议矩阵，未重新验证真实订阅通网。

## 订阅兼容、批量延迟与选中标识（2026-11-02）

当前工作区 **0.4.7 (11)**。用户本轮要求支持新订阅和更多格式、完成测速、标明选中的订阅；明确选择“批量节点延迟（毫秒），先把它做好”，不扩展带宽测速。本轮没有操作或安装手机，手机仍是已安装的 Release 0.4.6 (10)。没有提交或推送。

真实订阅返回 Clash/mihomo YAML，虽 Content-Type 为 text/html，但内容不是 HTML。生产 `SubscriptionClient` 下载成功，流量额度 header 可解析；51 节点（4 Trojan、43 AnyTLS、4 Hysteria2）、18 组、23 规则、20 inline rule-providers。失败根因是把 20 个内联项计入原来的最多 16 个远程资源。现只限制真正带 URL 的远程项 16，全部资源 256，保留 5 MB/结构限制；摘要增加向后兼容的可选 remoteResourceCount/inlineResourceCount，兼容性详情据此显示。SDK 核心预检及加密存储往返通过；不能声称该真实订阅的 51 个节点已经逐个通网。

`ProxySelection.delayTargets` 按嵌套组展开真实节点并去重，过滤 Direct/Reject/PassRule 等动作，含环保护；App、组控件和单项按钮共用同一目标集合。队列保留三并发和原超时/取消保护；新订阅或新会话调用 reset 清除旧汇总和迟到结果。只测 HTTPS 响应延迟 ms，手机仍须先连接 VPN，未实现独立离线核心或下载带宽测试。

订阅列表加蓝色“已选中”和绿色“使用中”文字胶囊与行底色；仅保存不会改变当前选择，切换和重启后标识保持正确。真实生产列表截图（使用合成 First/Second 测试数据）在 `docs/screenshots/subscription-selection-047.png`。

65 项 Release 单测、6 项模拟器 UI、48 项合成导入、12 组本地 TCP/UDP 协议互通、12 节点真实固定核心的嵌套组测速/超时/取消立即重试均通过。Release 构建和 App/Extension 签名通过。详见 `docs/validation/release-0.4.7.json` 和 `.build/features-047-*`。后续不需要无故重跑这组检查；真机与真实节点的联网质量另行验证，不把本地 loopback 测试等同真机验收。私人订阅 URL/正文/规范化文件/实验密钥与临时请求已清理，仅留脱敏报告；不读取或修改 Mac Clash Verge 的运行配置。

## HTTP 订阅与本轮手机验证（2026-11-01）

当前工作区 **0.4.6 (10)**，保留此前未提交的设置和测速修复。用户本轮明确授权安装到 PKR、添加指定地址并检查整个流程；仅本轮范围内可操作手机和 VPN，不据此推导以后自动控制手机。

HTTP 地址原先在解析/下载两层被拒绝。现已支持导入确认、每次下载独立的原站 HTTP 授权和已批准加密来源的刷新；禁止 HTTPS 降级、跨源 HTTP 重定向及凭据随跨源跳转发送。App 的 ATS 例外用于用户提供的 HTTP 地址，业务层仍逐请求检查；provider/地理资源保留 HTTPS 要求。

指定配置是 1 个 VLESS 节点、1 组、9 规则，无流量/到期 header。真机 UI 测试在初始化自动操作时超时，未进入页面。改用已有 DEBUG 单次请求入口调用生产流程，实际下载/加密保存、仅保存保持选择、刷新、确切版本连接、2/2 HTTPS 检查、核心实际流量增长、出口查询、断开及重连通过。后续修正后的复测仍调用相同生产模型和队列，批量结果为 1/1 成功、0 失败。网站当次为 Google/OpenAI/Claude available，YouTube timeout；不可宣称所有网站或 VLESS UDP 已验证。

发现核心 `PassRule` 占位项被当作节点：原配置 1 个节点，但运行列表包含 2 项且多一条失败。`ProxySelection.testableNames` 统一按名称与类型过滤，新增回归通过。复测前手机自动锁屏；用户随后明确回复“已解锁，继续完成”，修正后的真机应用内验证已完成：实际节点数 1，队列完成 1/1，可达 1，失败 0。没有重复添加订阅。

最终 **Release 0.4.6 (10)** 已重新覆盖安装并回读确认；不是验证用 Debug 构建。已有订阅和新加的“测试订阅1101”保留，最终验证结束 VPN 已断开；随后再次覆盖安装并成功打开正式版，设备版本回读为 0.4.6 (10)。61 项 Release 单测通过；6 个模拟器用例分别通过（旧非法 URL 用例由 HTTP 改为 FTP，首轮重试遇模拟器启动错误，随后串行重试成功）。构建、签名及 Release 不含验证入口检查通过。证据见 `docs/validation/release-0.4.6.json`。

本轮验证已结束，后续控制手机仍需用户明确授权。iOS 27.2 与当前 Xcode 的 UI 自动化初始化不稳定，不要反复盲跑；不能把应用内生产模型/队列验证称为完整真机界面自动化通过。确需再用应用内入口验证时，用单次缓存请求并复用当前选中的测试订阅，结束后恢复 Release。真实地址仅来自本轮用户消息，禁止写进源码/文档、日志公开或 Git 提交。私人临时原文/密钥及缓存请求已清理；正式订阅来源仍加密保存在手机。未提交或推送。

## 测速恢复修复（2026-10-30）

当前工作区版本 **0.4.5 (9)**，保留前一轮设置页重排。用户反馈“全部测速没有反应或一直不结束”。电脑上的无回包回归先失败，补上双层超时后通过；不能据此断言已经复现了手机上的唯一根因。

- `CallbackDeadline` 对扩展回包提供一次性完成、超时和取消；取消不再等待原来的 20 秒回包计时，迟到/重复回复不得污染新批次。`TunnelController` 回包状态校验显式回到 MainActor。
- `DelayTestRunner` 仍使用三个固定工作任务，不恢复曾崩溃的 TaskGroup；每个节点有 15 秒最终保护，IPC 通常 12 秒内返回或超时。开始/取消/中断/失败数量有可见反馈。
- `ProbeWorkQueue` 限制核心同时三个、总共最多六个等待或运行任务；允许一次取消后的替换批次排队，并在回包前释放名额。核心同步 URLTest 本身没有取消句柄，当前固定 SDK 的超时为 5 秒，不应承诺按取消就立刻终止底层网络调用。
- `python3 Scripts/test_delay_probes.py` 使用合成 loopback SS 服务、固定 SDK 和生产队列，验证 12 节点、三条无响应目标、取消后立即重试；不会创建系统 VPN、读取私人订阅或修改 Clash Verge 配置。

完整证据见 `docs/validation/release-0.4.5.json`。本轮不操作手机，不自动提交或推送；真机仍需用户明确允许后才能验证。手机最后已安装版本仍是 0.4.4 (8)。

## 本次 GitHub 提交（2026-10-28）

用户已明确要求将截至 0.4.4 (8) 的当前代码提交到 `cnodon/DashInto` 的 `main` 分支。提交记录以 Git 历史为准；早期章节中的“未提交”是当时状态。手机控制限制仍然有效，不因提交代码而恢复真机自动化。

## 当前优先约束（2026-10-28）

用户此前明确要求不要控制手机，真机自动化已停止。用户随后明确要求安装 0.4.4，已仅覆盖安装并打开核对版本，未运行真机自动化或切换 VPN。除此安装范围外，仍须等用户明确允许后，才可继续真机测试或更改 VPN；电脑和模拟器验证可以继续。

当前开发版本为 **0.4.4 (8)**：操作路径与五个 Tab 视觉优化已完成，首页在底部面板直接选节点，数据以面积图、额度环、延迟条和状态块展示。48 项 Release 单元测试、5 项模拟器 UI 测试、Release 构建和签名通过；2026-10-28 已按后续明确要求安装并启动 0.4.4 (8)，未自动测试或切换 VPN。使用 `.build/visual-044-*` 和 `docs/validation/release-0.4.4.json` 接续。DEBUG 模拟器只读示例入口必须标注示例数据，不能用来声称真实 VPN 测试通过。

历史 0.4.3 (7)：修复批量测速的 Release 专用 TaskGroup 故障，替换为三个固定工作任务；新增导入前订阅命名、自动名称与去重、已有订阅重命名，以及连接纸飞机/断开开关图标。48 项 Release 单元测试通过（`.build/fix-043-release-unit.log`）。模拟器 3 项原回归通过，命名/重命名用例修正 UIAlert 输入框查询后复测通过（`.build/fix-043-name-ui-retry.log`）。0.4.3 已安装并启动；真机批量测速曾完成一轮，但自动化未通过：第一轮遇到测速结束过快导致取消按钮消失，复测出现 AXErrorServerNotFound，尚不能宣称真机完整验收通过。保留 `.build/fix-043-physical*.log` 和结果包，禁止为确认结果再次操作手机。

原始崩溃本地证据 `.build/DashInto-delay-crash.ips`：0.4.2 (6)，主线程 EXC_BAD_ACCESS，栈顶 swift::TaskGroup::offer。原实现 Release 测试失败而 Debug 通过；固定工作任务后的 48 项 Release 测试通过。未提交或推送。

## 历史开发版本（0.4.2）

2026-10-28 用户要求进一步简化首页/订阅/设置，增加直连和代理批量延迟测试，改动已在工作区。版本为 0.4.2 (6)。先读 README 和 INTERACTION_REDESIGN.md 最新章节。44 项单元测试及固定 SDK 的三模式切换实验通过；模拟器回归、Release 构建与签名证据位于 `.build/compact-042-*`。已于 2026-10-28 覆盖安装到 PKR 并成功启动，版本回读为 0.4.2 (6)。本版真机 VPN 模式切换和真实订阅批量测速尚未验证；未提交、推送或创建 Release。

## 历史已部署版本（0.4.1）

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
