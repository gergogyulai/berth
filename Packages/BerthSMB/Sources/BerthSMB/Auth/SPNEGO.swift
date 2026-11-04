import Foundation

/// Just enough DER for SPNEGO (RFC 4178) tokens carrying NTLMSSP.
enum DER {
    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        [tag] + length(body.count) + body
    }

    struct Element {
        var tag: UInt8
        var body: Range<Int>
        var next: Int
    }

    static func read(_ bytes: [UInt8], at position: Int, limit: Int? = nil) throws -> Element {
        let end = limit ?? bytes.count
        guard position + 2 <= end else { throw SMBError.malformed("truncated DER element") }
        let tag = bytes[position]
        var cursor = position + 1
        var length = Int(bytes[cursor])
        cursor += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, cursor + count <= end else { throw SMBError.malformed("bad DER length") }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[cursor])
                cursor += 1
            }
        }
        guard cursor + length <= end else { throw SMBError.malformed("DER element overruns its container") }
        return Element(tag: tag, body: cursor..<(cursor + length), next: cursor + length)
    }
}

enum SPNEGO {
    static let spnegoOID: [UInt8] = [0x2B, 0x06, 0x01, 0x05, 0x05, 0x02]
    static let ntlmOID: [UInt8] = [0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x0A]

    /// MechTypeList as sent in NegTokenInit; the mechListMIC is computed over exactly these bytes.
    static let mechTypes: [UInt8] = DER.tlv(0x30, DER.tlv(0x06, ntlmOID))

    /// GSS-API InitialContextToken wrapping a NegTokenInit with an NTLMSSP NEGOTIATE.
    static func initToken(mechToken: [UInt8]) -> [UInt8] {
        let negTokenInit = DER.tlv(0x30, DER.tlv(0xA0, mechTypes) + DER.tlv(0xA2, DER.tlv(0x04, mechToken)))
        return DER.tlv(0x60, DER.tlv(0x06, spnegoOID) + DER.tlv(0xA0, negTokenInit))
    }

    /// NegTokenResp carrying the NTLMSSP AUTHENTICATE and, when available, the mechListMIC.
    static func responseToken(_ token: [UInt8], mechListMIC: [UInt8]?) -> [UInt8] {
        var body = DER.tlv(0xA2, DER.tlv(0x04, token))
        if let mechListMIC { body += DER.tlv(0xA3, DER.tlv(0x04, mechListMIC)) }
        return DER.tlv(0xA1, DER.tlv(0x30, body))
    }

    struct Response {
        var negState: UInt8?
        var responseToken: [UInt8]?
        var mechListMIC: [UInt8]?
    }

    static func parseResponse(_ blob: [UInt8]) throws -> Response {
        let outer = try DER.read(blob, at: 0)
        guard outer.tag == 0xA1 else { throw SMBError.malformed("expected SPNEGO NegTokenResp, got tag \(outer.tag)") }
        let sequence = try DER.read(blob, at: outer.body.lowerBound, limit: outer.body.upperBound)
        guard sequence.tag == 0x30 else { throw SMBError.malformed("NegTokenResp is not a SEQUENCE") }
        var response = Response()
        var cursor = sequence.body.lowerBound
        while cursor < sequence.body.upperBound {
            let field = try DER.read(blob, at: cursor, limit: sequence.body.upperBound)
            let inner = try DER.read(blob, at: field.body.lowerBound, limit: field.body.upperBound)
            switch field.tag {
            case 0xA0:
                if let first = blob[inner.body].first { response.negState = first }
            case 0xA2:
                response.responseToken = Array(blob[inner.body])
            case 0xA3:
                response.mechListMIC = Array(blob[inner.body])
            default:
                break
            }
            cursor = field.next
        }
        return response
    }
}
