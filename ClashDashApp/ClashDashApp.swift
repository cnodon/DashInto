import SwiftUI

@main
struct ClashDashApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup {
            RootView().environment(model)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .task {
                    guard !DashboardPresentation.preview else { return }
                    await model.load()
                    #if DEBUG && targetEnvironment(simulator)
                    if DashboardPresentation.delayResults { await model.seedDelayResultsForUITest(); return }
                    if AppModel.automaticRefreshUITest { await model.seedBlockedRefreshForUITest(); return }
                    #endif
                    model.resume()
                    Task { await model.updates.check() }
                    #if DEBUG
                    await DeviceValidation.runIfRequested(model)
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    guard !DashboardPresentation.preview && !DashboardPresentation.delayResults && !AppModel.automaticRefreshUITest else { return }
                    if phase == .active { Task { await model.load(); model.resume(); await model.updates.check() } }
                    else if phase == .background { model.suspend(); model.updates.scheduleBackgroundCheck() }
                }
                .onOpenURL { url in
                    guard ["clashdash", "dashinto"].contains(url.scheme ?? ""), url.host == "import",
                          let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value else { return }
                    model.importURL = value; model.showingImport = true
                }
        }
        .backgroundTask(.appRefresh(SubscriptionUpdates.backgroundID)) {
            await model.load()
            await model.refreshDueSubscriptions()
            await model.subscriptionUpdates.schedule(profiles: model.library.profiles)
        }
        .backgroundTask(.appRefresh(AppUpdates.backgroundID)) {
            await model.updates.check()
            await model.updates.scheduleBackgroundCheck()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder private var home: some View {
        #if DEBUG && targetEnvironment(simulator)
        if DashboardPresentation.preview { DashboardDesignPreview() } else { OverviewView() }
        #else
        OverviewView()
        #endif
    }
    var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
            let sidebar = DashLayout.showsSidebar(width: geometry.size.width, accessibilitySize: typeSize.isAccessibilitySize)
            HStack(spacing: 0) {
                if sidebar { navigationSidebar.frame(width: 220); Divider() }
                // Keep the same TabView identity during rotation/window resizing:
                // search fields, navigation stacks and presented sheets stay intact.
                TabView(selection: $model.selectedTab) {
                    NavigationStack { home }.toolbar(sidebar ? .hidden : .visible, for: .tabBar).tabItem { Label("首页", systemImage: "waveform.path") }.tag(AppTab.home)
                    NavigationStack { ProfilesView() }.toolbar(sidebar ? .hidden : .visible, for: .tabBar).tabItem { Label("订阅", systemImage: "rectangle.stack") }.tag(AppTab.subscriptions)
                    NavigationStack { PoliciesView() }.toolbar(sidebar ? .hidden : .visible, for: .tabBar).tabItem { Label("代理", systemImage: "circle.grid.2x2") }.tag(AppTab.proxies)
                    NavigationStack { DeviceInfoView() }.toolbar(sidebar ? .hidden : .visible, for: .tabBar).tabItem { Label("本机信息", systemImage: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") }.tag(AppTab.device)
                    NavigationStack { SettingsView() }.toolbar(sidebar ? .hidden : .visible, for: .tabBar).tabItem { Label("设置", systemImage: "gearshape") }.badge(model.updates.hasUpdate ? "新" : nil).tag(AppTab.settings)
                }
            }
        }
        .tint(.dashBlue)
        .sheet(isPresented: $model.showingImport) { ImportView(initialURL: model.importURL) }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .overlay(alignment: .top) {
            if let notice = model.notice {
                Text(notice).font(.subheadline).padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule()).shadow(color: .black.opacity(0.06), radius: 14, y: 5)
                    .padding(.top, 8).task(id: notice) { try? await Task.sleep(for: .seconds(3)); if !Task.isCancelled && model.notice == notice { model.notice = nil } }
                    .onTapGesture { model.notice = nil }.transition(.opacity)
            }
        }
        .animation(DashMotion.state, value: model.notice != nil)
    }
    private var navigationSidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("DashInto").font(.title2.weight(.semibold)).tracking(-0.6)
                .padding(.horizontal, 24).padding(.top, 28)
            List {
                sidebarItem(.home, title: "首页", symbol: "waveform.path")
                sidebarItem(.subscriptions, title: "订阅", symbol: "rectangle.stack")
                sidebarItem(.proxies, title: "代理", symbol: "circle.grid.2x2")
                sidebarItem(.device, title: "本机信息", symbol: "ipad")
                sidebarItem(.settings, title: "设置", symbol: "gearshape")
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            Label(model.tunnel.state.title, systemImage: "shield.lefthalf.filled")
                .font(.caption).foregroundStyle(model.tunnel.state == .connected ? Color.green : Color.secondary)
                .padding(24).accessibilityIdentifier("sidebarConnectionStatus")
        }.background(Color.dashBackground).accessibilityIdentifier("iPadSidebar")
    }
    private func sidebarItem(_ tab: AppTab, title: String, symbol: String) -> some View {
        Button { model.selectedTab = tab } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 22)
                Text(title)
                Spacer(minLength: 0)
                if tab == .settings && model.updates.hasUpdate {
                    Circle().fill(Color.dashBlue).frame(width: 7, height: 7).accessibilityLabel("有新版本")
                }
            }.font(.subheadline.weight(model.selectedTab == tab ? .semibold : .regular))
                .foregroundStyle(model.selectedTab == tab ? Color.dashBlue : Color.primary)
                .frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .listRowSeparator(.hidden)
            .listRowBackground(RoundedRectangle(cornerRadius: 12).fill(model.selectedTab == tab ? Color.dashBlue.opacity(0.1) : Color.clear))
            .accessibilityAddTraits(model.selectedTab == tab ? .isSelected : [])
            .accessibilityIdentifier("sidebar-" + String(tab.rawValue))
    }

}

private enum DashboardPresentation {
    static var delayResults: Bool {
        #if DEBUG && targetEnvironment(simulator)
        CommandLine.arguments.contains("--ui-test-delay-results") && CommandLine.arguments.contains {
            $0.hasPrefix("--ui-test-library=") && UUID(uuidString: String($0.dropFirst("--ui-test-library=".count))) != nil
        }
        #else
        false
        #endif
    }
    static var preview: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return CommandLine.arguments.contains("--ui-test-dashboard-preview") && CommandLine.arguments.contains { value in
            value.hasPrefix("--ui-test-library=") && UUID(uuidString: String(value.dropFirst("--ui-test-library=".count))) != nil
        }
        #else
        return false
        #endif
    }
}
