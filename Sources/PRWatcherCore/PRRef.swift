import Foundation

/// A pull request the user added by hand to watch, independent of the watched repos.
public struct PRRef: Codable, Hashable, Identifiable {
    public let owner: String
    public let name: String
    public let number: Int

    public var id: String { key }
    public var key: String { "\(owner)/\(name)#\(number)" }
    public var url: URL { URL(string: "https://github.com/\(owner)/\(name)/pull/\(number)")! }

    public init(owner: String, name: String, number: Int) {
        self.owner = owner
        self.name = name
        self.number = number
    }

    private static func isSafe(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
    }

    /// Accepts `https://github.com/owner/repo/pull/123` (optionally with `/files`, `#fragment`, query),
    /// `owner/repo/pull/123` and `owner/repo#123`.
    public static func parse(_ raw: String) -> PRRef? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        for host in ["www.github.com/", "github.com/"] where s.lowercased().hasPrefix(host) {
            s = String(s.dropFirst(host.count))
        }
        if let hash = s.firstIndex(of: "#"), s[s.index(after: hash)...].allSatisfy(\.isNumber),
           !s[..<hash].contains("/pull/") {
            // owner/repo#123 form
            let repo = s[..<hash].split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard repo.count == 2, let n = Int(s[s.index(after: hash)...]) else { return nil }
            return make(repo[0], repo[1], n)
        }
        if let cut = s.firstIndex(where: { $0 == "#" || $0 == "?" }) { s = String(s[..<cut]) }
        let parts = s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 4, parts[2] == "pull", let n = Int(parts[3]) else { return nil }
        return make(parts[0], parts[1], n)
    }

    private static func make(_ owner: String, _ name: String, _ n: Int) -> PRRef? {
        guard n > 0, isSafe(owner), isSafe(name) else { return nil }
        return PRRef(owner: owner, name: name, number: n)
    }
}
