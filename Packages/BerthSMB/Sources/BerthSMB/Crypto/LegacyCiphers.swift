import Foundation

/// MD4 (RFC 1320). Only used to derive the NT hash of a password for NTLM.
enum MD4 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var data = message
        let bitLength = UInt64(message.count) &* 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for i in 0..<8 { data.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(8 * i))) }

        var a: UInt32 = 0x6745_2301
        var b: UInt32 = 0xEFCD_AB89
        var c: UInt32 = 0x98BA_DCFE
        var d: UInt32 = 0x1032_5476
        var x = [UInt32](repeating: 0, count: 16)

        @inline(__always) func rotl(_ value: UInt32, _ shift: UInt32) -> UInt32 {
            (value << shift) | (value >> (32 - shift))
        }

        let round2Order = [0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15]
        let round3Order = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15]
        let shifts1: [UInt32] = [3, 7, 11, 19]
        let shifts2: [UInt32] = [3, 5, 9, 13]
        let shifts3: [UInt32] = [3, 9, 11, 15]

        for block in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 { x[i] = data.loadLE(UInt32.self, at: block + 4 * i) }
            let (aa, bb, cc, dd) = (a, b, c, d)
            // Each step updates one register; rotating the tuple keeps the formula uniform.
            for i in 0..<16 {
                let f = (b & c) | (~b & d)
                let t = rotl(a &+ f &+ x[i], shifts1[i % 4])
                (a, b, c, d) = (d, t, b, c)
            }
            for i in 0..<16 {
                let g = (b & c) | (b & d) | (c & d)
                let t = rotl(a &+ g &+ x[round2Order[i]] &+ 0x5A82_7999, shifts2[i % 4])
                (a, b, c, d) = (d, t, b, c)
            }
            for i in 0..<16 {
                let h = b ^ c ^ d
                let t = rotl(a &+ h &+ x[round3Order[i]] &+ 0x6ED9_EBA1, shifts3[i % 4])
                (a, b, c, d) = (d, t, b, c)
            }
            a = a &+ aa
            b = b &+ bb
            c = c &+ cc
            d = d &+ dd
        }

        var out = [UInt8]()
        out.reserveCapacity(16)
        for word in [a, b, c, d] {
            for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: word >> UInt32(8 * i))) }
        }
        return out
    }
}

/// RC4, for NTLM key exchange and the SPNEGO mechListMIC. Never used for bulk data.
struct RC4 {
    private var state: [UInt8]
    private var i: UInt8 = 0
    private var j: UInt8 = 0

    init(key: [UInt8]) {
        precondition(!key.isEmpty)
        state = (0...255).map { UInt8($0) }
        var j: UInt8 = 0
        for i in 0..<256 {
            j = j &+ state[i] &+ key[i % key.count]
            state.swapAt(i, Int(j))
        }
    }

    mutating func process(_ input: [UInt8]) -> [UInt8] {
        var output = input
        for k in output.indices {
            i = i &+ 1
            j = j &+ state[Int(i)]
            state.swapAt(Int(i), Int(j))
            output[k] ^= state[Int(state[Int(i)] &+ state[Int(j)])]
        }
        return output
    }
}
