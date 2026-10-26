import Foundation
import os

/// Access to Finder's shared file lists (sidebar Favorites, recent servers).
///
/// The LSSharedFileList API was removed from the SDK headers but is still exported by
/// CoreServices and still what Finder uses, so it is looked up at runtime. Everything here is
/// best-effort: if a symbol disappears in a future macOS, the features quietly turn off.
public enum SharedFileList {
    private typealias CreateFn = @convention(c) (CFAllocator?, CFString, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias SnapshotFn = @convention(c) (AnyObject, UnsafeMutablePointer<UInt32>?) -> Unmanaged<CFArray>?
    private typealias InsertFn = @convention(c) (AnyObject, UnsafeRawPointer?, CFString?, OpaquePointer?, CFURL, CFDictionary?, CFArray?) -> Unmanaged<AnyObject>?
    private typealias ResolveFn = @convention(c) (AnyObject, UInt32, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
    private typealias BookmarkFn = @convention(c) (AnyObject, UInt32, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFData>?
    private typealias RemoveFn = @convention(c) (AnyObject, AnyObject) -> OSStatus

    private struct Symbols: @unchecked Sendable {
        let create: CreateFn
        let snapshot: SnapshotFn
        let insert: InsertFn
        let resolve: ResolveFn
        let bookmark: BookmarkFn?
        let remove: RemoveFn
        let itemLast: UnsafeRawPointer?
    }

    private static let symbols: Symbols? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY) else { return nil }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let create = sym("LSSharedFileListCreate", CreateFn.self),
              let snapshot = sym("LSSharedFileListCopySnapshot", SnapshotFn.self),
              let insert = sym("LSSharedFileListInsertItemURL", InsertFn.self),
              let resolve = sym("LSSharedFileListItemCopyResolvedURL", ResolveFn.self),
              let remove = sym("LSSharedFileListItemRemove", RemoveFn.self) else { return nil }
        // kLSSharedFileListItemLast is a sentinel pointer value, not an object.
        let last = dlsym(handle, "kLSSharedFileListItemLast")?.assumingMemoryBound(to: UnsafeRawPointer?.self).pointee
        return Symbols(create: create, snapshot: snapshot, insert: insert, resolve: resolve,
                       bookmark: sym("LSSharedFileListItemCopyBookmarkData", BookmarkFn.self), remove: remove, itemLast: last)
    }()

    public static var isAvailable: Bool { symbols != nil }

    private static let favoriteItems = "com.apple.LSSharedFileList.FavoriteItems"
    private static let recentServers = "com.apple.LSSharedFileList.RecentServers"
    private static let favoriteServers = "com.apple.LSSharedFileList.FavoriteServers"

    /// Resolution flags: no UI, never mount.
    private static let quietFlags: UInt32 = 0x1 | 0x2

    private static func items(of listType: String) -> (list: AnyObject, items: [AnyObject])? {
        guard let s = symbols, let list = s.create(nil, listType as CFString, nil)?.takeRetainedValue() else { return nil }
        var seed: UInt32 = 0
        let items = (s.snapshot(list, &seed)?.takeRetainedValue() as? [AnyObject]) ?? []
        return (list, items)
    }

    // MARK: Sidebar

    public static func isPinned(path: String) -> Bool {
        guard let s = symbols, let (_, items) = items(of: favoriteItems) else { return false }
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return items.contains { item in
            (s.resolve(item, quietFlags, nil)?.takeRetainedValue() as URL?)?.standardizedFileURL.path == target
        }
    }

    @discardableResult
    public static func pinToSidebar(path: String, name: String? = nil) -> Bool {
        guard let s = symbols, let (list, _) = items(of: favoriteItems) else { return false }
        guard !isPinned(path: path) else { return true }
        let url = URL(fileURLWithPath: path, isDirectory: true) as CFURL
        return s.insert(list, s.itemLast, name as CFString?, nil, url, nil, nil) != nil
    }

    @discardableResult
    public static func unpinFromSidebar(path: String) -> Bool {
        guard let s = symbols, let (list, items) = items(of: favoriteItems) else { return false }
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        var removed = false
        for item in items {
            if (s.resolve(item, quietFlags, nil)?.takeRetainedValue() as URL?)?.standardizedFileURL.path == target {
                removed = s.remove(list, item) == noErr || removed
            }
        }
        return removed
    }

    // MARK: Servers

    public struct ServerEntry: Hashable, Sendable {
        public var name: String
        public var url: String
    }

    /// Finder's “Recent Servers” and Connect to Server favorites, as smb:// URLs.
    public static func smbServers() -> [ServerEntry] {
        var result: [ServerEntry] = []
        for listType in [favoriteServers, recentServers] {
            guard let s = symbols, let (_, items) = items(of: listType) else { continue }
            for item in items {
                guard let data = s.bookmark?(item, quietFlags, nil)?.takeRetainedValue() as Data? else { continue }
                let name = URL.resourceValues(forKeys: [.volumeNameKey], fromBookmarkData: data)?.volumeName ?? ""
                for url in extractURLs(from: data, scheme: "smb://") {
                    result.append(ServerEntry(name: name, url: url))
                }
            }
        }
        return result.uniqued()
    }

    /// Bookmark data embeds the volume's remount URL as a plain string; pull it out without
    /// resolving the bookmark (which could trigger a mount or an authentication dialog).
    static func extractURLs(from data: Data, scheme: String) -> [String] {
        let bytes = [UInt8](data)
        let needle = [UInt8](scheme.utf8)
        var found: [String] = []
        var i = 0
        while i + needle.count <= bytes.count {
            if bytes[i..<(i + needle.count)].elementsEqual(needle) {
                var j = i
                while j < bytes.count, bytes[j] >= 0x21, bytes[j] < 0x7F { j += 1 }
                found.append(String(decoding: bytes[i..<j], as: UTF8.self))
                i = j
            } else {
                i += 1
            }
        }
        return found
    }
}
