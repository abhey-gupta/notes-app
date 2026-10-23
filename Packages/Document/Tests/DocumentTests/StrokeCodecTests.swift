@testable import Document
import Foundation
import InkModel
import Testing

/// Header field offsets (see ``StrokeCodec``).
private enum Offset {
    static let version = 4, strokeCount = 6, flags = 10, bodyLength = 14, crc = 18, body = 22
    /// Within a stroke record.
    static let tool = 16, colorKind = 17, sampleCount = 26
}

/// Rebuilds an uncompressed file after mutating its body/fields, with a valid checksum, so mutations
/// reach the body parser instead of being caught by the CRC.
private func rebuilt(_ file: Data, strokeCount: UInt32? = nil, flags: UInt32 = 0, mutate: (inout [UInt8]) -> Void) -> Data {
    let bytes = [UInt8](file)
    var body = Array(bytes[Offset.body...])
    mutate(&body)
    let count = strokeCount ?? bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(
        fromByteOffset: Offset.strokeCount,
        as: UInt32.self
    )) }
    return StrokeCodec.assemble(strokeCount: count, flags: flags, bodyLength: UInt32(body.count), stored: body)
}

private func put(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
    withUnsafeBytes(of: value.littleEndian) { bytes.replaceSubrange(offset ..< offset + 4, with: $0) }
}

struct StrokeCodecTests {
    @Test func crcMatchesReferenceVector() {
        #expect(Array("123456789".utf8).withUnsafeBytes(CRC32.checksum) == 0xCBF4_3926)
        #expect([UInt8]().withUnsafeBytes(CRC32.checksum) == 0)
    }

    @Test func headerLayout() throws {
        var rng = SplitMix64(seed: 1)
        let strokes = Fixtures.strokes(&rng, count: 3, samples: 5)
        let data = try StrokeCodec.encode(strokes, compress: false)
        let bytes = [UInt8](data)
        #expect(Array(bytes[0 ..< 4]) == Array("INKS".utf8))
        #expect(Array(bytes[4 ..< 10]) == [1, 0, 3, 0, 0, 0])
        #expect(Array(bytes[10 ..< 14]) == [0, 0, 0, 0])
        #expect(bytes.count == 22 + 3 * (30 + 5 * 24))
        let first = strokes[0]
        #expect(Array(bytes[22 ..< 38]) == withUnsafeBytes(of: first.id.uuid.uuid) { Array($0) })
        #expect(bytes[22 + Offset.tool] == first.tool.rawValue)
        #expect(bytes[22 + Offset.sampleCount] == 5)
        let x = bytes
            .withUnsafeBytes { Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 22 + 30, as: UInt32.self))) }
        #expect(x == first.samples[0].x)
    }

    @Test func colorEncoding() throws {
        let semantic = Stroke(tool: .brush, color: .semantic(.red), width: 1, samples: [])
        let custom = Stroke(tool: .brush, color: .custom(RGBA8(r: 1, g: 2, b: 3, a: 4)), width: 1, samples: [])
        let bytes = try [UInt8](StrokeCodec.encode([semantic, custom], compress: false))
        #expect(Array(bytes[22 + 17 ..< 22 + 22]) == [0, SemanticInk.red.rawValue, 0, 0, 0])
        #expect(Array(bytes[22 + 30 + 17 ..< 22 + 30 + 22]) == [1, 1, 2, 3, 4])
    }

    @Test func emptyPage() throws {
        let data = try StrokeCodec.encode([])
        #expect(data.count == 22)
        #expect(try StrokeCodec.decode(data).isEmpty)
    }

    @Test(arguments: [true, false])
    func randomizedRoundTripIsByteIdentical(compress: Bool) throws {
        var rng = SplitMix64(seed: compress ? 7 : 8)
        for _ in 0 ..< 300 {
            let strokes = Fixtures.strokes(&rng, count: Int.random(in: 0 ... 40, using: &rng))
            let data = try StrokeCodec.encode(strokes, compress: compress)
            let decoded = try StrokeCodec.decode(data)
            #expect(decoded == strokes)
            #expect(decoded.map(\.bounds) == strokes.map(\.bounds))
            #expect(try StrokeCodec.encode(decoded, compress: compress) == data)
        }
    }

    @Test func densePageCompresses() throws {
        let strokes = Fixtures.densePage()
        let raw = try StrokeCodec.encode(strokes, compress: false)
        let packed = try StrokeCodec.encode(strokes)
        #expect(packed.count < raw.count)
        #expect([UInt8](packed)[Offset.flags] == 1)
        #expect(try StrokeCodec.decode(packed) == strokes)
        report("dense page 400×60: raw \(raw.count) B, lz4 \(packed.count) B")
    }

    @Test func nonFiniteFloatsSurviveBitExact() throws {
        let odd: [Float] = [.nan, -.infinity, .infinity, -0.0, .leastNonzeroMagnitude, Float(bitPattern: 0x7FC0_1234)]
        let samples = odd.map { Sample(x: $0, y: $0, force: $0, altitude: $0, azimuth: $0, t: $0) }
        let stroke = Stroke(tool: .ballpoint, color: .primary, width: .nan, samples: samples)
        let data = try StrokeCodec.encode([stroke])
        let decoded = try StrokeCodec.decode(data)
        #expect(try StrokeCodec.encode(decoded) == data)
        #expect(decoded[0].samples.map(\.x.bitPattern) == odd.map(\.bitPattern))
    }

    // MARK: Typed errors

    @Test func rejectsBadMagic() throws {
        var bytes = try [UInt8](StrokeCodec.encode([]))
        bytes[0] = UInt8(ascii: "X")
        #expect(throws: StrokeCodecError.badMagic) { try StrokeCodec.decode(Data(bytes)) }
    }

    @Test(arguments: [UInt16(0), 2, 0xFFFF])
    func rejectsUnsupportedVersion(version: UInt16) throws {
        var bytes = try [UInt8](StrokeCodec.encode([]))
        bytes[Offset.version] = UInt8(version & 0xFF)
        bytes[Offset.version + 1] = UInt8(version >> 8)
        #expect(throws: StrokeCodecError.unsupportedVersion(found: version, supported: 1)) { try StrokeCodec.decode(Data(bytes)) }
    }

    @Test func rejectsUnknownFlags() throws {
        let data = try rebuilt(StrokeCodec.encode([]), flags: 0b110) { _ in }
        #expect(throws: StrokeCodecError.unsupportedFlags(0b110)) { try StrokeCodec.decode(data) }
    }

    @Test func rejectsChecksumMismatch() throws {
        var rng = SplitMix64(seed: 2)
        var bytes = try [UInt8](StrokeCodec.encode(Fixtures.strokes(&rng, count: 2, samples: 3), compress: false))
        bytes[bytes.count - 1] ^= 0x01
        #expect(throws: StrokeCodecError.checksumMismatch) { try StrokeCodec.decode(Data(bytes)) }
    }

    @Test func rejectsMalformedBodies() throws {
        var rng = SplitMix64(seed: 3)
        let strokes = Fixtures.strokes(&rng, count: 2, samples: 3)
        let file = try StrokeCodec.encode(strokes, compress: false)
        let second = 30 + 3 * 24

        #expect(throws: StrokeCodecError.unknownTool(9)) { try StrokeCodec.decode(rebuilt(file) { $0[Offset.tool] = 9 }) }
        #expect(throws: StrokeCodecError.invalidColor) { try StrokeCodec.decode(rebuilt(file) { $0[Offset.colorKind] = 2 }) }
        #expect(throws: StrokeCodecError.invalidColor) {
            try StrokeCodec.decode(rebuilt(file) { $0.replaceSubrange(Offset.colorKind ..< Offset.colorKind + 5, with: [0, 1, 0, 0, 7]) })
        }
        #expect(throws: StrokeCodecError.invalidColor) {
            try StrokeCodec.decode(rebuilt(file) { $0.replaceSubrange(Offset.colorKind ..< Offset.colorKind + 2, with: [0, 200]) })
        }
        #expect(throws: StrokeCodecError.duplicateStrokeID(strokes[0].id)) {
            try StrokeCodec.decode(rebuilt(file) { body in
                let firstID = Array(body[0 ..< 16])
                body.replaceSubrange(second ..< second + 16, with: firstID)
            })
        }
        #expect(throws: StrokeCodecError.truncated) {
            try StrokeCodec.decode(rebuilt(file) { put(0xFFFF_FFFF, at: Offset.sampleCount, in: &$0) })
        }
        #expect(throws: StrokeCodecError.truncated) {
            try StrokeCodec.decode(rebuilt(file) { put(4, at: second + Offset.sampleCount, in: &$0) })
        }
        #expect(throws: StrokeCodecError.trailingBytes) { try StrokeCodec.decode(rebuilt(file) { $0.append(0) }) }
        #expect(throws: StrokeCodecError.trailingBytes) { try StrokeCodec.decode(rebuilt(file, strokeCount: 1) { _ in }) }
        #expect(throws: StrokeCodecError.truncated) { try StrokeCodec.decode(rebuilt(file, strokeCount: 3) { _ in }) }
        #expect(throws: StrokeCodecError.invalidLength) { try StrokeCodec.decode(rebuilt(file, strokeCount: .max) { _ in }) }
    }

    @Test func rejectsLengthMismatches() throws {
        var rng = SplitMix64(seed: 4)
        var bytes = try [UInt8](StrokeCodec.encode(Fixtures.strokes(&rng, count: 2, samples: 3), compress: false))
        bytes.removeLast()
        #expect(throws: StrokeCodecError.truncated) { try StrokeCodec.decode(Data(bytes)) }
        bytes.append(contentsOf: [0, 0])
        #expect(throws: StrokeCodecError.trailingBytes) { try StrokeCodec.decode(Data(bytes)) }
        #expect(throws: StrokeCodecError.truncated) { try StrokeCodec.decode(Data(bytes[0 ..< 21])) }
    }

    @Test func rejectsBadCompressedBody() throws {
        let file = try StrokeCodec.encode(Fixtures.densePage().prefix(20).map(\.self))
        let bytes = [UInt8](file)
        let length = bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: Offset.bodyLength, as: UInt32.self)) }
        let stored = Array(bytes[Offset.body...])
        let wrongLength = StrokeCodec.assemble(strokeCount: 20, flags: 1, bodyLength: length - 1, stored: stored)
        #expect(throws: StrokeCodecError.decompressionFailed) { try StrokeCodec.decode(wrongLength) }
        let longer = StrokeCodec.assemble(strokeCount: 20, flags: 1, bodyLength: length + 1, stored: stored)
        #expect(throws: StrokeCodecError.decompressionFailed) { try StrokeCodec.decode(longer) }
        let tooBig = StrokeCodec.assemble(strokeCount: 20, flags: 1, bodyLength: .max, stored: stored)
        #expect(throws: StrokeCodecError.invalidLength) { try StrokeCodec.decode(tooBig) }
        let garbage = StrokeCodec.assemble(strokeCount: 1, flags: 1, bodyLength: 100, stored: [1, 2, 3, 4, 5])
        #expect(throws: StrokeCodecError.decompressionFailed) { try StrokeCodec.decode(garbage) }
    }
}

/// Fuzz: thousands of malformed inputs; each must decode or throw a ``StrokeCodecError`` (typed throws make
/// any other error impossible), never trap.
struct StrokeCodecFuzzTests {
    static let seeds: [UInt64] = [11, 12]

    @Test(arguments: [true, false])
    func everyTruncationThrows(compress: Bool) throws {
        var rng = SplitMix64(seed: 5)
        let data = try StrokeCodec.encode(Fixtures.strokes(&rng, count: 12, samples: 20), compress: compress)
        for length in 0 ..< data.count {
            #expect(throws: StrokeCodecError.self) { try StrokeCodec.decode(data.prefix(length)) }
        }
    }

    @Test(arguments: seeds)
    func bitFlipsAreDetected(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        for compress in [true, false] {
            let data = try StrokeCodec.encode(Fixtures.strokes(&rng, count: 10, samples: 30), compress: compress)
            for _ in 0 ..< 2500 {
                var bytes = [UInt8](data)
                for _ in 0 ..< Int.random(in: 1 ... 4, using: &rng) {
                    bytes[Int.random(in: 0 ..< bytes.count, using: &rng)] ^= 1 << UInt8.random(in: 0 ..< 8, using: &rng)
                }
                guard bytes != [UInt8](data) else { continue }
                #expect(throws: StrokeCodecError.self) { try StrokeCodec.decode(Data(bytes)) }
            }
        }
    }

    /// Corruption behind a valid checksum exercises the body parser and the lz4 decoder directly.
    @Test(arguments: seeds)
    func corruptBodiesWithValidChecksumNeverTrap(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        var decoded = 0
        var rejected = 0
        let raw = try StrokeCodec.encode(Fixtures.strokes(&rng, count: 8, samples: 12), compress: false)
        let packed = try StrokeCodec.encode(Fixtures.strokes(&rng, count: 8, samples: 40))
        for _ in 0 ..< 3000 {
            let compressed = Bool.random(using: &rng)
            var bytes = [UInt8](compressed ? packed : raw)
            var body = Array(bytes[Offset.body...])
            switch Int.random(in: 0 ..< 4, using: &rng) {
            case 0: // byte smash
                for _ in 0 ..< Int.random(in: 1 ... 8, using: &rng) {
                    body[Int.random(in: 0 ..< body.count, using: &rng)] = UInt8.random(in: 0 ... 255, using: &rng)
                }
            case 1: // truncate or extend
                body = Int.random(in: 0 ... 1, using: &rng) == 0
                    ? Array(body.prefix(Int.random(in: 0 ..< body.count, using: &rng)))
                    : body + (0 ..< Int.random(in: 1 ... 64, using: &rng)).map { _ in UInt8.random(in: 0 ... 255, using: &rng) }
            case 2: // splice a random u32 (often a length field)
                let at = Int.random(in: 0 ... body.count - 4, using: &rng)
                put(UInt32.random(in: 0 ... .max, using: &rng) >> UInt32.random(in: 0 ..< 32, using: &rng), at: at, in: &body)
            default: // pure noise
                body = (0 ..< Int.random(in: 0 ... 512, using: &rng)).map { _ in UInt8.random(in: 0 ... 255, using: &rng) }
            }
            let bodyLength = compressed
                ? bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: Offset.bodyLength, as: UInt32.self)) }
                : UInt32(body.count)
            bytes = [UInt8](StrokeCodec.assemble(
                strokeCount: UInt32.random(in: 0 ... 12, using: &rng),
                flags: compressed ? 1 : 0,
                bodyLength: bodyLength,
                stored: body
            ))
            do {
                _ = try StrokeCodec.decode(Data(bytes))
                decoded += 1
            } catch {
                rejected += 1
            }
        }
        #expect(rejected > 0)
        #expect(decoded + rejected == 3000)
    }

    @Test(arguments: seeds)
    func randomBytesThrow(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for _ in 0 ..< 2000 {
            var bytes = (0 ..< Int.random(in: 0 ... 256, using: &rng)).map { _ in UInt8.random(in: 0 ... 255, using: &rng) }
            if bytes.count >= 6, Bool.random(using: &rng) {
                bytes.replaceSubrange(0 ..< 6, with: Array("INKS".utf8) + [1, 0])
            }
            #expect(throws: StrokeCodecError.self) { try StrokeCodec.decode(Data(bytes)) }
        }
    }
}
