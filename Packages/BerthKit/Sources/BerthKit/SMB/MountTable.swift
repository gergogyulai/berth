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
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
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

    /// Finds the mount for a share, preferring its known mount point, then any matching host/share.
    public static func find(_ share: Share, knownMountPoint: String? = nil, in entries: [Entry]) -> Entry? {
        if let knownMountPoint, let e = entries.first(where: { $0.mountPoint == knownMountPoint }),
           e.share.caseInsensitiveCompare(share.shareName) == .orderedSame {
            return e
        }
        if let custom = share.mountLocation.customPath, let e = entries.first(where: { $0.mountPoint == custom }) {
            return e
        }
        return entries.first { entry in
            entry.share.caseInsensitiveCompare(share.shareName) == .orderedSame
                && share.addresses.contains { SMBURL.hostsMatch($0.trimmedHost, entry.host) }
        }
    }
}
