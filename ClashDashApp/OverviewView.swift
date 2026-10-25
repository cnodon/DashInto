import SwiftUI
import ClashDashKit

struct SubscriptionPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.library.profiles) { profile in
                        Button {
                            Task { await model.activate(profile); dismiss() }
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack { Text(profile.name).foregroundStyle(.primary); Spacer(); if profile.id == model.displayProfile?.id { Image(systemName: "checkmark") } }
                                Text(profile.current?.summary.routeCountText ?? "已保存").font(.caption).foregroundStyle(.secondary)
                                Text(model.tunnel.phase == .stopped ? "选为下次连接使用" : "切换并重连").font(.caption)
                            }.padding(.vertical, 4)
                        }.disabled(model.connection.step.inProgress || model.busy)
                    }
                } footer: { Text(model.tunnel.phase == .stopped ? "选择订阅后，点连接即可。无需先选线路。" : "切换会短暂中断当前连接。") }
            }.navigationTitle("选择订阅").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
