import Foundation

/// Finds shares the user already uses elsewhere: mounted right now, or in Finder's lists.
public enum ShareImporter {
    public struct Candidate: Identifiable, Hashable, Sendable {
        public enum Source: String, Sendable {
            case mounted = "Mounted Now"
            case finder = "Finder Recents & Favorites"
            case bonjour = "Nearby (Bonjour)"
        }

        public var id: String { "\(host.lowercased())/\(share.lowercased())/\(username.lowercased())" }
        public var source: Source
        public var host: String
        public var share: String
        public var username: String
        public var domain: String
        public var isGuest: Bool
        public var mountPoint: String?

        public var title: String { share.isEmpty ? host : share }
        public var subtitle: String {
            let user = isGuest ? "guest" : (username.isEmpty ? nil : username)
            return [user.map { "\($0) @ \(host)" } ?? host, mountPoint].compactMap { $0 }.joined(separator: " — ")
        }

        public func makeShare() -> Share {
            var host = self.host
            // Bonjour service names in mount sources look like "NAS._smb._tcp.local".
            if host.hasSuffix("._smb._tcp.local") {
                host = host.replacingOccurrences(of: "._smb._tcp.local", with: "").replacingOccurrences(of: " ", with: "-") + ".local"
            }
            return Share(
                displayName: share,
                addresses: [ServerAddress(host: host)],
                shareName: share,
                auth: isGuest ? .guest : (username.isEmpty ? .anonymous : .registered),
                username: isGuest ? "" : username,
                domain: domain,
                icon: Self.guessIcon(for: share)
            )
        }

        public static func guessIcon(for name: String) -> ShareIcon {
            let n = name.lowercased()
            let rules: [(keys: [String], preset: String)] = [
                (["media", "movie", "film", "video", "tv", "plex", "jellyfin"], "Media"),
                (["music", "audio"], "Music"),
                (["photo", "picture", "camera"], "Photos"),
                (["backup", "bak"], "Backups"),
                (["timemachine", "time machine", "tm"], "Time Machine"),
                (["doc", "paper"], "Documents"),
                (["download"], "Downloads"),
                (["home", "user"], "Home"),
                (["archive"], "Archive"),
                (["work", "office"], "Work"),
                (["game"], "Games"),
                (["code", "dev", "src", "git"], "Code"),
            ]
            for rule in rules where rule.keys.contains(where: { n.contains($0) }) {
                if let icon = ShareIcon.presets.first(where: { $0.title == rule.preset })?.icon { return icon }
            }
            return .default
        }
    }

    public static func mountedCandidates() -> [Candidate] {
        MountTable.smbMounts().map { entry in
            let isGuest = entry.username.lowercased() == "guest"
            return Candidate(source: .mounted, host: entry.host, share: entry.share, username: isGuest ? "" : entry.username,
                             domain: "", isGuest: isGuest, mountPoint: entry.mountPoint)
        }
    }

    public static func finderCandidates() -> [Candidate] {
        SharedFileList.smbServers().compactMap { entry in
            guard let parsed = SMBURL.parse(entry.url), !parsed.share.isEmpty else { return nil }
            let isGuest = parsed.username.lowercased() == "guest"
            return Candidate(source: .finder, host: parsed.host, share: parsed.share, username: isGuest ? "" : parsed.username,
                             domain: parsed.domain, isGuest: isGuest, mountPoint: nil)
        }
    }

    /// All candidates, minus duplicates and shares that are already configured.
    public static func candidates(excluding existing: [Share]) -> [Candidate] {
        let all = mountedCandidates() + finderCandidates()
        var seen = Set<String>()
        return all.filter { candidate in
            guard seen.insert(candidate.id).inserted else { return false }
            return !existing.contains { share in
                share.shareName.caseInsensitiveCompare(candidate.share) == .orderedSame
                    && share.addresses.contains { SMBURL.hostsMatch($0.trimmedHost, candidate.host) }
            }
        }
    }
}
