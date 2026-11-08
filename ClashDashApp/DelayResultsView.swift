import SwiftUI
import ClashDashKit

struct DelayResultsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var failuresOnly = false
    private var runner: DelayTestRunner { model.delayTests }
    private var names: [String] {
        failuresOnly ? runner.failedNames : runner.names
    }
    var body: some View {
        NavigationStack {
            List {
                #if DEBUG && targetEnvironment(simulator)
                if CommandLine.arguments.contains("--ui-test-delay-results") { Text("界面测试 · 示例数据").foregroundStyle(.orange) }
                #endif
                Section {
                    HStack {
                        metric("可用", runner.succeeded, .green)
                        metric("超时", runner.timedOut, .orange)
                        metric("失败", runner.errors, .red)
                        metric("未完成", runner.total - runner.completed, .secondary)
                    }
                    if let start = runner.startedAt {
                        LabeledContent("开始", value: start.formatted(.dateTime.hour().minute().second()))
                    }
                    LabeledContent("测试目标", value: model.lastDelayEndpoint.title)
                    if let message = runner.interruption { Text(message).font(.caption).foregroundStyle(.secondary) }
                    if model.delayPreparation.isPreparing { Label("正在准备重测…", systemImage: "hourglass") }
                    if let error = model.delayPreparation.failure { Text(error).font(.caption).foregroundStyle(.orange) }
                } footer: { Text("HTTPS 响应延迟，单位 ms。仅代表测试时访问该目标的情况。") }
                Section {
                    Button("仅重测失败（\(runner.failedNames.count)）") { model.startDelayTests(runner.failedNames) }
                        .disabled(model.delayTestBusy || runner.failedNames.isEmpty).accessibilityIdentifier("retryFailedDelays")
                    if !runner.isRunning && !runner.unfinishedNames.isEmpty {
                        Button("继续未完成（\(runner.unfinishedNames.count)）") { model.startDelayTests(runner.unfinishedNames) }
                            .disabled(model.delayTestBusy).accessibilityIdentifier("resumeUnfinishedDelays")
                    }
                    if model.delayTestBusy {
                        Button("取消测速", role: .destructive) { model.cancelDelayTests() }
                    }
                    Toggle("只看未通过", isOn: $failuresOnly)
                }
                Section("节点 · \(names.count)") {
                    ForEach(names, id: \.self) { name in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(name).font(.subheadline)
                                if let date = runner.resultDates[name] {
                                    Text(date, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let delay = runner.results[name] { DelayIndicator(milliseconds: delay) }
                            else if runner.testingNames.contains(name) { ProgressView().controlSize(.small) }
                            else { Text(runner.isRunning ? "等待" : "未测试").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }.accessibilityIdentifier("delayResultsPage").navigationTitle("测速结果").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
    private func metric(_ title: String, _ value: Int, _ tint: Color) -> some View {
        VStack(spacing: 5) {
            Text(value, format: .number).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}
