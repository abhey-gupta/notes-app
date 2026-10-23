import Compression
import Foundation
import InkModel

/// Why stroke bytes could not be encoded or decoded. Decoding never traps on malformed input.
public enum StrokeCodecError: Error, Hashable, Sendable {
    /// Fewer bytes than the header or a declared length requires.
    case truncated
    /// Does not start with `INKS`.
    case badMagic
    /// Written by a newer codec (or version 0, which never existed).
    case unsupportedVersion(found: UInt16, supported: UInt16)
    /// Header sets flag bits this version does not understand.
    case unsupportedFlags(UInt32)
    /// Stored CRC-32 does not match header + body: the file is damaged.
    case checksumMismatch
    /// A declared length or count is inconsistent with the data, or a page exceeds ``StrokeCodec/maxBodyLength``.
    case invalidLength
    /// The lz4 body did not decompress to exactly the declared length.
    case decompressionFailed
    /// Unknown pen kind byte.
    case unknownTool(UInt8)
    /// Unknown color kind or semantic slot, or non-zero padding.
    case invalidColor
    /// Two strokes on one page share an ID.
    case duplicateStrokeID(StrokeID)
    /// Bytes left over after the last stroke.
    case trailingBytes
}

/// Binary codec for one page's strokes (`pages/<pageID>.strokes`, ARCHITECTURE.md §4.3).
///
/// Little-endian throughout. Layout:
/// ```
/// header (22 B): "INKS" | u16 formatVersion | u32 strokeCount | u32 flags (bit0: lz4)
///                | u32 bodyLength (uncompressed) | u32 crc32 (header bytes 0..<18, then stored body)
/// body:          stroke*  (lz4-compressed with Apple's `COMPRESSION_LZ4` framing when bit0 is set)
/// stroke:        u128 id | u8 tool | u8 colorKind + 4 B (semantic: slot,0,0,0 · custom: r,g,b,a)
///                | f32 width | u32 sampleCount | sampleCount × (f32 x, y, force, altitude, azimuth, t)
/// ```
/// Encoding is deterministic, so `encode(decode(encode(s))) == encode(s)` byte for byte.
public enum StrokeCodec {
    /// Version written to, and the newest accepted from, the header.
    public static let formatVersion: UInt16 = 1
    /// Largest uncompressed body accepted (256 MiB); bounds allocations driven by header fields.
    public static let maxBodyLength = 1 << 28

    static let magic: [UInt8] = Array("INKS".utf8)
    static let headerLength = 22
    static let checksummedHeaderLength = 18
    static let strokeHeaderLength = 30
    static let sampleLength = 24
    static let lz4Flag: UInt32 = 1

    /// Encodes `strokes` (z-order, bottom first).
    /// - Parameter compress: lz4-compress the body. Skipped automatically when it would not shrink.
    /// - Throws: ``StrokeCodecError/invalidLength`` if the page exceeds ``maxBodyLength``.
    public static func encode(_ strokes: [Stroke], compress: Bool = true) throws(StrokeCodecError) -> Data {
        var bodyLength = 0
        for stroke in strokes {
            bodyLength += strokeHeaderLength + stroke.samples.count * sampleLength
        }
        guard bodyLength <= maxBodyLength else { throw .invalidLength }
        var body = ByteWriter(capacity: bodyLength)
        for stroke in strokes {
            body.append(stroke)
        }
        var flags: UInt32 = 0
        var stored = body.bytes
        if compress, let packed = lz4Encode(body.bytes) {
            flags |= lz4Flag
            stored = packed
        }
        return assemble(strokeCount: UInt32(strokes.count), flags: flags, bodyLength: UInt32(bodyLength), stored: stored)
    }

    /// Decodes a stroke file. Validates every length before reading; any malformation is a typed error.
    public static func decode(_ data: Data) throws(StrokeCodecError) -> [Stroke] {
        let result: Result<[Stroke], StrokeCodecError> = data.withUnsafeBytes { raw in
            Result { () throws(StrokeCodecError) -> [Stroke] in try decode(raw) }
        }
        return try result.get()
    }

    // MARK: Internal (exposed to tests)

    /// Builds a file around an already-stored body: header fields, then checksum.
    static func assemble(strokeCount: UInt32, flags: UInt32, bodyLength: UInt32, stored: [UInt8]) -> Data {
        var header = ByteWriter(capacity: headerLength)
        header.bytes.append(contentsOf: magic)
        header.append(formatVersion)
        header.append(strokeCount)
        header.append(flags)
        header.append(bodyLength)
        var crc = header.bytes.withUnsafeBytes { CRC32.update(CRC32.initial, $0) }
        crc = stored.withUnsafeBytes { CRC32.update(crc, $0) }
        header.append(CRC32.finalize(crc))
        var data = Data(capacity: headerLength + stored.count)
        data.append(contentsOf: header.bytes)
        data.append(contentsOf: stored)
        return data
    }

    static func decode(_ raw: UnsafeRawBufferPointer) throws(StrokeCodecError) -> [Stroke] {
        let header = try Header(validating: raw)
        let stored = UnsafeRawBufferPointer(rebasing: raw[headerLength...])
        if !header.isCompressed, stored.count != header.bodyLength {
            throw stored.count < header.bodyLength ? .truncated : .trailingBytes
        }
        var crc = CRC32.update(CRC32.initial, UnsafeRawBufferPointer(rebasing: raw[0 ..< checksummedHeaderLength]))
        crc = CRC32.update(crc, stored)
        guard CRC32.finalize(crc) == header.crc else { throw .checksumMismatch }
        guard header.bodyLength <= maxBodyLength, header.strokeCount <= header.bodyLength / strokeHeaderLength else {
            throw .invalidLength
        }

        guard header.isCompressed else { return try parseBody(stored, strokeCount: header.strokeCount) }
        guard let body = lz4Decode(stored, length: header.bodyLength) else { throw .decompressionFailed }
        let result: Result<[Stroke], StrokeCodecError> = body.withUnsafeBytes { b in
            Result { () throws(StrokeCodecError) -> [Stroke] in try parseBody(b, strokeCount: header.strokeCount) }
        }
        return try result.get()
    }

    /// Fixed header fields, with magic, version and flags already validated.
    private struct Header {
        var strokeCount: Int
        var isCompressed: Bool
        var bodyLength: Int
        var crc: UInt32

        init(validating raw: UnsafeRawBufferPointer) throws(StrokeCodecError) {
            func u32(_ offset: Int) -> UInt32 {
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            guard raw.count >= headerLength else { throw .truncated }
            guard raw.prefix(4).elementsEqual(magic) else { throw .badMagic }
            let version = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt16.self))
            guard version >= 1, version <= formatVersion else { throw .unsupportedVersion(found: version, supported: formatVersion) }
            let flags = u32(10)
            guard flags & ~lz4Flag == 0 else { throw .unsupportedFlags(flags & ~lz4Flag) }
            strokeCount = Int(u32(6))
            isCompressed = flags & lz4Flag != 0
            bodyLength = Int(u32(14))
            crc = u32(18)
        }
    }

    /// Whether `Sample`'s in-memory layout equals its on-disk layout, so sample arrays copy in bulk.
    static let samplesMatchDiskLayout: Bool = {
        let offsets: [PartialKeyPath<Sample>] = [\.x, \.y, \.force, \.altitude, \.azimuth, \.t]
        return UInt32(1).littleEndian == 1 && MemoryLayout<Sample>.stride == sampleLength
            && offsets.enumerated().allSatisfy { MemoryLayout<Sample>.offset(of: $0.element) == $0.offset * 4 }
    }()

    // MARK: Private

    private static func parseBody(_ body: UnsafeRawBufferPointer, strokeCount: Int) throws(StrokeCodecError) -> [Stroke] {
        var reader = ByteReader(buffer: body)
        var strokes: [Stroke] = []
        strokes.reserveCapacity(strokeCount)
        var ids = Set<StrokeID>(minimumCapacity: strokeCount)
        for _ in 0 ..< strokeCount {
            let stroke = try readStroke(&reader)
            guard ids.insert(stroke.id).inserted else { throw .duplicateStrokeID(stroke.id) }
            strokes.append(stroke)
        }
        guard reader.remaining == 0 else { throw .trailingBytes }
        return strokes
    }

    /// Reads one stroke in the body layout, bounds-checked. Shared with the journal codec.
    static func readStroke(_ reader: inout ByteReader) throws(StrokeCodecError) -> Stroke {
        guard reader.remaining >= strokeHeaderLength else { throw .truncated }
        let id = StrokeID(uuid: UUID(uuid: reader.read(uuid_t.self)))
        let toolByte = reader.read(UInt8.self)
        guard let tool = PenKind(rawValue: toolByte) else { throw .unknownTool(toolByte) }
        let color = try readColor(&reader)
        let width = Float(bitPattern: UInt32(littleEndian: reader.read(UInt32.self)))
        let sampleCount = Int(UInt32(littleEndian: reader.read(UInt32.self)))
        guard sampleCount <= reader.remaining / sampleLength else { throw .truncated }
        let samples = readSamples(&reader, count: sampleCount)
        return Stroke(id: id, tool: tool, color: color, width: width, samples: samples)
    }

    /// Reads a color (u8 kind + 4 B). Caller guarantees 5 bytes remain.
    static func readColor(_ reader: inout ByteReader) throws(StrokeCodecError) -> InkColor {
        let kind = reader.read(UInt8.self)
        let (c0, c1, c2, c3) = reader.read((UInt8, UInt8, UInt8, UInt8).self)
        switch kind {
        case 0:
            guard let slot = SemanticInk(rawValue: c0), c1 == 0, c2 == 0, c3 == 0 else { throw .invalidColor }
            return .semantic(slot)
        case 1:
            return .custom(RGBA8(r: c0, g: c1, b: c2, a: c3))
        default:
            throw .invalidColor
        }
    }

    /// Caller guarantees `count * sampleLength` bytes remain.
    private static func readSamples(_ reader: inout ByteReader, count: Int) -> [Sample] {
        let byteCount = count * sampleLength
        defer { reader.offset += byteCount }
        let src = UnsafeRawBufferPointer(rebasing: reader.buffer[reader.offset ..< reader.offset + byteCount])
        if samplesMatchDiskLayout {
            return [Sample](unsafeUninitializedCapacity: count) { buffer, initialized in
                UnsafeMutableRawBufferPointer(buffer).copyMemory(from: src)
                initialized = count
            }
        }
        return (0 ..< count).map { i in
            func f(_ field: Int) -> Float {
                Float(bitPattern: UInt32(littleEndian: src.loadUnaligned(fromByteOffset: i * sampleLength + field * 4, as: UInt32.self)))
            }
            return Sample(x: f(0), y: f(1), force: f(2), altitude: f(3), azimuth: f(4), t: f(5))
        }
    }

    /// lz4-compresses `bytes`; `nil` if empty or the result would not be smaller.
    private static func lz4Encode(_ bytes: [UInt8]) -> [UInt8]? {
        guard !bytes.isEmpty else { return nil }
        let capacity = bytes.count
        var written = 0
        let out = [UInt8](unsafeUninitializedCapacity: capacity) { dst, initialized in
            initialized = 0
            bytes.withUnsafeBufferPointer { src in
                guard let dstBase = dst.baseAddress, let srcBase = src.baseAddress else { return }
                written = compression_encode_buffer(dstBase, capacity, srcBase, src.count, nil, COMPRESSION_LZ4)
            }
            initialized = written
        }
        return written > 0 && written < capacity ? out : nil
    }

    /// Decompresses to exactly `length` bytes, else `nil` (over-long output is detected via one spare byte).
    private static func lz4Decode(_ stored: UnsafeRawBufferPointer, length: Int) -> [UInt8]? {
        guard let srcBase = stored.baseAddress?.assumingMemoryBound(to: UInt8.self), !stored.isEmpty else {
            return length == 0 ? [] : nil
        }
        let capacity = length + 1
        let out = [UInt8](unsafeUninitializedCapacity: capacity) { dst, initialized in
            guard let dstBase = dst.baseAddress else {
                initialized = 0
                return
            }
            initialized = compression_decode_buffer(dstBase, capacity, srcBase, stored.count, nil, COMPRESSION_LZ4)
        }
        return out.count == length ? out : nil
    }
}

/// Little-endian appender (stroke codec and journal).
struct ByteWriter {
    var bytes: [UInt8] = []

    init(capacity: Int) {
        bytes.reserveCapacity(capacity)
    }

    mutating func append(_ value: some FixedWidthInteger) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func append(_ id: StrokeID) {
        withUnsafeBytes(of: id.uuid.uuid) { bytes.append(contentsOf: $0) }
    }

    /// u8 kind + 4 B: semantic `0, slot, 0, 0, 0`; custom `1, r, g, b, a`.
    mutating func append(_ color: InkColor) {
        switch color {
        case let .semantic(slot):
            bytes.append(contentsOf: [0, slot.rawValue, 0, 0, 0])
        case let .custom(c):
            bytes.append(contentsOf: [1, c.r, c.g, c.b, c.a])
        }
    }

    mutating func append(_ stroke: Stroke) {
        append(stroke.id)
        append(stroke.tool.rawValue)
        append(stroke.color)
        append(stroke.width.bitPattern)
        append(UInt32(stroke.samples.count))
        if StrokeCodec.samplesMatchDiskLayout {
            stroke.samples.withUnsafeBytes { bytes.append(contentsOf: $0) }
        } else {
            for s in stroke.samples {
                for f in [s.x, s.y, s.force, s.altitude, s.azimuth, s.t] {
                    append(f.bitPattern)
                }
            }
        }
    }
}

/// Bounds-unchecked reader; callers check ``remaining`` first.
struct ByteReader {
    let buffer: UnsafeRawBufferPointer
    var offset = 0

    var remaining: Int {
        buffer.count - offset
    }

    mutating func read<T: BitwiseCopyable>(_: T.Type) -> T {
        defer { offset += MemoryLayout<T>.size }
        return buffer.loadUnaligned(fromByteOffset: offset, as: T.self)
    }
}
