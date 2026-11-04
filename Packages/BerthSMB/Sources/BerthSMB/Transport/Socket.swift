import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A connected TCP socket tuned for SMB: Nagle off, large buffers, keepalives, no SIGPIPE.
///
/// Blocking I/O is deliberate: one dedicated thread reads and one writes (see `SMBConnection`),
/// which is the cheapest way to keep a deep pipeline of large requests moving.
final class TCPSocket: @unchecked Sendable {
    let fd: Int32
    let remoteDescription: String

    private init(fd: Int32, remoteDescription: String) {
        self.fd = fd
        self.remoteDescription = remoteDescription
    }

    deinit {
        _ = systemClose(fd)
    }

    struct Options: Sendable {
        var connectTimeout: Duration
        var bufferSize: Int
        /// SO_RCVTIMEO: how often a blocked read wakes up so the reader can check deadlines.
        var receivePollInterval: Duration
        var sendTimeout: Duration
    }

    /// Resolves `host` and connects to the first address that answers within the timeout.
    static func connect(host: String, port: Int, options: Options) throws -> TCPSocket {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        hints.ai_protocol = Int32(IPPROTO_TCP)
        var list: UnsafeMutablePointer<addrinfo>?
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let rc = getaddrinfo(host, String(port), &hints, &list)
        guard rc == 0, let first = list else {
            let message = rc == 0 ? "no addresses" : String(cString: gai_strerror(rc))
            throw SMBError.connectionFailed(code: EHOSTUNREACH, message: "Could not resolve \(host): \(message)")
        }
        defer { freeaddrinfo(list) }

        var candidates: [UnsafeMutablePointer<addrinfo>] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            candidates.append(entry)
            cursor = entry.pointee.ai_next
        }

        let clock = ContinuousClock()
        let deadline = clock.now + options.connectTimeout
        var lastError: Int32 = ETIMEDOUT
        for (index, entry) in candidates.enumerated() {
            let remaining = deadline - clock.now
            guard remaining > .zero else { break }
            // Give every remaining address a fair share of what's left, but at least 1.5 s.
            let share = max(.milliseconds(1500), remaining / max(1, candidates.count - index))
            let attempt = min(share, remaining)
            let ai = entry.pointee
            let fd = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
            guard fd >= 0 else {
                lastError = errno
                continue
            }
            if let error = connect(fd: fd, address: ai.ai_addr, length: ai.ai_addrlen, timeout: attempt) {
                lastError = error
                _ = systemClose(fd)
                continue
            }
            configure(fd, options: options)
            return TCPSocket(fd: fd, remoteDescription: "\(host):\(port)")
        }
        throw SMBError.connectionFailed(
            code: lastError,
            message: "Could not connect to \(host):\(port) (\(String(cString: strerror(lastError))))."
        )
    }

    /// Non-blocking connect bounded by `timeout`; returns an errno on failure.
    private static func connect(fd: Int32, address: UnsafeMutablePointer<sockaddr>?, length: socklen_t,
                                timeout: Duration) -> Int32? {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }

        #if canImport(Darwin)
        let result = Darwin.connect(fd, address, length)
        #else
        let result = Glibc.connect(fd, address, length)
        #endif
        if result == 0 { return nil }
        guard errno == EINPROGRESS else { return errno }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(clamping: timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        let ready = poll(&pfd, 1, max(1, milliseconds))
        if ready == 0 { return ETIMEDOUT }
        if ready < 0 { return errno }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else { return errno }
        return error == 0 ? nil : error
    }

    private static func configure(_ fd: Int32, options: Options) {
        func set(_ level: Int32, _ name: Int32, _ value: Int32) {
            var v = value
            _ = setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size))
        }
        set(Int32(IPPROTO_TCP), TCP_NODELAY, 1)
        set(SOL_SOCKET, SO_KEEPALIVE, 1)
        set(SOL_SOCKET, SO_SNDBUF, Int32(clamping: options.bufferSize))
        set(SOL_SOCKET, SO_RCVBUF, Int32(clamping: options.bufferSize))
        #if canImport(Darwin)
        set(SOL_SOCKET, SO_NOSIGPIPE, 1)
        set(Int32(IPPROTO_TCP), TCP_KEEPALIVE, 20)
        #else
        set(Int32(IPPROTO_TCP), TCP_KEEPIDLE, 20)
        #endif
        set(Int32(IPPROTO_TCP), TCP_KEEPINTVL, 5)
        set(Int32(IPPROTO_TCP), TCP_KEEPCNT, 4)
        setTimeout(fd, SO_RCVTIMEO, options.receivePollInterval)
        setTimeout(fd, SO_SNDTIMEO, options.sendTimeout)
    }

    private static func setTimeout(_ fd: Int32, _ name: Int32, _ duration: Duration) {
        let (seconds, attoseconds) = duration.components
        var tv = timeval()
        tv.tv_sec = .init(seconds)
        tv.tv_usec = .init(attoseconds / 1_000_000_000_000)
        _ = setsockopt(fd, SOL_SOCKET, name, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Writes the whole buffer. Throws on error, including a send timeout (the peer stopped reading).
    func sendAll(_ buffer: UnsafeRawBufferPointer) throws {
        guard var pointer = buffer.baseAddress else { return }
        var remaining = buffer.count
        while remaining > 0 {
            #if canImport(Darwin)
            let sent = Darwin.send(fd, pointer, remaining, 0)
            #else
            let sent = Glibc.send(fd, pointer, remaining, Int32(MSG_NOSIGNAL))
            #endif
            if sent < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw SMBError.timedOut }
                throw SMBError.disconnected(String(cString: strerror(errno)))
            }
            pointer += sent
            remaining -= sent
        }
    }

    enum ReadResult {
        case data(Int)
        /// SO_RCVTIMEO elapsed without data; the caller gets a chance to check its deadlines.
        case idle
        case closed
    }

    func receive(into buffer: UnsafeMutableRawBufferPointer) throws -> ReadResult {
        while true {
            let count = recv(fd, buffer.baseAddress, buffer.count, 0)
            if count > 0 { return .data(count) }
            if count == 0 { return .closed }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return .idle }
            throw SMBError.disconnected(String(cString: strerror(errno)))
        }
    }

    /// Wakes up any thread blocked on the socket. The descriptor is closed on deinit.
    func shutdown() {
        #if canImport(Darwin)
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        #else
        _ = Glibc.shutdown(fd, Int32(SHUT_RDWR))
        #endif
    }
}

@inline(__always)
private func systemClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fd)
    #else
    return Glibc.close(fd)
    #endif
}
