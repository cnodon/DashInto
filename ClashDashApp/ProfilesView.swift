import SwiftUI
import UniformTypeIdentifiers
import ClashDashKit

struct ProfilesView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            if !model.library.profiles.isEmpty {
                Section {
                    ForEach(model.library.profiles) { profile in
                        SubscriptionListRow(profile: profile)
                    }
                }
            }
        }.overlay {
            if model.library.profiles.isEmpty {
                ContentUnavailableView("暂无订阅", systemImage: "rectangle.stack", description: Text("右上角 + 添加"))
            }
        }.contentMargins(.top, 8, for: .scrollContent).listSectionSpacing(.compact)
            .navigationTitle("").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("profilesPage")
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button { model.importURL = ""; model.showingImport = true } label: { Image(systemName: "plus") }.accessibilityLabel("添加订阅")
            } }
            .refreshable { for profile in model.library.profiles where profile.isSubscription { await model.refresh(profile) } }
    }
}

private struct SubscriptionListRow: View {
    @Environment(AppModel.self) private var model
    var profile: Profile
    private var running: Bool { model.tunnel.state == .connected && model.runningProfile?.id == profile.id }
    private var updatePending: Bool { running && model.hasPendingUpdate }
    var body: some View {
        HStack(spacing: 12) {
            NavigationLink { ProfileDetailView(profileID: profile.id) } label: {
                HStack(spacing: 12) {
                    if let balance = SubscriptionBalance(usage: profile.usage) { DashQuotaRing(fraction: balance.fraction, size: 48) }
                    else { DashGlyph(symbol: "rectangle.stack") }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Text(profile.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                            if running || model.library.selectedProfileID == profile.id {
                                Image(systemName: running ? "checkmark.circle.fill" : "checkmark.circle")
                                    .font(.caption).foregroundStyle(running ? Color.green : Color.dashBlue)
                                    .accessibilityLabel(running ? "正在使用" : "下次使用")
                            }
                        }
                        if let balance = SubscriptionBalance(usage: profile.usage) {
                            Text(DashFormat.bytes(balance.remaining) + " 剩余").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        } else { Text(profile.current?.summary.routeCountText ?? "已保存").font(.caption).foregroundStyle(.secondary) }
                        HStack(spacing: 8) {
                            Label { Text(profile.updatedAt, style: .relative) } icon: { Image(systemName: "arrow.clockwise") }
                            if let expiry = profile.usage?.expiresAt {
                                Label { if expiry < Date() { Text("已到期") } else { Text(expiry, format: .dateTime.month().day()) } } icon: { Image(systemName: "calendar") }
                                    .foregroundStyle(expiry < Date() ? Color.orange : Color.secondary)
                            }
                        }.font(.caption2).foregroundStyle(.tertiary)
                    }
                }.padding(.vertical, 6)
            }.accessibilityIdentifier("profileDetail-" + profile.name)
            Button { model.useAndConnect(profile) } label: {
                Group {
                    if model.refreshingProfileID == profile.id || model.connection.targetID == profile.id && model.connection.step.inProgress { ProgressView().controlSize(.small) }
                    else { Image(systemName: updatePending ? "arrow.clockwise" : running ? "checkmark" : "paperplane.fill") }
                }.font(.subheadline).frame(width: 44, height: 44)
                    .background((running ? Color.green : Color.dashBlue).opacity(0.08), in: Circle())
            }.buttonStyle(.borderless).disabled(model.connection.step.inProgress || model.busy || (running && !updatePending))
                .accessibilityLabel(updatePending ? "应用并重连" : running ? "正在使用" : "使用并连接")
                .accessibilityIdentifier("useProfile-" + profile.name)
        }
    }
}

struct ProfileDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var profileID: UUID
    @State private var showingDelete = false
    @State private var showingRename = false
    @State private var newName = ""
    private var profile: Profile? { model.library.profiles.first { $0.id == profileID } }
    var body: some View {
        List {
            if let profile {
                Section {
                    SubscriptionBalanceView(profile: profile)
                    LabeledContent("节点", value: profile.current?.summary.routeCountText ?? "已保存")
                    LabeledContent("更新时间") { Text(profile.updatedAt, format: .dateTime.month().day().hour().minute()) }
                }
                Section {
                    Button(model.tunnel.phase == .stopped ? "使用并连接" : "切换并重连") { model.useAndConnect(profile) }
                        .disabled(model.busy || model.connection.step.inProgress)
                    Button("下次连接使用") { Task { await model.activate(profile) } }
                        .disabled(model.busy || model.connection.step.inProgress || model.tunnel.phase != .stopped)
                    if profile.isSubscription {
                        Button { Task { await model.refresh(profile) } } label: {
                            HStack { Text("更新订阅"); Spacer(); if model.refreshingProfileID == profile.id { ProgressView() } }
                        }.disabled(model.refreshingProfileID != nil || model.busy || model.connection.step.inProgress)
                    }
                } footer: { Text("更新后重连生效") }
                Section {
                    Button("重命名") { newName = profile.name; showingRename = true }.disabled(model.busy || model.connection.step.inProgress)
                }
                Section { Button("删除订阅", role: .destructive) { showingDelete = true }.disabled(model.busy || model.connection.step.inProgress) }
            }
        }.navigationTitle(profile?.name ?? "配置详情").navigationBarTitleDisplayMode(.inline)
            .alert("订阅名称", isPresented: $showingRename) {
                TextField("订阅名称", text: $newName).accessibilityIdentifier("renameProfileName")
                Button("取消", role: .cancel) {}
                Button("保存") { if let profile { Task { await model.rename(profile, name: newName) } } }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog("删除这份配置？", isPresented: $showingDelete, titleVisibility: .visible) {
                Button("删除配置", role: .destructive) { if let profile { Task { await model.delete(profile); dismiss() } } }
            } message: { Text(model.activeProfile?.id == profileID && model.tunnel.state.isActive ? "当前连接将断开，配置及其历史版本会从本机删除。" : "配置及其历史版本会从本机删除。") }
    }
}

struct ImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var initialURL: String = ""
    @State private var address = ""
    @State private var name = ""
    @State private var generatedName = "我的订阅"
    @State private var prepared: PreparedConfiguration?
    @State private var sourceURL: URL?
    @State private var usage: SubscriptionUsage?
    @State private var loading = false
    @State private var saving = false
    @State private var stage = ""
    @State private var error: String?
    @State private var filePicker = false
    @State private var work: Task<Void, Never>?
    @State private var pastedContent = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("订阅名称") {
                    TextField("留空自动命名", text: $name).accessibilityIdentifier("profileName").disabled(saving)
                }
                if loading { Section { HStack { ProgressView(); Text(stage).font(.subheadline) } } }
                if prepared == nil {
                    Section {
                        TextField("https://你的订阅地址", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("subscriptionURL")
                        HStack {
                            Label("自动识别订阅格式", systemImage: "link").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            PasteButton(payloadType: String.self) { items in if let item = items.first { address = item.trimmingCharacters(in: .whitespacesAndNewlines) } }.labelStyle(.titleOnly).buttonBorderShape(.capsule)
                        }
                        Button { readSubscription() } label: {
                            HStack { Text(loading ? stage : "继续"); Spacer(); if loading { ProgressView() } else { Image(systemName: "arrow.right") } }
                        }.disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading).accessibilityIdentifier("readSubscription")
                    } header: { Text("订阅链接") } footer: { Text("优先选择 Clash/mihomo 链接以保留完整分流和 DNS。Shadowrocket 常见节点订阅也可自动识别，会生成节点选择策略。") }
                    Section {
                        DisclosureGroup("粘贴节点或配置") {
                            TextEditor(text: $pastedContent).font(.system(.footnote, design: .monospaced)).frame(minHeight: 130)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("nodeContent")
                            PasteButton(payloadType: String.self) { items in pastedContent = items.joined(separator: "\n") }.labelStyle(.titleOnly)
                            Button("读取粘贴内容") { prepare(pastedContent, proposedName: "我的节点") }.disabled(pastedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
                                .accessibilityIdentifier("readPastedContent")
                        }
                        Button("从配置文件导入", systemImage: "doc.badge.plus") { filePicker = true }.disabled(loading)
                    } footer: { Text("支持常见分享链接、Base64 节点订阅和部分客户端节点配置；不支持的记录会在保存前提示。") }
                } else if let prepared {
                    Section("已准备好连接") {
                        Label(prepared.summary.routeCountText, systemImage: "network")
                        Text(prepared.summary.isDirectOnly ? "此配置只直接连接，不提供代理线路。" : "将使用订阅默认选择。可以直接连接，也可以稍后在线路页调整。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !prepared.summary.warnings.isEmpty {
                        Section { Label("有 \(prepared.summary.warnings.count) 条适配说明，可在下方查看。", systemImage: "info.circle").font(.subheadline).foregroundStyle(.secondary) }
                    }
                    Section {
                        DisclosureGroup("格式与兼容性详情") {
                        LabeledContent("识别格式", value: prepared.summary.sourceFormat ?? "Clash / mihomo")
                        LabeledContent("静态节点", value: "\(prepared.summary.nodes.count)")
                        LabeledContent("代理组", value: "\(prepared.summary.groups.count)")
                        LabeledContent("规则", value: "\(prepared.summary.rules.count)")
                        LabeledContent("远程资源", value: "\(prepared.summary.providerCount)")

                        Text("导入检查通过，连接后验证网络可达性。").font(.caption).foregroundStyle(.secondary)
                        ForEach(prepared.summary.warnings, id: \.self) { warning in Text(warning).font(.subheadline).foregroundStyle(.secondary) }
                    }
                        }
                    Section {
                        Button("重新选择来源") { self.prepared = nil; sourceURL = nil; usage = nil }.disabled(saving)
                    }
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange) } }
                Section { Label("订阅地址和节点凭据加密保存在本机。", systemImage: "lock.shield").font(.footnote).foregroundStyle(.secondary) }
            }.id(prepared == nil ? "entry" : "preview")
                .navigationTitle(prepared == nil ? "添加订阅" : "导入预览").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    if prepared != nil {
                        VStack(spacing: 8) {
                            DashPrimaryButton(title: saving ? "正在保存" : model.tunnel.phase == .stopped ? "使用并连接" : "切换并重连") { save(connect: true) }
                                .disabled(saving || model.busy || model.connection.step.inProgress)
                                .accessibilityIdentifier("useAndConnect")
                            Button("仅保存") { save(connect: false) }.frame(minHeight: 44).disabled(saving)
                                .accessibilityIdentifier("saveProfile")
                            Text(model.tunnel.phase == .stopped ? "仅保存不会选中或连接这份订阅。" : "切换会短暂中断连接；仅保存会保留当前连接。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal, 20).padding(.vertical, 10).background(.regularMaterial)
                    }
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { work?.cancel(); dismiss() }.disabled(saving) } }
                .interactiveDismissDisabled(saving)
                .scrollDismissesKeyboard(.interactively)
                .onAppear { address = initialURL }
                .onDisappear { work?.cancel() }
                .fileImporter(isPresented: $filePicker, allowedContentTypes: [.yaml, .json, .plainText, .data]) { result in
                    switch result {
                    case .success(let url):
                        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        do {
                            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                            guard size <= DashConstants.maximumConfigurationBytes else { throw DashError.message("配置超过 5 MB。") }
                            let text = try String(contentsOf: url, encoding: .utf8)
                            prepare(text, proposedName: url.deletingPathExtension().lastPathComponent)
                        } catch { self.error = error.localizedDescription }
                    case .failure(let error): self.error = error.localizedDescription
                    }
                }
        }
    }
    private func readSubscription() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if ImportAddress.isNodeLink(trimmed) { prepare(trimmed, proposedName: "我的节点"); return }
        error = nil; loading = true; stage = "读取订阅"
        work?.cancel()
        work = Task {
            defer { loading = false }
            do {
                let url = try ImportAddress.subscriptionURL(from: trimmed)
                let download = try await SubscriptionClient().download(url)
                try Task.checkCancellation(); stage = "识别线路"
                let parsed = try await Task.detached { try NativeConfigImporter.prepare(download.text) }.value
                try Task.checkCancellation()
                let result = try await NativeResourcePreparer.shared.prepare(parsed) { value in await MainActor.run { stage = value } }
                try Task.checkCancellation()
                prepared = result; sourceURL = url; usage = download.usage
                applySuggestedName(download.suggestedName, url: url, fallback: "我的订阅")
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func prepare(_ text: String, proposedName: String) {
        error = nil; loading = true; stage = "识别线路"
        work?.cancel()
        work = Task {
            defer { loading = false }
            do {
                let parsed = try await Task.detached { try NativeConfigImporter.prepare(text) }.value
                try Task.checkCancellation()
                let result = try await NativeResourcePreparer.shared.prepare(parsed) { value in await MainActor.run { stage = value } }
                try Task.checkCancellation(); prepared = result; sourceURL = nil; usage = nil
                applySuggestedName(proposedName, url: nil, fallback: "我的节点")
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func applySuggestedName(_ suggestion: String?, url: URL?, fallback: String) {
        let automatic = SubscriptionNaming.resolve(suggested: suggestion, sourceURL: url, fallback: fallback,
                                                   existing: model.library.profiles.map(\.name))
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == generatedName { name = automatic }
        generatedName = automatic
    }
    private func save(connect: Bool) {
        guard let prepared, !saving else { return }
        saving = true; error = nil
        work = Task {
            defer { saving = false }
            do {
                let commit = try await model.save(prepared, name: SubscriptionNaming.resolve(input: name, suggested: generatedName), url: sourceURL, usage: usage)
                if connect, let exact = commit.library.profiles.first(where: { $0.id == commit.profileID && $0.selectedVersion == commit.generation }) {
                    model.useAndConnect(exact)
                } else { model.selectedTab = .subscriptions; model.notice = "订阅已保存。可在列表中使用并连接。" }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
