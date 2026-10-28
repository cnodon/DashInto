// Runs in a separate macOS process; does not create or alter any system VPN.
import Foundation
import Clash
import Darwin

final class HostPlatform: NSObject, ClashPlatformInterfaceProtocol {
    func writeLog(_ message: String?) {}
    func underNetworkExtension() -> Bool { false }
    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_ fd: Int32) throws {}
    func openTun(_ options: (any ClashTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw NSError(domain: "ClashDashCoreLab", code: 1, userInfo: [NSLocalizedDescriptionKey: "The host probe must not create a system tunnel"])
    }
    func startDefaultInterfaceMonitor(_ listener: (any ClashInterfaceUpdateListenerProtocol)?) throws {
        listener?.updateDefaultInterface("lo0", interfaceIndex: Int32(if_nametoindex("lo0")), isExpensive: false, isConstrained: false, supportsIPv4: true, supportsIPv6: true)
    }
    func closeDefaultInterfaceMonitor(_ listener: (any ClashInterfaceUpdateListenerProtocol)?) throws {}
    func getInterfaces() throws -> any ClashNetworkInterfaceIteratorProtocol { HostInterfaces() }
}
final class HostInterfaces: NSObject, ClashNetworkInterfaceIteratorProtocol {
    private var available = true
    func len() -> Int32 { 1 }
    func hasNext() -> Bool { available }
    func next() -> ClashNetworkInterface? {
        guard available else { return nil }; available = false
        let value = ClashNetworkInterface(); value.name = "lo0"; value.index = Int32(if_nametoindex("lo0"))
        value.mtu = 16384; value.flags = 37; value.type = 4; return value
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let options = ClashSetupOptions()
options.basePath = root.path; options.workingPath = root.path; options.tempPath = root.path
options.runtimeProfile = "macosApplication"; options.maxProcs = 4; options.logMaxLines = 20
var error: NSError?
ClashSetup(options, &error)
if let error { fatalError(error.localizedDescription) }
let file = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "client.yaml"
let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
ClashCheckConfig(text, &error)
if let error { fatalError(error.localizedDescription) }
guard let core = ClashNewService(HostPlatform(), &error) else { fatalError(error?.localizedDescription ?? "Core creation failed") }
try core.start(text)
ClashSelectProxy("Select", "LoopbackSS", &error)
if let error { fatalError(error.localizedDescription) }
let delay = ClashURLTest("LoopbackSS", CommandLine.arguments[2])
if CommandLine.arguments.count > 4 && CommandLine.arguments[4] == "reject-tls" {
    try core.close()
    print("TLS_REJECTION", delay < 0)
    exit(delay < 0 ? 0 : 1)
}
let tcpOnly = CommandLine.arguments.count > 4 && CommandLine.arguments[4] == "tcp-only"
let dns = tcpOnly ? "not-requested" : ClashDNSQueryJSON("clashdash.test", "A")
print("CORE_VERSION", ClashVersion())
print("TCP_SS_DELAY_MS", delay)
print("UDP_DNS_RESULT", dns)
print("MEMORY_BYTES", ClashMemoryFootprint())
print("TRAFFIC", ClashTrafficJSON())
try core.setMode("global")
guard core.mode() == "global" else { fatalError("Mode change was not committed") }
try core.setMode("direct")
guard core.mode() == "direct" else { fatalError("Direct mode was not committed") }
try core.setMode("rule")
guard core.mode() == "rule" else { fatalError("Rule mode was not restored") }
print("MODES_VERIFIED", "global,direct,rule")
try core.close()
guard delay >= 0, tcpOnly || dns.contains("203.0.113.7") else { exit(1) }
