import Foundation
import Synchronization

/// One TCP connection to an SMB server, multiplexing any number of in-flight requests.
///
/// Performance notes:
/// - Requests are pipelined: callers `await` their own responses while others are in flight.
///   The only limit is the SMB credit window, which the client keeps topped up to
///   `targetCredits` by asking for more in every request.
/// - Large reads and writes are multi-credit (up to the server's MaxRead/WriteSize per request).
/// - A dedicated reader thread parses, decrypts and verifies responses and resumes the waiting
///   tasks directly; a dedicated writer thread coalesces small frames into few syscalls.
/// - Related requests (CREATE + QUERY_INFO + CLOSE, …) go out as one compound frame, so most
///   metadata operations cost a single round trip.
final class SMBConnection: @unchecked Sendable {
    struct Configuration: Sendable {
        var requestTimeout: Duration = .seconds(30)
        var targetCredits: Int = 512
    }

    struct ExchangeResult: Sendable {
        var responses: [SMBMessage]
        /// The request exactly as sent (only when asked for; used for the 3.1.1 preauth hash).
        var sent: [UInt8]?
    }

    let socket: TCPSocket
    let configuration: Configuration
    private let state: Mutex<State>
    private let writer: FrameWriter
    private let clock = ContinuousClock()
    private let nonceSalt = SMBCrypto.randomBytes(4)

    private struct Waiter {
        var id: UInt64
        var charge: Int
        var continuation: CheckedContinuation<Void, Error>
    }

    private struct Exchange {
        var continuation: CheckedContinuation<ExchangeResult, Error>?
        var results: [SMBMessage?]
        var remaining: Int
        var deadline: ContinuousClock.Instant?
        var sent: [UInt8]?
        /// (MessageId, AsyncId) of elements the server answered with STATUS_PENDING.
        var asyncIDs: [(UInt64, UInt64)] = []
        var treeID: UInt32
    }

    private struct Slot {
        var exchange: UInt64
        var index: Int
        var charge: Int
    }

    private struct State {
        var nextMessageID: UInt64 = 0
        /// Credits granted by the server and not yet spent.
        var credits: Int = 1
        /// Credits spent on requests that haven't been answered yet.
        var outstanding: Int = 0
        var waiters: [Waiter] = []
        var exchanges: [UInt64: Exchange] = [:]
        var slots: [UInt64: Slot] = [:]
        var starting: Set<UInt64> = []
        var cancelledBeforeStart: Set<UInt64> = []
        var nextExchangeID: UInt64 = 1
        var nextWaiterID: UInt64 = 1
        var failure: SMBError?
        var security: SessionSecurity?
        var sessionID: UInt64 = 0
        var dialect: SMBDialect?
        var nonceCounter: UInt64 = 0
    }

    private init(socket: TCPSocket, configuration: Configuration) {
        self.socket = socket
        self.configuration = configuration
        self.state = Mutex(State())
        self.writer = FrameWriter(socket: socket)
    }

    static func open(host: String, port: Int, connectTimeout: Duration, socketBufferSize: Int,
                     configuration: Configuration) throws -> SMBConnection {
        let socket = try TCPSocket.connect(host: host, port: port, options: TCPSocket.Options(
            connectTimeout: connectTimeout,
            bufferSize: socketBufferSize,
            receivePollInterval: .seconds(1),
            sendTimeout: configuration.requestTimeout
        ))
        let connection = SMBConnection(socket: socket, configuration: configuration)
        connection.writer.onError = { [weak connection] error in connection?.fail(error) }
        connection.writer.start()
        connection.startReader()
        return connection
    }

    // MARK: State shared with the handshake

    var isClosed: Bool { state.withLock { $0.failure != nil } }
    var failure: SMBError? { state.withLock { $0.failure } }
    var availableCredits: Int { state.withLock { $0.credits } }

    func setDialect(_ dialect: SMBDialect) {
        state.withLock { $0.dialect = dialect }
    }

    func setSessionID(_ id: UInt64) {
        state.withLock { $0.sessionID = id }
    }

    func installSecurity(_ security: SessionSecurity?) {
        state.withLock { $0.security = security }
    }

    var security: SessionSecurity? { state.withLock { $0.security } }

    // MARK: Sending

    /// Sends one request, or a related compound when `requests.count > 1`, and waits for every
    /// response. Error statuses are returned, not thrown: compounds often expect some elements
    /// to fail (e.g. STATUS_NO_MORE_FILES).
    func send(_ requests: [SMBRequest], captureSent: Bool = false) async throws -> ExchangeResult {
        precondition(!requests.isEmpty)
        let charges = requests.map { max(1, $0.creditCharge) }
        let total = charges.reduce(0, +)
        try await acquireCredits(total)

        let id: UInt64 = state.withLock { s in
            let id = s.nextExchangeID
            s.nextExchangeID += 1
            s.starting.insert(id)
            return id
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExchangeResult, Error>) in
                self.start(id, requests, charges: charges, captureSent: captureSent, continuation: continuation)
            }
        } onCancel: {
            self.cancel(exchange: id)
        }
    }

    func send(_ request: SMBRequest) async throws -> SMBMessage {
        try await send([request]).responses[0]
    }

    private func acquireCredits(_ count: Int) async throws {
        enum Outcome { case granted, wait(UInt64), fail(SMBError) }
        let outcome: Outcome = state.withLock { s in
            if let failure = s.failure { return .fail(failure) }
            if s.waiters.isEmpty && s.credits >= count {
                s.credits -= count
                s.outstanding += count
                return .granted
            }
            if s.outstanding == 0 && s.waiters.isEmpty && s.credits < count {
                return .fail(.unsupported("The server granted too few credits (\(s.credits)) for a request needing \(count)."))
            }
            let id = s.nextWaiterID
            s.nextWaiterID += 1
            return .wait(id)
        }
        switch outcome {
        case .granted:
            return
        case .fail(let error):
            throw error
        case .wait(let id):
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Grant immediately if the credits arrived between the two critical sections,
                // otherwise nothing would wake this waiter up.
                typealias Continuations = [CheckedContinuation<Void, Error>]
                let (granted, starved, failure): (Continuations, Continuations, SMBError?) = state.withLock { s in
                    if let failure = s.failure { return ([], [continuation], failure) }
                    s.waiters.append(Waiter(id: id, charge: count, continuation: continuation))
                    let granted = Self.grantWaiters(&s)
                    if s.outstanding == 0, let first = s.waiters.first, s.credits < first.charge {
                        // Nothing is in flight, so no response will ever bring more credits.
                        let starved = s.waiters.map(\.continuation)
                        s.waiters.removeAll()
                        return (granted, starved, .unsupported("The server stopped granting credits."))
                    }
                    return (granted, [], nil)
                }
                for waiter in granted { waiter.resume() }
                if let failure {
                    for waiter in starved { waiter.resume(throwing: failure) }
                }
            }
        }
    }

    /// Returns credits taken for an exchange that never made it onto the wire.
    private func refund(_ count: Int) {
        let ready = state.withLock { s -> [CheckedContinuation<Void, Error>] in
            s.credits += count
            s.outstanding -= count
            return Self.grantWaiters(&s)
        }
        for continuation in ready { continuation.resume() }
    }

    private static func grantWaiters(_ s: inout State) -> [CheckedContinuation<Void, Error>] {
        var ready: [CheckedContinuation<Void, Error>] = []
        while let first = s.waiters.first, s.credits >= first.charge {
            s.waiters.removeFirst()
            s.credits -= first.charge
            s.outstanding += first.charge
            ready.append(first.continuation)
        }
        return ready
    }

    private struct Prepared {
        var messageIDs: [UInt64]
        var creditRequests: [UInt16]
        var sessionID: UInt64
        var security: SessionSecurity?
        var dialect: SMBDialect?
        var nonce: [UInt8]?
    }

    private func start(_ id: UInt64, _ requests: [SMBRequest], charges: [Int], captureSent: Bool,
                       continuation: CheckedContinuation<ExchangeResult, Error>) {
        let total = charges.reduce(0, +)
        let deadline: ContinuousClock.Instant? = requests.contains { $0.timeout == .unlimited }
            ? nil : clock.now + configuration.requestTimeout
        let nonceSalt = self.nonceSalt

        // 1. Reserve message ids and register the exchange.
        let prepared: Result<Prepared, SMBError> = state.withLock { s in
            s.starting.remove(id)
            if let failure = s.failure { return .failure(failure) }
            if s.cancelledBeforeStart.remove(id) != nil { return .failure(.cancelled) }
            var ids: [UInt64] = []
            var creditRequests: [UInt16] = []
            let deficit = max(0, configuration.targetCredits - (s.credits + s.outstanding))
            for (index, charge) in charges.enumerated() {
                let messageID = s.nextMessageID
                s.nextMessageID += UInt64(charge)
                ids.append(messageID)
                s.slots[messageID] = Slot(exchange: id, index: index, charge: charge)
                let extra = index == 0 ? min(deficit, 256) : 0
                creditRequests.append(UInt16(clamping: charge + extra))
            }
            s.exchanges[id] = Exchange(continuation: continuation, results: Array(repeating: nil, count: requests.count),
                                       remaining: requests.count, deadline: deadline, sent: nil,
                                       treeID: requests[0].treeID)
            var nonce: [UInt8]?
            if let security = s.security, security.encryptRequests {
                s.nonceCounter &+= 1
                var n = [UInt8](repeating: 0, count: 12)
                for i in 0..<8 { n[i] = UInt8(truncatingIfNeeded: s.nonceCounter >> UInt64(8 * i)) }
                for i in 0..<4 { n[8 + i] = nonceSalt[i] }
                nonce = n
            }
            return .success(Prepared(messageIDs: ids, creditRequests: creditRequests, sessionID: s.sessionID,
                                     security: s.security, dialect: s.dialect, nonce: nonce))
        }

        let plan: Prepared
        switch prepared {
        case .success(let value):
            plan = value
        case .failure(let error):
            refund(total)
            continuation.resume(throwing: error)
            return
        }

        // 2. Encode headers, sign or seal (outside the lock).
        do {
            var frame = try encode(requests, charges: charges, plan: plan)
            if captureSent {
                let sent = Array(frame[SMBRequest.prefixSize...])
                state.withLock { s in s.exchanges[id]?.sent = sent }
            }
            if let security = plan.security, security.encryptRequests, let nonce = plan.nonce {
                frame = try frame.withUnsafeBytes { raw in
                    try security.seal(UnsafeRawBufferPointer(rebasing: raw[SMBRequest.prefixSize...]), nonce: nonce)
                }
            } else {
                Self.setPrefix(&frame)
            }
            // 3. Hand it to the writer thread.
            if !writer.enqueue(frame) {
                fail(.disconnected("connection closed"))
            }
        } catch {
            let smbError = error as? SMBError ?? .malformed("\(error)")
            let toResume = state.withLock { s -> CheckedContinuation<ExchangeResult, Error>? in
                for messageID in plan.messageIDs { s.slots.removeValue(forKey: messageID) }
                return s.exchanges.removeValue(forKey: id)?.continuation
            }
            refund(total)
            toResume?.resume(throwing: smbError)
        }
    }

    private func encode(_ requests: [SMBRequest], charges: [Int], plan: Prepared) throws -> [UInt8] {
        let signing = plan.security.map { $0.signRequests && !$0.encryptRequests } ?? false
        let chargeField: (Int) -> UInt16 = { charge in plan.dialect == .smb202 ? 0 : UInt16(clamping: charge) }

        if requests.count == 1 {
            var frame = requests[0].frame
            Self.writeHeader(&frame, at: SMBRequest.prefixSize, command: requests[0].command,
                             charge: chargeField(charges[0]), creditRequest: plan.creditRequests[0], flags: 0,
                             next: 0, messageID: plan.messageIDs[0], treeID: requests[0].treeID,
                             sessionID: plan.sessionID)
            if signing, let security = plan.security, requests[0].command != .negotiate,
               requests[0].command != .sessionSetup {
                try security.sign(&frame, range: SMBRequest.prefixSize..<frame.count)
            }
            return frame
        }

        // Related compound: each element 8-byte aligned and signed on its own.
        var frame = [UInt8](repeating: 0, count: SMBRequest.prefixSize)
        frame.reserveCapacity(requests.reduce(SMBRequest.prefixSize) { $0 + $1.frame.count + 8 })
        for (index, request) in requests.enumerated() {
            var element = Array(request.frame[SMBRequest.prefixSize...])
            let isLast = index == requests.count - 1
            if !isLast {
                let pad = (8 - element.count % 8) % 8
                element.append(contentsOf: repeatElement(0, count: pad))
            }
            Self.writeHeader(&element, at: 0, command: request.command, charge: chargeField(charges[index]),
                             creditRequest: plan.creditRequests[index],
                             flags: index > 0 ? SMB2HeaderFlag.relatedOperations : 0,
                             next: isLast ? 0 : UInt32(element.count), messageID: plan.messageIDs[index],
                             treeID: request.treeID, sessionID: plan.sessionID)
            if signing, let security = plan.security {
                try security.sign(&element, range: 0..<element.count)
            }
            frame.append(contentsOf: element)
        }
        return frame
    }

    static func writeHeader(_ buffer: inout [UInt8], at base: Int, command: SMB2Command, charge: UInt16,
                                    creditRequest: UInt16, flags: UInt32, next: UInt32, messageID: UInt64,
                                    treeID: UInt32, sessionID: UInt64) {
        buffer.storeLE(SMB2Header.protocolID, at: base)
        buffer.storeLE(UInt16(64), at: base + 4)
        buffer.storeLE(charge, at: base + 6)
        buffer.storeLE(UInt32(0), at: base + 8)
        buffer.storeLE(command.rawValue, at: base + 12)
        buffer.storeLE(creditRequest, at: base + 14)
        buffer.storeLE(flags, at: base + 16)
        buffer.storeLE(next, at: base + 20)
        buffer.storeLE(messageID, at: base + 24)
        buffer.storeLE(UInt32(0), at: base + 32)
        buffer.storeLE(treeID, at: base + 36)
        buffer.storeLE(sessionID, at: base + 40)
    }

    private static func setPrefix(_ frame: inout [UInt8]) {
        let length = frame.count - SMBRequest.prefixSize
        frame[0] = 0
        frame[1] = UInt8(truncatingIfNeeded: length >> 16)
        frame[2] = UInt8(truncatingIfNeeded: length >> 8)
        frame[3] = UInt8(truncatingIfNeeded: length)
    }

    // MARK: Cancellation

    private func cancel(exchange id: UInt64) {
        let (continuation, asyncIDs, treeID) = state.withLock {
            s -> (CheckedContinuation<ExchangeResult, Error>?, [(UInt64, UInt64)], UInt32) in
            if s.starting.contains(id) {
                s.cancelledBeforeStart.insert(id)
                return (nil, [], 0)
            }
            guard var exchange = s.exchanges[id] else { return (nil, [], 0) }
            let continuation = exchange.continuation
            exchange.continuation = nil
            let pending = exchange.asyncIDs
            // Keep the slots: the late responses still carry credits.
            s.exchanges[id] = exchange
            return (continuation, pending, exchange.treeID)
        }
        continuation?.resume(throwing: SMBError.cancelled)
        for (messageID, asyncID) in asyncIDs {
            sendCancel(messageID: messageID, asyncID: asyncID, treeID: treeID)
        }
    }

    /// SMB2 CANCEL for an async request. Consumes no credits and has no response.
    private func sendCancel(messageID: UInt64, asyncID: UInt64, treeID: UInt32) {
        var frame = Requests.cancel().frame
        let (sessionID, security, nonce): (UInt64, SessionSecurity?, [UInt8]?) = state.withLock { s in
            var nonce: [UInt8]?
            if let security = s.security, security.encryptRequests {
                s.nonceCounter &+= 1
                var n = [UInt8](repeating: 0, count: 12)
                for i in 0..<8 { n[i] = UInt8(truncatingIfNeeded: s.nonceCounter >> UInt64(8 * i)) }
                for i in 0..<4 { n[8 + i] = nonceSalt[i] }
                nonce = n
            }
            return (s.sessionID, s.security, nonce)
        }
        let p = SMBRequest.prefixSize
        Self.writeHeader(&frame, at: p, command: .cancel, charge: 0, creditRequest: 0,
                         flags: SMB2HeaderFlag.asyncCommand, next: 0, messageID: messageID, treeID: 0,
                         sessionID: sessionID)
        frame.storeLE(asyncID, at: p + 32)
        do {
            if let security, security.encryptRequests, let nonce {
                frame = try frame.withUnsafeBytes { raw in
                    try security.seal(UnsafeRawBufferPointer(rebasing: raw[p...]), nonce: nonce)
                }
            } else {
                if let security, security.signRequests { try security.sign(&frame, range: p..<frame.count) }
                Self.setPrefix(&frame)
            }
            _ = writer.enqueue(frame)
        } catch {
            // Best effort: the request completes (or the connection dies) either way.
        }
    }

    // MARK: Receiving

    private func startReader() {
        let thread = Thread { [self] in self.readLoop() }
        thread.name = "app.berth.smb.reader"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 1 << 20
        thread.start()
    }

    private func readLoop() {
        var reader = FrameReader(socket: socket)
        var lastDeadlineCheck = clock.now
        while true {
            do {
                guard var frame = try reader.next(onIdle: { [self] in
                    lastDeadlineCheck = clock.now
                    try checkDeadlines()
                }) else {
                    fail(.disconnected("the server closed the connection"))
                    return
                }
                try process(&frame)
                if clock.now - lastDeadlineCheck > .seconds(1) {
                    lastDeadlineCheck = clock.now
                    try checkDeadlines()
                }
            } catch {
                fail(error as? SMBError ?? .disconnected("\(error)"))
                return
            }
            if state.withLock({ $0.failure != nil }) { return }
        }
    }

    private func checkDeadlines() throws {
        let now = clock.now
        let expired = state.withLock { s in
            s.exchanges.values.contains { exchange in
                guard let deadline = exchange.deadline else { return false }
                return deadline < now
            }
        }
        // A request the server never answered means it is gone (or wedged): drop everything so
        // callers fail fast and reconnect, like a soft mount.
        if expired { throw SMBError.timedOut }
    }

    private func process(_ frame: inout [UInt8]) throws {
        guard frame.count >= 4 else { throw SMBError.malformed("short frame") }
        let protocolID = frame.loadLE(UInt32.self, at: 0)
        var encrypted = false
        if protocolID == SMB2Header.transformID {
            guard let security = state.withLock({ $0.security }) else {
                throw SMBError.malformed("encrypted frame before session setup")
            }
            frame = try security.open(frame)
            encrypted = true
        } else if protocolID == SMB2Header.compressionID {
            throw SMBError.unsupported("The server sent a compressed message, which was not negotiated.")
        } else if protocolID != SMB2Header.protocolID {
            throw SMBError.malformed(String(format: "unknown protocol id 0x%08X", protocolID))
        }

        // Pass 1: split the compound chain and verify signatures in place.
        let security = state.withLock { $0.security }
        var ranges: [(Range<Int>, SMB2Header)] = []
        var position = 0
        while true {
            let header = try SMB2Header(ByteReader(frame, start: position))
            let length = header.nextCommand == 0 ? frame.count - position : Int(header.nextCommand)
            guard length >= SMB2.headerSize, position + length <= frame.count else {
                throw SMBError.malformed("bad compound chain")
            }
            let range = position..<(position + length)
            if !encrypted, let security, security.signRequests, header.isSigned,
               header.sessionID == security.sessionID, header.messageID != SMB2.unsolicitedMessageID {
                guard try security.verify(&frame, range: range) else { throw SMBError.signatureMismatch }
            }
            ranges.append((range, header))
            if header.nextCommand == 0 { break }
            position += length
        }

        // Pass 2: route responses.
        var completed: [(CheckedContinuation<ExchangeResult, Error>, ExchangeResult)] = []
        var ready: [CheckedContinuation<Void, Error>] = []
        state.withLock { s in
            for (range, header) in ranges {
                s.credits += Int(header.credits)
                guard header.messageID != SMB2.unsolicitedMessageID else { continue } // oplock/lease break
                guard let slot = s.slots[header.messageID] else { continue }
                if header.status == .pending && header.isAsync {
                    // Interim response: the real one comes later. Stop the clock for it.
                    s.exchanges[slot.exchange]?.deadline = nil
                    s.exchanges[slot.exchange]?.asyncIDs.append((header.messageID, header.asyncID))
                    continue
                }
                s.slots.removeValue(forKey: header.messageID)
                s.outstanding -= slot.charge
                guard var exchange = s.exchanges[slot.exchange] else { continue }
                let message = SMBMessage(reader: ByteReader(frame, start: range.lowerBound, end: range.upperBound),
                                         header: header, wasEncrypted: encrypted)
                exchange.results[slot.index] = message
                exchange.remaining -= 1
                if exchange.remaining == 0 {
                    s.exchanges.removeValue(forKey: slot.exchange)
                    if let continuation = exchange.continuation {
                        let responses = exchange.results.compactMap { $0 }
                        completed.append((continuation, ExchangeResult(responses: responses, sent: exchange.sent)))
                    }
                } else {
                    s.exchanges[slot.exchange] = exchange
                }
            }
            ready = Self.grantWaiters(&s)
        }
        for (continuation, result) in completed { continuation.resume(returning: result) }
        for continuation in ready { continuation.resume() }
    }

    // MARK: Teardown

    /// Fails every pending request and closes the socket. Idempotent.
    func fail(_ error: SMBError) {
        let (exchanges, waiters) = state.withLock {
            s -> ([CheckedContinuation<ExchangeResult, Error>], [CheckedContinuation<Void, Error>]) in
            guard s.failure == nil else { return ([], []) }
            s.failure = error
            let exchanges = s.exchanges.values.compactMap(\.continuation)
            let waiters = s.waiters.map(\.continuation)
            s.exchanges.removeAll()
            s.slots.removeAll()
            s.waiters.removeAll()
            return (exchanges, waiters)
        }
        writer.close()
        socket.shutdown()
        for continuation in exchanges { continuation.resume(throwing: error) }
        for continuation in waiters { continuation.resume(throwing: error) }
    }

    func close() {
        fail(.disconnected("closed"))
    }
}

// MARK: - Reader

/// Splits the byte stream into Direct TCP frames (4-byte header: zero, 24-bit length).
private struct FrameReader {
    let socket: TCPSocket
    private var staging = [UInt8](repeating: 0, count: 256 * 1024)
    private var head = 0
    private var tail = 0

    init(socket: TCPSocket) { self.socket = socket }

    private var buffered: Int { tail - head }

    /// Reads into the staging buffer. Returns false when the peer closed the connection.
    private mutating func fill(onIdle: () throws -> Void) throws -> Bool {
        if head == tail {
            head = 0
            tail = 0
        } else if tail == staging.count {
            // Compact. (Locals only inside the closures: they run while `staging` is borrowed.)
            let count = tail - head
            let from = head
            staging.withUnsafeMutableBytes { raw in
                let base = raw.baseAddress!
                base.copyMemory(from: base + from, byteCount: count)
            }
            head = 0
            tail = count
        }
        let socket = self.socket
        while true {
            let start = tail
            let result = try staging.withUnsafeMutableBytes { raw in
                try socket.receive(into: UnsafeMutableRawBufferPointer(rebasing: raw[start...]))
            }
            switch result {
            case .data(let count):
                tail += count
                return true
            case .idle:
                try onIdle()
            case .closed:
                return false
            }
        }
    }

    mutating func next(onIdle: () throws -> Void) throws -> [UInt8]? {
        while buffered < 4 {
            guard try fill(onIdle: onIdle) else { return nil }
        }
        let length = Int(staging[head + 1]) << 16 | Int(staging[head + 2]) << 8 | Int(staging[head + 3])
        guard staging[head] == 0, length >= 4 else { throw SMBError.malformed("bad frame header") }
        head += 4

        var frame = [UInt8](repeating: 0, count: length)
        var filled = min(length, buffered)
        if filled > 0 {
            let start = head
            frame.withUnsafeMutableBytes { out in
                staging.withUnsafeBytes { input in
                    out.baseAddress!.copyMemory(from: input.baseAddress! + start, byteCount: filled)
                }
            }
            head += filled
        }
        // Read the rest of a large frame straight into its own buffer.
        while filled < length {
            let result = try frame.withUnsafeMutableBytes { raw in
                try socket.receive(into: UnsafeMutableRawBufferPointer(rebasing: raw[filled...]))
            }
            switch result {
            case .data(let count): filled += count
            case .idle: try onIdle()
            case .closed: return nil
            }
        }
        return frame
    }
}

// MARK: - Writer

/// Owns the sending side of the socket. Frames are written in order; small ones are coalesced.
private final class FrameWriter: @unchecked Sendable {
    private let socket: TCPSocket
    private let condition = NSCondition()
    private var queue: [[UInt8]] = []
    private var closed = false
    var onError: (@Sendable (SMBError) -> Void)?

    init(socket: TCPSocket) { self.socket = socket }

    func start() {
        let thread = Thread { [self] in self.run() }
        thread.name = "app.berth.smb.writer"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Returns false once the writer is closed.
    func enqueue(_ frame: [UInt8]) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return false }
        queue.append(frame)
        condition.signal()
        return true
    }

    func close() {
        condition.lock()
        closed = true
        queue.removeAll()
        condition.signal()
        condition.unlock()
    }

    private func run() {
        var scratch = [UInt8]()
        scratch.reserveCapacity(256 * 1024)
        while true {
            condition.lock()
            while queue.isEmpty && !closed { condition.wait() }
            if closed {
                condition.unlock()
                return
            }
            let batch = queue
            queue.removeAll(keepingCapacity: true)
            condition.unlock()

            do {
                for frame in batch {
                    if frame.count <= 32 * 1024 {
                        scratch.append(contentsOf: frame)
                        if scratch.count >= 192 * 1024 { try flush(&scratch) }
                    } else {
                        try flush(&scratch)
                        try frame.withUnsafeBytes { try socket.sendAll($0) }
                    }
                }
                try flush(&scratch)
            } catch {
                onError?(error as? SMBError ?? .disconnected("\(error)"))
                return
            }
        }
    }

    private func flush(_ scratch: inout [UInt8]) throws {
        guard !scratch.isEmpty else { return }
        try scratch.withUnsafeBytes { try socket.sendAll($0) }
        scratch.removeAll(keepingCapacity: true)
    }
}
