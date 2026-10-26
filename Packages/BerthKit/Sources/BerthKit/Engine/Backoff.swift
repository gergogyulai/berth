import Foundation

/// Exponential backoff with jitter: 2s, 4s, 8s … capped at `maximum`.
public struct Backoff: Sendable {
    public var base: TimeInterval
    public var maximum: TimeInterval
    public var jitter: Double

    public init(base: TimeInterval = 2, maximum: TimeInterval = 300, jitter: Double = 0.2) {
        self.base = base
        self.maximum = maximum
        self.jitter = jitter
    }

    /// Delay before retry number `attempt` (1-based).
    public func delay(forAttempt attempt: Int, random: Double = .random(in: -1...1)) -> TimeInterval {
        let exponent = Double(max(0, min(attempt - 1, 30)))
        let raw = min(maximum, base * pow(2, exponent))
        let jittered = raw * (1 + jitter * random)
        return max(1, min(maximum, jittered))
    }
}
