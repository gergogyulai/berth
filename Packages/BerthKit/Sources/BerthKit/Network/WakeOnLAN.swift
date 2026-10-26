import Foundation

public enum WakeOnLAN {
    public enum WakeError: LocalizedError {
        case invalidMAC
        case socket(Int32)

        public var errorDescription: String? {
            switch self {
            case .invalidMAC: "The hardware (MAC) address is not valid."
            case .socket(let code): "Could not send the wake packet (\(String(cString: strerror(code))))."
            }
        }
    }

    /// Parses `aa:bb:cc:dd:ee:ff`, `aa-bb-cc-dd-ee-ff`, `aabb.ccdd.eeff` or `aabbccddeeff`.
    public static func parseMAC(_ string: String) -> [UInt8]? {
        let hex = string.lowercased().filter { $0.isHexDigit }
        let separators = string.filter { !$0.isHexDigit && !$0.isWhitespace }
        guard hex.count == 12, separators.allSatisfy({ ":-.".contains($0) }) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// 6 × 0xFF followed by the MAC repeated 16 times.
    public static func magicPacket(for mac: [UInt8]) -> [UInt8] {
        [UInt8](repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: mac, count: 16).joined())
    }

    /// Sends the magic packet to UDP ports 9 and 7 on the broadcast address.
    public static func wake(mac: String, broadcast: String = "") throws {
        guard let bytes = parseMAC(mac) else { throw WakeError.invalidMAC }
        let packet = magicPacket(for: bytes)
        let target = broadcast.trimmingCharacters(in: .whitespaces).isEmpty ? "255.255.255.255" : broadcast

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw WakeError.socket(errno) }
        defer { close(fd) }
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw WakeError.socket(errno)
        }
        for port: UInt16 in [9, 7] {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { throw WakeError.socket(EINVAL) }
            let sent = packet.withUnsafeBytes { buf in
                withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent < 0 { throw WakeError.socket(errno) }
        }
    }
}
