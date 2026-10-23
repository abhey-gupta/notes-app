import InkModel

/// The v2 rendering block that follows each stroke's samples (see ``StrokeCodec``).
///
/// ```
/// u8 flags (bit0 present, bit1 square: heights = widths, bit2 uniform opacity)
/// if present: u8 inkLength | ink UTF-8 | u32 randomSeed | f32 opacity (if uniform)
///             | sampleCount × (f32 width [, f32 height unless square] [, f32 opacity unless uniform])
/// ```
struct RenderingLayout {
    static let present: UInt8 = 1
    static let square: UInt8 = 2
    static let uniformOpacity: UInt8 = 4
    static let allFlags: UInt8 = 7
    /// Longest ink identifier stored (UTF-8 bytes).
    static let maxInkLength = 255

    var inkBytes: [UInt8]
    var square: Bool
    var uniformOpacity: Bool

    init(_ r: StrokeRendering) {
        inkBytes = Self.inkBytes(r.ink)
        square = r.points.allSatisfy { $0.width.bitPattern == $0.height.bitPattern }
        let first = r.points.first?.opacity.bitPattern
        uniformOpacity = r.points.allSatisfy { $0.opacity.bitPattern == first }
    }

    var flags: UInt8 {
        Self.present | (square ? Self.square : 0) | (uniformOpacity ? Self.uniformOpacity : 0)
    }

    var pointLength: Int {
        Self.pointLength(square: square, uniformOpacity: uniformOpacity)
    }

    static func pointLength(square: Bool, uniformOpacity: Bool) -> Int {
        4 + (square ? 0 : 4) + (uniformOpacity ? 0 : 4)
    }

    /// Bytes the block takes (1 when there is no rendering).
    static func encodedLength(_ rendering: StrokeRendering?) -> Int {
        guard let rendering else { return 1 }
        let layout = RenderingLayout(rendering)
        return 2 + layout.inkBytes.count + 4 + (layout.uniformOpacity ? 4 : 0) + rendering.points.count * layout.pointLength
    }

    /// UTF-8 of `ink`, cut to whole scalars within ``maxInkLength`` bytes.
    private static func inkBytes(_ ink: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for scalar in ink.unicodeScalars {
            let utf8 = Array(String(scalar).utf8)
            guard bytes.count + utf8.count <= maxInkLength else { break }
            bytes += utf8
        }
        return bytes
    }
}

extension StrokeCodec {
    /// Reads a v2 rendering block for `count` samples.
    static func readRendering(_ reader: inout ByteReader, count: Int) throws(StrokeCodecError) -> StrokeRendering? {
        guard reader.remaining >= 1 else { throw .truncated }
        let flags = reader.read(UInt8.self)
        guard flags & ~RenderingLayout.allFlags == 0 else { throw .invalidRendering }
        guard flags & RenderingLayout.present != 0 else {
            guard flags == 0 else { throw .invalidRendering }
            return nil
        }
        let square = flags & RenderingLayout.square != 0
        let uniform = flags & RenderingLayout.uniformOpacity != 0
        guard reader.remaining >= 1 else { throw .truncated }
        let inkLength = Int(reader.read(UInt8.self))
        guard reader.remaining >= inkLength + 4 + (uniform ? 4 : 0) else { throw .truncated }
        guard let ink = String(validating: reader.buffer[reader.offset ..< reader.offset + inkLength], as: UTF8.self) else {
            throw .invalidRendering
        }
        reader.offset += inkLength
        let seed = UInt32(littleEndian: reader.read(UInt32.self))
        func f32() -> Float {
            Float(bitPattern: UInt32(littleEndian: reader.read(UInt32.self)))
        }
        let sharedOpacity: Float = uniform ? f32() : 1
        guard count <= reader.remaining / RenderingLayout.pointLength(square: square, uniformOpacity: uniform) else { throw .truncated }
        let points = [PointRendering](unsafeUninitializedCapacity: count) { buffer, initialized in
            for i in 0 ..< count {
                let width = f32()
                let height = square ? width : f32()
                let opacity = uniform ? sharedOpacity : f32()
                buffer.initializeElement(at: i, to: PointRendering(width: width, height: height, opacity: opacity))
            }
            initialized = count
        }
        return StrokeRendering(ink: ink, randomSeed: seed, points: points)
    }
}

extension ByteWriter {
    /// The v2 rendering block (a single 0 byte for `nil`).
    mutating func append(_ rendering: StrokeRendering?) {
        guard let rendering else {
            append(UInt8(0))
            return
        }
        let layout = RenderingLayout(rendering)
        append(layout.flags)
        append(UInt8(layout.inkBytes.count))
        bytes.append(contentsOf: layout.inkBytes)
        append(rendering.randomSeed)
        if layout.uniformOpacity {
            append((rendering.points.first?.opacity ?? 1).bitPattern)
        }
        for p in rendering.points {
            append(p.width.bitPattern)
            if !layout.square {
                append(p.height.bitPattern)
            }
            if !layout.uniformOpacity {
                append(p.opacity.bitPattern)
            }
        }
    }
}
