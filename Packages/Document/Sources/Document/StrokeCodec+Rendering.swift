import CoreGraphics
import Foundation
import InkModel

/// The v2 rendering block that follows each stroke's samples (see ``StrokeCodec``).
///
/// ```
/// u8 flags (bit0 present, bit1 square: heights = widths, bit2 uniform opacity, bit3 render group,
///           bit4 grain offset, bit5 point extras, bit6 wide secondaryScale)
/// if present: u8 inkLength | ink UTF-8 | u32 randomSeed | u128 renderGroupID (bit3)
///             | f64 grainOffset x, y (bit4) | f32 opacity (if uniform)
///             | sampleCount × (f32 width [, f32 height unless square] [, f32 opacity unless uniform]
///               [, f32 or f64 (bit6) secondaryScale, f32 threshold, f32 lateralJitter if extras])
/// ```
struct RenderingLayout {
    static let present: UInt8 = 1
    static let square: UInt8 = 2
    static let uniformOpacity: UInt8 = 4
    static let renderGroup: UInt8 = 8
    static let grainOffset: UInt8 = 16
    static let extras: UInt8 = 32
    static let wideSecondary: UInt8 = 64
    static let allFlags: UInt8 = 127
    /// Longest ink identifier stored (UTF-8 bytes).
    static let maxInkLength = 255

    var inkBytes: [UInt8]
    var square: Bool
    var uniformOpacity: Bool
    var hasGroup: Bool
    var hasGrain: Bool
    var hasExtras: Bool
    /// Some `secondaryScale` isn't exactly a Float32: store them all as f64.
    var wideSecondary: Bool

    init(_ r: StrokeRendering) {
        inkBytes = Self.inkBytes(r.ink)
        square = r.points.allSatisfy { $0.width.bitPattern == $0.height.bitPattern }
        let first = r.points.first?.opacity.bitPattern
        uniformOpacity = r.points.allSatisfy { $0.opacity.bitPattern == first }
        hasGroup = r.renderGroupID != nil
        hasGrain = r.grainOffset != nil
        hasExtras = !r.points.allSatisfy(\.hasDefaultExtras)
        wideSecondary = hasExtras && r.points.contains { Double(Float($0.secondaryScale)).bitPattern != $0.secondaryScale.bitPattern }
    }

    var flags: UInt8 {
        let bits: [(Bool, UInt8)] = [
            (square, Self.square), (uniformOpacity, Self.uniformOpacity), (hasGroup, Self.renderGroup),
            (hasGrain, Self.grainOffset), (hasExtras, Self.extras), (wideSecondary, Self.wideSecondary),
        ]
        return bits.reduce(Self.present) { $1.0 ? $0 | $1.1 : $0 }
    }

    var pointLength: Int {
        Self.pointLength(flags)
    }

    static func pointLength(_ flags: UInt8) -> Int {
        var length = 4
        if flags & square == 0 {
            length += 4
        }
        if flags & uniformOpacity == 0 {
            length += 4
        }
        if flags & extras != 0 {
            length += flags & wideSecondary != 0 ? 16 : 12
        }
        return length
    }

    /// Bytes between the seed and the points: group, grain, shared opacity.
    var extrasLength: Int {
        (hasGroup ? 16 : 0) + (hasGrain ? 16 : 0) + (uniformOpacity ? 4 : 0)
    }

    /// Bytes the block takes (1 when there is no rendering).
    static func encodedLength(_ rendering: StrokeRendering?) -> Int {
        guard let rendering else { return 1 }
        let layout = RenderingLayout(rendering)
        return 2 + layout.inkBytes.count + 4 + layout.extrasLength + rendering.points.count * layout.pointLength
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
        let uniform = flags & RenderingLayout.uniformOpacity != 0
        let hasGroup = flags & RenderingLayout.renderGroup != 0
        let hasGrain = flags & RenderingLayout.grainOffset != 0
        let hasExtras = flags & RenderingLayout.extras != 0
        let wide = flags & RenderingLayout.wideSecondary != 0
        guard hasExtras || !wide else { throw .invalidRendering }
        guard reader.remaining >= 1 else { throw .truncated }
        let inkLength = Int(reader.read(UInt8.self))
        let extras = (hasGroup ? 16 : 0) + (hasGrain ? 16 : 0) + (uniform ? 4 : 0)
        guard reader.remaining >= inkLength + 4 + extras else { throw .truncated }
        guard let ink = String(validating: reader.buffer[reader.offset ..< reader.offset + inkLength], as: UTF8.self) else {
            throw .invalidRendering
        }
        reader.offset += inkLength
        let seed = UInt32(littleEndian: reader.read(UInt32.self))
        let group = hasGroup ? UUID(uuid: reader.read(uuid_t.self)) : nil
        func f32() -> Float {
            Float(bitPattern: UInt32(littleEndian: reader.read(UInt32.self)))
        }
        func f64() -> Double {
            Double(bitPattern: UInt64(littleEndian: reader.read(UInt64.self)))
        }
        let grain = hasGrain ? CGPoint(x: f64(), y: f64()) : nil
        let sharedOpacity: Float = uniform ? f32() : 1
        guard count <= reader.remaining / RenderingLayout.pointLength(flags) else { throw .truncated }
        let points = readPoints(&reader, count: count, flags: flags, sharedOpacity: sharedOpacity)
        return StrokeRendering(ink: ink, randomSeed: seed, points: points, renderGroupID: group, grainOffset: grain)
    }

    /// Caller guarantees `count × pointLength(flags)` bytes remain.
    private static func readPoints(_ reader: inout ByteReader, count: Int, flags: UInt8, sharedOpacity: Float) -> [PointRendering] {
        let square = flags & RenderingLayout.square != 0
        let uniform = flags & RenderingLayout.uniformOpacity != 0
        let hasExtras = flags & RenderingLayout.extras != 0
        let wide = flags & RenderingLayout.wideSecondary != 0
        func f32() -> Float {
            Float(bitPattern: UInt32(littleEndian: reader.read(UInt32.self)))
        }
        return [PointRendering](unsafeUninitializedCapacity: count) { buffer, initialized in
            for i in 0 ..< count {
                let width = f32()
                let height = square ? width : f32()
                let opacity = uniform ? sharedOpacity : f32()
                var point = PointRendering(width: width, height: height, opacity: opacity)
                if hasExtras {
                    point.secondaryScale = wide ? Double(bitPattern: UInt64(littleEndian: reader.read(UInt64.self))) : Double(f32())
                    point.threshold = f32()
                    point.lateralJitter = f32()
                }
                buffer.initializeElement(at: i, to: point)
            }
            initialized = count
        }
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
        if let group = rendering.renderGroupID {
            withUnsafeBytes(of: group.uuid) { bytes.append(contentsOf: $0) }
        }
        if let grain = rendering.grainOffset {
            append(Double(grain.x).bitPattern)
            append(Double(grain.y).bitPattern)
        }
        if layout.uniformOpacity {
            append((rendering.points.first?.opacity ?? 1).bitPattern)
        }
        // Gathered as little-endian 32-bit words, then appended in one copy.
        var words: [UInt32] = []
        words.reserveCapacity(rendering.points.count * layout.pointLength / 4)
        for p in rendering.points {
            words.append(p.width.bitPattern.littleEndian)
            if !layout.square {
                words.append(p.height.bitPattern.littleEndian)
            }
            if !layout.uniformOpacity {
                words.append(p.opacity.bitPattern.littleEndian)
            }
            if layout.hasExtras {
                if layout.wideSecondary {
                    let bits = p.secondaryScale.bitPattern
                    words.append(UInt32(truncatingIfNeeded: bits).littleEndian)
                    words.append(UInt32(truncatingIfNeeded: bits >> 32).littleEndian)
                } else {
                    words.append(Float(p.secondaryScale).bitPattern.littleEndian)
                }
                words.append(p.threshold.bitPattern.littleEndian)
                words.append(p.lateralJitter.bitPattern.littleEndian)
            }
        }
        words.withUnsafeBytes { bytes.append(contentsOf: $0) }
    }
}
