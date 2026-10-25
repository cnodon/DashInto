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
                    await model.load(); model.resume()
                    Task { await model.updates.check() }
                    #if DEBUG
                    await DeviceValidation.runIfRequested(model)
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.load(); model.resume(); await model.updates.check() } }
                    else if phase == .background { model.suspend(); model.updates.scheduleBackgroundCheck() }
                }
                .onOpenURL { url in
                    guard ["clashdash", "dashinto"].contains(url.scheme ?? ""), url.host == "import",
                          let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value else { return }
                    model.importURL = value; model.showingImport = true
                }
        }
        .backgroundTask(.appRefresh(AppUpdates.backgroundID)) {
            await model.updates.check()
            await model.updates.scheduleBackgroundCheck()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            NavigationStack { OverviewView() }.tabItem { Label("首页", systemImage: "waveform.path") }.tag(AppTab.home)
            NavigationStack { ProfilesView() }.tabItem { Label("订阅", systemImage: "rectangle.stack") }.tag(AppTab.subscriptions)
            NavigationStack { PoliciesView() }.tabItem { Label("代理", systemImage: "circle.grid.2x2") }.tag(AppTab.proxies)
            NavigationStack { DeviceInfoView() }.tabItem { Label("本机信息", systemImage: "iphone") }.tag(AppTab.device)
            NavigationStack { SettingsView() }.tabItem { Label("设置", systemImage: "gearshape") }.badge(model.updates.hasUpdate ? "新" : nil).tag(AppTab.settings)
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
}
