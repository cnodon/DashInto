import Foundation

public enum SubscriptionNaming {
    public static func resolve(input: String = "", suggested: String? = nil, sourceURL: URL? = nil,
                               fallback: String = "我的订阅", existing: [String] = []) -> String {
        let custom = cleaned(input)
        var suggested = suggested ?? ""
        if suggested.lowercased().hasPrefix("base64:") {
            suggested = Data(base64Encoded: String(suggested.dropFirst(7)))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        let base = [custom, cleaned(suggested), cleaned(sourceURL?.host ?? ""), cleaned(fallback), "我的订阅"]
            .first { !$0.isEmpty }!
        let used = Set(existing.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        var result = base, index = 2
        while used.contains(result.precomposedStringWithCanonicalMapping.lowercased()) {
            result = "\(base) (\(index))"; index += 1
        }
        return result
    }
    private static func cleaned(_ input: String) -> String {
        let words = input.components(separatedBy: .whitespacesAndNewlines.union(.controlCharacters)).filter { !$0.isEmpty }
        return String(words.joined(separator: " ").prefix(80))
    }
}
