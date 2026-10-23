/// CRC-32 (IEEE 802.3, reflected polynomial `0xEDB88320`), slicing-by-8. Detects corrupt stroke files.
enum CRC32 {
    /// Initial running value; pass one ``update(_:_:)`` result into the next to checksum in pieces.
    static let initial: UInt32 = 0xFFFF_FFFF

    /// Folds `bytes` into the running value `crc`.
    static func update(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var crc = crc
        guard var p = bytes.baseAddress else { return crc }
        var n = bytes.count
        table.withUnsafeBufferPointer { t in
            while n >= 8 {
                let lo = p.loadUnaligned(as: UInt32.self).littleEndian ^ crc
                let hi = p.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
                crc = t[7 * 256 + Int(lo & 0xFF)] ^ t[6 * 256 + Int((lo >> 8) & 0xFF)]
                    ^ t[5 * 256 + Int((lo >> 16) & 0xFF)] ^ t[4 * 256 + Int(lo >> 24)]
                    ^ t[3 * 256 + Int(hi & 0xFF)] ^ t[2 * 256 + Int((hi >> 8) & 0xFF)]
                    ^ t[1 * 256 + Int((hi >> 16) & 0xFF)] ^ t[Int(hi >> 24)]
                p += 8
                n -= 8
            }
            while n > 0 {
                crc = t[Int((crc ^ UInt32(p.load(as: UInt8.self))) & 0xFF)] ^ (crc >> 8)
                p += 1
                n -= 1
            }
        }
        return crc
    }

    /// Final checksum from a running value.
    static func finalize(_ crc: UInt32) -> UInt32 {
        ~crc
    }

    /// One-shot checksum.
    static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        finalize(update(initial, bytes))
    }

    /// 8 × 256 lookup tables; table `k` advances a byte through `k` further zero bytes.
    private static let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 8 * 256)
        for i in 0 ..< 256 {
            var c = UInt32(i)
            for _ in 0 ..< 8 {
                c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
            }
            t[i] = c
        }
        for i in 0 ..< 256 {
            for k in 1 ..< 8 {
                let prev = t[(k - 1) * 256 + i]
                t[k * 256 + i] = t[Int(prev & 0xFF)] ^ (prev >> 8)
            }
        }
        return t
    }()
}
