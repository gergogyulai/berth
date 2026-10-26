import Foundation

/// A lossless model of `~/Library/Preferences/nsmb.conf`.
///
/// Lines Berth does not understand (comments, unknown keys, blank lines) are preserved verbatim
/// so editing the file through Berth never destroys hand-written configuration.
public struct NSMBConf: Equatable, Sendable {
    public struct Section: Equatable, Sendable, Identifiable {
        public var name: String
        public var lines: [Line]
        public var id: String { name.uppercased() }

        public init(name: String, lines: [Line] = []) {
            self.name = name
            self.lines = lines
        }

        public subscript(key: String) -> String? {
            get {
                for line in lines.reversed() {
                    if case .entry(let k, let v) = line, k.caseInsensitiveCompare(key) == .orderedSame { return v }
                }
                return nil
            }
            set {
                let matches: (Line) -> Bool = {
                    if case .entry(let k, _) = $0 { return k.caseInsensitiveCompare(key) == .orderedSame }
                    return false
                }
                if let newValue {
                    if let idx = lines.lastIndex(where: matches) {
                        lines[idx] = .entry(key: key, value: newValue)
                        // Drop earlier duplicates so the file stays unambiguous.
                        lines = lines.enumerated().filter { $0.offset == idx || !matches($0.element) }.map(\.element)
                    } else {
                        // Insert before trailing blank lines/comments to keep the section tidy.
                        var insertAt = lines.count
                        while insertAt > 0, case .raw(let r) = lines[insertAt - 1], r.trimmingCharacters(in: .whitespaces).isEmpty {
                            insertAt -= 1
                        }
                        lines.insert(.entry(key: key, value: newValue), at: insertAt)
                    }
                } else {
                    lines.removeAll(where: matches)
                }
            }
        }

        public var entries: [(key: String, value: String)] {
            lines.compactMap { if case .entry(let k, let v) = $0 { return (k, v) } else { return nil } }
        }
    }

    public enum Line: Equatable, Sendable {
        case entry(key: String, value: String)
        case raw(String)
    }

    /// Lines before the first section header (usually comments).
    public var preamble: [String] = []
    public var sections: [Section] = []

    public init() {}

    public static var userFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences/nsmb.conf")
    }

    public static func load(from url: URL = userFileURL) throws -> NSMBConf {
        guard FileManager.default.fileExists(atPath: url.path) else { return NSMBConf() }
        return NSMBConf(parsing: try String(contentsOf: url, encoding: .utf8))
    }

    public init(parsing text: String) {
        var current: Section?
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
                if let current { sections.append(current) }
                let name = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
                current = Section(name: name.trimmingCharacters(in: .whitespaces))
                continue
            }
            let isComment = trimmed.hasPrefix("#") || trimmed.hasPrefix(";")
            if !isComment, let eq = trimmed.firstIndex(of: "="), current != nil {
                let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                current?.lines.append(.entry(key: key, value: value))
            } else if current != nil {
                current?.lines.append(.raw(rawLine))
            } else {
                preamble.append(rawLine)
            }
        }
        if let current { sections.append(current) }
        // A trailing newline produces one empty raw line; drop it so round-trips are stable.
        if case .raw(let last)? = sections.last?.lines.last, last.isEmpty {
            sections[sections.count - 1].lines.removeLast()
        } else if sections.isEmpty, preamble.last == "" {
            preamble.removeLast()
        }
    }

    public func serialized() -> String {
        var out: [String] = preamble
        for section in sections {
            out.append("[\(section.name)]")
            for line in section.lines {
                switch line {
                case .entry(let k, let v): out.append("\(k)=\(v)")
                case .raw(let r): out.append(r)
                }
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    public func write(to url: URL = userFileURL) throws {
        // Keep one backup of whatever was there before Berth first touched it.
        let backup = url.appendingPathExtension("berth-backup")
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: url, to: backup)
        }
        try serialized().write(to: url, atomically: true, encoding: .utf8)
    }

    public func section(named name: String) -> Section? {
        sections.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public mutating func withSection(named name: String, _ body: (inout Section) -> Void) {
        if let idx = sections.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            body(&sections[idx])
        } else {
            var section = Section(name: name)
            body(&section)
            // [default] goes first by convention.
            if name.lowercased() == "default" { sections.insert(section, at: 0) } else { sections.append(section) }
        }
    }

    public mutating func removeSection(named name: String) {
        sections.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Section name used for a server. smbfs matches sections against the server name in upper case.
    public static func sectionName(forHost host: String) -> String {
        host.uppercased()
    }
}

/// The nsmb.conf keys Berth exposes in its editor, with metadata for the UI.
public struct NSMBOption: Identifiable, Sendable {
    public enum Kind: Sendable {
        case bool
        case choice([(value: String, title: String)])
        case text(placeholder: String)
    }

    public let key: String
    public let title: String
    public let help: String
    public let kind: Kind
    public let serverScoped: Bool
    public var id: String { key }

    public static let all: [NSMBOption] = [
        NSMBOption(key: "signing_required", title: "Require Signing",
                   help: "Packet signing protects integrity but costs throughput. Tailscale already authenticates every packet.",
                   kind: .bool, serverScoped: true),
        NSMBOption(key: "mc_on", title: "Multichannel",
                   help: "Use several connections (and NICs) per session. Great on fast LANs, harmful over VPNs.",
                   kind: .bool, serverScoped: true),
        NSMBOption(key: "mc_prefer_wired", title: "Prefer Wired Channels",
                   help: "In multichannel mode, prefer Ethernet over Wi-Fi.",
                   kind: .bool, serverScoped: true),
        NSMBOption(key: "notify_off", title: "Disable Change Notifications",
                   help: "Stops Finder from subscribing to directory change notifications. Reduces chatter on slow links.",
                   kind: .bool, serverScoped: true),
        NSMBOption(key: "streams", title: "Named Streams",
                   help: "Store extended attributes and resource forks as NTFS streams when the server supports them.",
                   kind: .bool, serverScoped: true),
        NSMBOption(key: "soft", title: "Soft Mount",
                   help: "Applications get an error instead of hanging when the server stops responding.",
                   kind: .bool, serverScoped: true),
        NSMBOption(key: "protocol_vers_map", title: "SMB Versions",
                   help: "Which protocol versions may be negotiated.",
                   kind: .choice([("7", "SMB 1, 2 and 3"), ("6", "SMB 2 and 3"), ("4", "SMB 3 only")]), serverScoped: true),
        NSMBOption(key: "minauth", title: "Minimum Authentication",
                   help: "Weakest authentication method that may be used.",
                   kind: .choice([("kerberos", "Kerberos"), ("ntlmv2", "NTLMv2"), ("ntlm", "NTLM"), ("lm", "LM"), ("none", "None")]),
                   serverScoped: true),
        NSMBOption(key: "port445", title: "Ports",
                   help: "Whether to use port 445, NetBIOS (139), or both.",
                   kind: .choice([("both", "445, then NetBIOS"), ("no_netbios", "445 only"), ("netbios_only", "NetBIOS only")]),
                   serverScoped: true),
        NSMBOption(key: "validate_neg_off", title: "Disable Validate Negotiate",
                   help: "Works around old servers that mishandle SMB 3 negotiate validation.",
                   kind: .bool, serverScoped: true),
        NSMBOption(key: "dir_cache_max", title: "Directory Cache (max)",
                   help: "Maximum time a directory listing is cached, e.g. 60s.",
                   kind: .text(placeholder: "60s"), serverScoped: true),
        NSMBOption(key: "max_resp_timeout", title: "Response Timeout",
                   help: "Maximum time to wait for any response from the server, e.g. 30s.",
                   kind: .text(placeholder: "30s"), serverScoped: true),
        NSMBOption(key: "addr", title: "Address Override",
                   help: "DNS name or IP to use for this server name.",
                   kind: .text(placeholder: "nas.local"), serverScoped: true),
    ]

    public static func option(for key: String) -> NSMBOption? { all.first { $0.key == key } }
}

/// Opinionated groups of nsmb.conf + mount settings.
public enum PerformancePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case fastLAN
    case tailscaleWAN
    case compatibility

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fastLAN: "Fast LAN"
        case .tailscaleWAN: "Tailscale / WAN"
        case .compatibility: "Compatibility"
        }
    }

    public var summary: String {
        switch self {
        case .fastLAN: "No signing, multichannel on, prefers wired links. Best throughput on a trusted home network."
        case .tailscaleWAN: "No signing (the tunnel already authenticates), no multichannel, fewer notifications, soft mounts."
        case .compatibility: "Allows SMB 1, NTLM and disables negotiate validation for older NAS boxes and routers."
        }
    }

    public var symbol: String {
        switch self {
        case .fastLAN: "hare.fill"
        case .tailscaleWAN: "point.3.filled.connected.trianglepath.dotted"
        case .compatibility: "wrench.adjustable.fill"
        }
    }

    public var values: [String: String] {
        switch self {
        case .fastLAN:
            ["signing_required": "no", "mc_on": "yes", "mc_prefer_wired": "yes", "notify_off": "no",
             "streams": "yes", "soft": "no", "protocol_vers_map": "6", "port445": "no_netbios"]
        case .tailscaleWAN:
            ["signing_required": "no", "mc_on": "no", "notify_off": "yes", "streams": "yes",
             "soft": "yes", "protocol_vers_map": "6", "port445": "no_netbios", "dir_cache_max": "120s"]
        case .compatibility:
            ["signing_required": "no", "mc_on": "no", "protocol_vers_map": "7", "minauth": "ntlm",
             "validate_neg_off": "yes", "streams": "no", "port445": "both"]
        }
    }

    /// Keys managed by presets; applying a preset clears the others in this set.
    public static let managedKeys: Set<String> = Set(allCases.flatMap { $0.values.keys })

    public func apply(to section: inout NSMBConf.Section) {
        for key in Self.managedKeys where values[key] == nil { section[key] = nil }
        for (key, value) in values.sorted(by: { $0.key < $1.key }) { section[key] = value }
    }

    /// Detects which preset (if any) a section currently matches exactly.
    public static func matching(_ section: NSMBConf.Section) -> PerformancePreset? {
        allCases.first { preset in
            managedKeys.allSatisfy { key in section[key]?.lowercased() == preset.values[key] }
        }
    }
}
