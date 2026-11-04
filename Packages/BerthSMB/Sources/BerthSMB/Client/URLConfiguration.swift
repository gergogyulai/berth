import Foundation

extension SMBClient.Configuration {
    /// Parses `smb://[DOMAIN;]user[:password]@host[:port]/share[/path]`.
    ///
    /// Returns the configuration and the path inside the share. `guest@` and an empty user mean
    /// guest and anonymous access. A password missing from the URL comes from `password`.
    public init?(url string: String, password fallbackPassword: String? = nil) {
        guard let components = URLComponents(string: string), components.scheme?.lowercased() == "smb",
              let host = components.host, !host.isEmpty else { return nil }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let share = parts.first else { return nil }

        var user = components.user ?? ""
        var domain = ""
        if let semicolon = user.firstIndex(of: ";") {
            domain = String(user[..<semicolon])
            user = String(user[user.index(after: semicolon)...])
        }
        let password = components.password ?? fallbackPassword ?? ""
        let credentials: SMBCredentials
        if user.isEmpty {
            credentials = .anonymous
        } else if user.lowercased() == "guest" && password.isEmpty {
            credentials = .guest
        } else {
            credentials = .user(name: user, password: password, domain: domain)
        }
        self.init(host: host, port: components.port ?? 445, share: share, credentials: credentials)
    }

    /// The path inside the share from an smb:// URL ("" for the share root).
    public static func path(fromURL string: String) -> String {
        guard let components = URLComponents(string: string) else { return "" }
        return components.path.split(separator: "/", omittingEmptySubsequences: true).dropFirst().joined(separator: "/")
    }
}
