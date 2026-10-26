import Foundation

public enum SMBURL {
    /// Characters allowed in the user-info part, minus the ones with structural meaning for SMB URLs.
    private static let userAllowed: CharacterSet = {
        var set = CharacterSet.urlUserAllowed
        set.remove(charactersIn: ";:@/?#")
        return set
    }()

    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "?#;")
        return set
    }()

    /// Builds `smb://[DOMAIN;][user@]host[:port]/share`.
    ///
    /// The password is deliberately never embedded; it is handed to NetFS separately.
    public static func make(address: ServerAddress, share: String, auth: AuthMode, username: String, domain: String) -> URL? {
        var host = address.trimmedHost
        guard !host.isEmpty else { return nil }
        // Bare IPv6 literals need brackets.
        if host.contains(":") && !host.hasPrefix("[") { host = "[\(host)]" }

        var userInfo = ""
        switch auth {
        case .registered where !username.isEmpty:
            let user = username.addingPercentEncoding(withAllowedCharacters: userAllowed) ?? username
            if !domain.isEmpty {
                let dom = domain.addingPercentEncoding(withAllowedCharacters: userAllowed) ?? domain
                userInfo = "\(dom);\(user)@"
            } else {
                userInfo = "\(user)@"
            }
        case .guest:
            userInfo = "guest:@"
        default:
            break
        }

        let port = address.port.flatMap { $0 == 445 ? nil : ":\($0)" } ?? ""
        let trimmedShare = share.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let encodedShare = trimmedShare.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? trimmedShare
        return URL(string: "smb://\(userInfo)\(host)\(port)/\(encodedShare)")
    }

    public struct Parsed: Equatable, Sendable {
        public var host: String
        public var port: Int?
        public var share: String
        public var username: String
        public var domain: String
    }

    /// Parses an smb:// URL (as found in Finder's recent servers or `mount` output).
    public static func parse(_ string: String) -> Parsed? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("smb://") { s.removeFirst(6) } else if s.hasPrefix("//") { s.removeFirst(2) } else { return nil }
        var userPart = ""
        if let at = s.lastIndex(of: "@"), s[..<at].firstIndex(of: "/") == nil {
            userPart = String(s[..<at])
            s = String(s[s.index(after: at)...])
        }
        let hostPart: String
        var sharePart = ""
        if let slash = s.firstIndex(of: "/") {
            hostPart = String(s[..<slash])
            sharePart = String(s[s.index(after: slash)...])
        } else {
            hostPart = s
        }
        var host = hostPart
        var port: Int?
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            let rest = host[host.index(after: close)...]
            if rest.hasPrefix(":") { port = Int(rest.dropFirst()) }
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
            port = Int(host[host.index(after: colon)...])
            host = String(host[..<colon])
        }
        var domain = ""
        var user = userPart
        if let colon = user.firstIndex(of: ":") { user = String(user[..<colon]) }
        if let semi = user.firstIndex(of: ";") {
            domain = String(user[..<semi])
            user = String(user[user.index(after: semi)...])
        }
        let share = sharePart.split(separator: "/").first.map(String.init) ?? ""
        return Parsed(
            host: host.removingPercentEncoding ?? host,
            port: port,
            share: share.removingPercentEncoding ?? share,
            username: user.removingPercentEncoding ?? user,
            domain: domain.removingPercentEncoding ?? domain
        )
    }

    /// Compares host names loosely: case-insensitive, ignoring a trailing dot and ".local".
    public static func hostsMatch(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            var h = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            while h.hasSuffix(".") { h.removeLast() }
            if h.hasSuffix(".local") { h.removeLast(6) }
            if h.hasSuffix("._smb._tcp") { h.removeLast(10) }
            return h
        }
        return norm(a) == norm(b)
    }
}
