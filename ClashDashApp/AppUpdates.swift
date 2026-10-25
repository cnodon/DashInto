import SwiftUI
import Observation
import BackgroundTasks
import UserNotifications
import ClashDashKit

@Observable @MainActor
final class AppUpdates {
    static let backgroundID = "app.clashdash.update-check"
    var repository = UserDefaults.standard.string(forKey: "updates.repository") ?? (Bundle.main.object(forInfoDictionaryKey: "DashGitHubRepository") as? String ?? "")
    var automatic = UserDefaults.standard.object(forKey: "updates.automatic") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "updates.automatic"); scheduleBackgroundCheck() }
    }
    var development = UserDefaults.standard.object(forKey: "updates.development") as? Bool ?? true {
        didSet { UserDefaults.standard.set(development, forKey: "updates.development"); latest = nil; lastChecked = nil; UserDefaults.standard.removeObject(forKey: "updates.release"); UserDefaults.standard.removeObject(forKey: "updates.checked") }
    }
    var notifications = UserDefaults.standard.bool(forKey: "updates.notifications")
    var latest: GitHubRelease?
    var lastChecked: Date?
    var checking = false
    var error: String?
    var hasUpdate: Bool {
        guard let candidate = latest?.version,
              let installed = AppReleaseVersion(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                                                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") else { return false }
        return candidate > installed
    }
    var releaseURL: URL? { (try? GitHubRepository(repository)).flatMap { latest?.trustedURL(repository: $0) } }
    var testFlightURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "DashTestFlightURL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host == "testflight.apple.com", url.path.hasPrefix("/join/") else { return nil }
        return url
    }
    init() {
        if let cache = UserDefaults.standard.data(forKey: "updates.release") { latest = try? JSONDecoder().decode(GitHubRelease.self, from: cache) }
        lastChecked = UserDefaults.standard.object(forKey: "updates.checked") as? Date
    }
    func setRepository(_ input: String) throws {
        repository = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : try GitHubRepository(input).path
        UserDefaults.standard.set(repository, forKey: "updates.repository")
        latest = nil; lastChecked = nil; error = nil
        UserDefaults.standard.removeObject(forKey: "updates.release"); UserDefaults.standard.removeObject(forKey: "updates.checked")
        scheduleBackgroundCheck()
    }
    func check(force: Bool = false) async {
        guard !checking, !repository.isEmpty, force || automatic,
              force || Date().timeIntervalSince(lastChecked ?? .distantPast) >= 6 * 3600 else { return }
        checking = true; error = nil
        let requested = repository, channel = development
        defer { checking = false }
        do {
            let value = try await GitHubUpdateClient.latest(repository: GitHubRepository(requested), includeDevelopment: channel)
            try Task.checkCancellation()
            guard repository == requested, development == channel else { return }
            latest = value; lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: "updates.checked")
            if let value { UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: "updates.release") }
            else { UserDefaults.standard.removeObject(forKey: "updates.release") }
            if hasUpdate, notifications, let value,
               UserDefaults.standard.string(forKey: "updates.notified") != requested + "/" + value.tag_name {
                let content = UNMutableNotificationContent()
                content.title = "DashInto 有新版本"; content.body = value.tag_name + " · 打开设置查看更新说明"; content.sound = .default
                try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "clashdash-update", content: content, trigger: nil))
                UserDefaults.standard.set(requested + "/" + value.tag_name, forKey: "updates.notified")
            }
        } catch is CancellationError { }
        catch { if repository == requested { self.error = error.localizedDescription } }
    }
    func setNotifications(_ value: Bool) async {
        if value {
            do { notifications = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
            catch { notifications = false; self.error = "未能取得通知权限。" }
        } else { notifications = false }
        UserDefaults.standard.set(notifications, forKey: "updates.notifications")
    }
    func scheduleBackgroundCheck() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundID)
        guard automatic, !repository.isEmpty else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundID)
        request.earliestBeginDate = Date().addingTimeInterval(6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}

struct AppUpdateView: View {
    @Environment(AppModel.self) private var model
    @State private var repositoryInput = ""
    @State private var validation: String?
    var body: some View {
        @Bindable var updates = model.updates
        List {
            Section {
                LabeledContent("已安装", value: DashConstants.appVersion)
                if updates.hasUpdate, let release = updates.latest {
                    Label("新版本 " + release.tag_name, systemImage: "arrow.down.circle").foregroundStyle(Color.dashBlue)
                } else if let date = updates.lastChecked {
                    Text(updates.latest == nil ? "尚无已发布版本" : "当前没有更新").font(.subheadline)
                    LabeledContent("上次检查") { Text(date, format: .dateTime.month().day().hour().minute()) }
                }
                Button { Task { await updates.check(force: true) } } label: {
                    HStack { Text("检查更新"); Spacer(); if updates.checking { ProgressView() } }
                }.disabled(updates.checking || updates.repository.isEmpty).accessibilityIdentifier("checkAppUpdate")
                if let error = updates.error ?? validation { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            Section("GitHub 仓库") {
                TextField("https://github.com/owner/repository", text: $repositoryInput).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("updateRepository")
                Button("保存仓库") {
                    do { try updates.setRepository(repositoryInput); repositoryInput = updates.repository; validation = nil; Task { await updates.check(force: true) } }
                    catch { validation = error.localizedDescription }
                }.disabled(updates.checking)
            }
            Section {
                Toggle("自动检查新版本", isOn: $updates.automatic)
                Toggle("包含开发版本", isOn: $updates.development)
                Toggle("发现更新时通知", isOn: Binding(get: { updates.notifications }, set: { value in Task { await updates.setNotifications(value) } }))
            } footer: { Text("打开 App 时检查；后台检查时间由 iOS 安排，不能保证每次推送代码后立即收到通知。只读取所选公共仓库的发布版本。") }
            if let release = updates.latest {
                Section("更新说明") { Text(release.body ?? "此版本未提供说明。").font(.subheadline).textSelection(.enabled) }
                if let url = updates.releaseURL { Section { Link("查看 GitHub 版本", destination: url) } }
            }
            Section {
                if let url = updates.testFlightURL { Link("在 TestFlight 中打开", destination: url) }
                else { Text("等待首次 TestFlight 发布").foregroundStyle(.secondary) }
            } header: { Text("TestFlight") } footer: { Text(updates.testFlightURL == nil ? "TestFlight 安装入口尚未配置；当前真机版可用 Mac / Xcode 更新。" : "自动安装由 TestFlight 管理，可在 TestFlight 中开启自动更新。") }
        }.navigationTitle("软件更新").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .onAppear { repositoryInput = updates.repository }
    }
}
