// Run through test_delay_probes.py; uses the pinned core and production scheduling on loopback only.
import Foundation
import Clash
import ClashDashKit

@main struct DelayProbe {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fastURL = CommandLine.arguments[2], slowURL = CommandLine.arguments[3]
        let setup = ClashSetupOptions()
        setup.basePath = root.path; setup.workingPath = root.path; setup.tempPath = root.path
        setup.runtimeProfile = "macosApplication"; setup.maxProcs = 4; setup.logMaxLines = 10
        var error: NSError?
        ClashSetup(setup, &error)
        if let error { throw error }
        guard let core = ClashNewService(HostPlatform(), &error) else { throw error ?? URLError(.unknown) }
        try core.start(String(contentsOf: root.appendingPathComponent("client.json"), encoding: .utf8))
        defer { try? core.close() }
        let queue = ProbeWorkQueue(), runner = DelayTestRunner()
        let preparation = DelayTestPreparation()
        var results: [String: Int] = [:]
        func probe(_ name: String, url: String) async throws -> Int {
            try await CallbackDeadline.run(timeout: 12) { reply in
                guard queue.submit(operation: { Int(ClashURLTest(name, url)) }, completion: { reply(.success($0)) }) else {
                    throw URLError(.cannotLoadFromNetwork)
                }
                return nil
            }
        }
        func waitForFinish() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while (preparation.isPreparing || runner.isRunning) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard !preparation.isPreparing, preparation.failure == nil, !runner.isRunning else { throw URLError(.timedOut) }
        }
        let names = (0..<12).map { "Local\($0)" }
        let groups = [ProxyGroup(name: "Inner", kind: "select", members: Array(names.prefix(6))),
                      ProxyGroup(name: "Outer", kind: "select", members: ["Inner"] + names + ["DIRECT", "PASS-RULE"])]
        let targets = ProxySelection.delayTargets(["Outer"], nodes: names.map { ProxyNode(name: $0, kind: "ss") }, groups: groups, runtimeKinds: ["PASS-RULE": "PassRule"])
        guard targets == names else { throw URLError(.badServerResponse) }
        preparation.start(prepare: {
            try await Task.sleep(for: .milliseconds(20))
            return targets
        }, ready: { nodes in
            runner.start(names: nodes, isCurrent: { true }, test: { try await probe($0, url: fastURL) }, receive: { results[$0] = $1 })
        })
        guard preparation.isPreparing else { throw URLError(.badServerResponse) }
        try await waitForFinish()
        guard results.count == 12, runner.succeeded == 12 else { throw URLError(.badServerResponse) }
        print("PREPARATION_TO_BULK_12_REAL_CORE_PASSED")
        print("BULK_12_REAL_CORE_PASSED")
        print("NESTED_GROUP_12_UNIQUE_NODES_PASSED")

        results = [:]
        runner.start(names: Array(names.prefix(3)), isCurrent: { true }, test: { try await probe($0, url: slowURL) }, receive: { results[$0] = $1 })
        try await waitForFinish()
        guard runner.failed == 3, results.values.allSatisfy({ $0 < 0 }) else { throw URLError(.badServerResponse) }
        print("UNRESPONSIVE_TARGET_FINISHED_3_OF_3")

        runner.start(names: Array(names.prefix(3)), isCurrent: { true }, test: { try await probe($0, url: slowURL) }, receive: { _, _ in })
        try await Task.sleep(for: .milliseconds(200))
        runner.cancel()
        results = [:]
        runner.start(names: names, isCurrent: { true }, test: { try await probe($0, url: fastURL) }, receive: { results[$0] = $1 })
        try await waitForFinish()
        guard results.count == 12, runner.succeeded == 12 else { throw URLError(.badServerResponse) }
        print("CANCEL_AND_IMMEDIATE_RETRY_12_PASSED")
    }
}
