import Foundation

/// A snapshot of the kernel mount table, restricted to SMB.
public enum MountTable {
    public struct Entry: Hashable, Sendable {
        public var mountPoint: String
        /// e.g. `//user@nas._smb._tcp.local/Media`
        public var source: String
        public var host: String
        public var share: String
        public var username: String
        public var ownerUID: uid_t
        public var isOwnedByCurrentUser: Bool { ownerUID == getuid() }
    }

    /// Lists smbfs mounts. Uses MNT_NOWAIT so a dead server can never block the caller.
    public static func smbMounts(includeOtherUsers: Bool = false) -> [Entry] {
        // The _r_np variant: plain getmntinfo reuses one static buffer and crashes when called from
        // two threads at once.
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        defer { free(buffer) }
        guard count > 0, let buffer else { return [] }
        var entries: [Entry] = []
        for i in 0..<Int(count) {
            var fs = buffer[i]
            let type = withUnsafeBytes(of: &fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard type == "smbfs" else { continue }
            let mountPoint = withUnsafeBytes(of: &fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let source = withUnsafeBytes(of: &fs.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            // On a multi-user Mac every user's mounts show up here. Never treat somebody else's
            // mount of the same share as ours.
            guard includeOtherUsers || fs.f_owner == getuid() else { continue }
            let parsed = SMBURL.parse(source)
            entries.append(Entry(
                mountPoint: mountPoint,
                source: source,
                host: parsed?.host ?? "",
                share: parsed?.share ?? "",
                username: parsed?.username ?? "",
                ownerUID: fs.f_owner
            ))
        }
        return entries
    }

    /// Extra mounts of a share that nothing in Berth tracks, such as ones Finder or a replayed request
    /// made. Only same-user matches count: a second mount under another account can be deliberate.
    public static func duplicates(of share: Share, in entries: [Entry], excluding tracked: Set<String>) -> [Entry] {
        guard share.auth == .registered else { return [] }
        return entries.filter { entry in
            !tracked.contains(entry.mountPoint)
                && entry.share.caseInsensitiveCompare(share.shareName) == .orderedSame
                && entry.username.caseInsensitiveCompare(share.username) == .orderedSame
                && share.addresses.contains { SMBURL.hostsMatch($0.trimmedHost, entry.host) }
        }
    }

    /// A path as the mount table would show it: tilde expanded, no trailing slash, and `/tmp`-style
    /// symlinks at the front resolved. Never touches the path's last component, so it can't block
    /// on a dead mount.
    static func canonicalPath(_ path: String) -> String {
        var expanded = (path as NSString).expandingTildeInPath
        while expanded.count > 1, expanded.hasSuffix("/") { expanded.removeLast() }
        let url = URL(fileURLWithPath: expanded)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        return (parent as NSString).appendingPathComponent(url.lastPathComponent)
    }

    /// Finds the mount for a share, preferring its known mount point, then any matching host/share.
    public static func find(_ share: Share, knownMountPoint: String? = nil, in entries: [Entry]) -> Entry? {
        if let knownMountPoint, let e = entries.first(where: { $0.mountPoint == knownMountPoint }),
           e.share.caseInsensitiveCompare(share.shareName) == .orderedSame {
            return e
        }
        // The configured folder is stored as typed ("~/Shares/Media"); the kernel reports the real path.
        // Something else mounted there is not this share.
        if let custom = share.mountLocation.customPath.map({ canonicalPath($0) }),
           let e = entries.first(where: { canonicalPath($0.mountPoint) == custom }),
           e.share.caseInsensitiveCompare(share.shareName) == .orderedSame {
            return e
        }
        return entries.first { entry in
            entry.share.caseInsensitiveCompare(share.shareName) == .orderedSame
                && share.addresses.contains { SMBURL.hostsMatch($0.trimmedHost, entry.host) }
        }
    }
}
