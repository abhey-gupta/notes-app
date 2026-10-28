import CoreGraphics
import Foundation
import InkModel

/// Codec and replay for a page's autosave journal, `pages/<pageID>.wal` (ARCHITECTURE.md §4.4).
///
/// Little-endian throughout. Layout:
/// ```
/// file:    header record*
/// header:  "INKW" | u16 formatVersion | u16 flags (0) | u64 baseRev
///          | u64 baseLength | u32 baseCRC | u32 crc32(header bytes 0..<28)          (32 B)
/// record:  u32 payloadLength | u32 crc32(payloadLength bytes + payload) | payload
/// payload: u64 rev (page rev after the edit) | u8 kind | body
/// body:    add 0, remove 1:  placed
///          replace 2:        placed(old) | placed(new)
///          transform 3:      u32 n | n × u128 id | f64 × 6 forward (a b c d tx ty) | f64 × 6 backward
///          recolor 4:        u32 n | n × (u128 id | color from | color to)
///          addImages 5, removeImages 6 (v3):  u32 n | n × (u32 index | image)
///          transformImages 7 (v3):            u32 n | n × u128 id | f64 × 6 forward | f64 × 6 backward
/// placed:  u32 n | n × (u32 index | stroke)             stroke, color and image as in ``StrokeCodec``
/// ```
/// Strokes in records use the ``StrokeCodec`` layout of the same version (version 2 adds the rendering
/// block; version 3 the image kinds, #157). Older journals replay; ``DocumentStore`` folds them into a
/// stroke file at once, so new records never land in an old-format journal.
///
/// The header names the stroke file the journal applies on top of (`baseLength`, `baseCRC`: see
/// ``StrokesIdentity``). Checkpoints rewrite the stroke file before deleting the journal, so a journal
/// whose base no longer matches is already folded in and is discarded rather than replayed twice.
/// That makes replay idempotent for every edit kind, including transforms.
///
/// Each record carries its own length and checksum: a crash mid-append leaves a torn last record that
/// fails one of them and is cut off; everything before it is kept.
enum Journal {
    static let magic: [UInt8] = Array("INKW".utf8)
    /// Version written to, and the newest accepted from, the header.
    static let formatVersion: UInt16 = 3
    static let headerLength = 32
    static let recordHeaderLength = 8
    /// Largest record payload accepted; bounds allocations driven by a (possibly damaged) length.
    static let maxPayloadLength = StrokeCodec.maxBodyLength

    /// What the journal applies on top of.
    struct Header: Hashable {
        /// Page rev when the journal was started.
        var baseRev: UInt64
        /// Stroke file the journal applies on top of.
        var base: StrokesIdentity
        /// Format of the file (and of its records).
        var version: UInt16 = Journal.formatVersion
    }

    /// One decoded record.
    struct Record: Hashable {
        /// Page rev after applying ``edit``.
        var rev: UInt64
        var edit: PageEdit
    }

    /// Why a scan or replay stopped before end of file.
    enum DamageKind: Error, Hashable {
        /// File shorter than a header.
        case tornHeader
        /// Bad magic or header checksum.
        case corruptHeader
        /// Record runs past end of file: crash mid-append.
        case tornRecord
        /// Record checksum mismatch.
        case checksumMismatch
        /// Record checksums but does not decode (or does not apply, during replay).
        case invalidRecord
    }

    /// Where and why a scan stopped early.
    struct Damage: Hashable {
        var kind: DamageKind
        /// Byte offset of the first bad byte range (record start, or 0 for the header).
        var offset: Int
    }

    /// Result of scanning journal bytes.
    struct Scan: Hashable {
        /// `nil` if the header is torn or corrupt (then nothing is replayable).
        var header: Header?
        var records: [Record] = []
        /// End offset of each record in ``records``.
        var recordEnds: [Int] = []
        /// Length of the valid prefix (header + whole, checksummed, decodable records).
        var validLength: Int
        /// Why the scan stopped before end of file, if it did.
        var damage: Damage?
    }

    // MARK: Encoding

    static func encodeHeader(_ header: Header) -> [UInt8] {
        var w = ByteWriter(capacity: headerLength)
        w.bytes.append(contentsOf: magic)
        w.append(header.version)
        w.append(UInt16(0))
        w.append(header.baseRev)
        w.append(header.base.length)
        w.append(header.base.crc)
        w.append(w.bytes.withUnsafeBytes { CRC32.checksum($0) })
        return w.bytes
    }

    /// One framed record.
    /// - Throws: ``JournalTooLarge`` if the payload exceeds ``maxPayloadLength``.
    /// - Parameter version: Stroke layout (tests write version 1 records with it).
    static func encodeRecord(rev: UInt64, edit: PageEdit, version: UInt16 = formatVersion) throws(JournalTooLarge) -> [UInt8] {
        var w = ByteWriter(capacity: recordHeaderLength + payloadSizeHint(edit))
        w.append(UInt32(0))
        w.append(UInt32(0))
        w.append(rev)
        switch edit {
        case let .add(placed):
            w.append(UInt8(0))
            w.append(placed, version: version)
        case let .remove(placed):
            w.append(UInt8(1))
            w.append(placed, version: version)
        case let .replace(old, new):
            w.append(UInt8(2))
            w.append(old, version: version)
            w.append(new, version: version)
        case let .transform(ids, forward, backward):
            w.append(UInt8(3))
            w.append(UInt32(ids.count))
            for id in ids {
                w.append(id)
            }
            w.append(forward)
            w.append(backward)
        case let .recolor(changes):
            w.append(UInt8(4))
            w.append(UInt32(changes.count))
            for change in changes {
                w.append(change.id)
                w.append(change.from)
                w.append(change.to)
            }
        case .addImages, .removeImages, .transformImages:
            appendImageEdit(edit, to: &w)
        }
        let payloadLength = w.bytes.count - recordHeaderLength
        guard payloadLength <= maxPayloadLength else { throw JournalTooLarge() }
        w.bytes.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(payloadLength).littleEndian, toByteOffset: 0, as: UInt32.self)
            var crc = CRC32.update(CRC32.initial, UnsafeRawBufferPointer(rebasing: raw[0 ..< 4]))
            crc = CRC32.update(crc, UnsafeRawBufferPointer(rebasing: raw[recordHeaderLength...]))
            raw.storeBytes(of: CRC32.finalize(crc).littleEndian, toByteOffset: 4, as: UInt32.self)
        }
        return w.bytes
    }

    /// A record payload over ``maxPayloadLength``.
    struct JournalTooLarge: Error {}

    private static func payloadSizeHint(_ edit: PageEdit) -> Int {
        func size(_ placed: [PlacedStroke]) -> Int {
            placed.reduce(4) { $0 + 4 + StrokeCodec.encodedLength($1.stroke) }
        }
        return switch edit {
        case let .add(p), let .remove(p): 9 + size(p)
        case let .replace(old, new): 9 + size(old) + size(new)
        case let .transform(ids, _, _): 9 + 4 + ids.count * 16 + 96
        case let .recolor(changes): 9 + 4 + changes.count * 26
        case let .addImages(p), let .removeImages(p): 9 + 4 + p.count * (4 + StrokeCodec.imageLength)
        case let .transformImages(ids, _, _): 9 + 4 + ids.count * 16 + 96
        }
    }

    // MARK: Decoding

    /// Scans journal bytes, keeping the longest valid prefix. Never traps on malformed input.
    /// - Throws: ``DocumentError/unsupportedFormatVersion(found:supported:)`` for a journal written by a
    ///   newer build (header intact), so it is neither replayed nor deleted.
    static func scan(_ data: Data) throws(DocumentError) -> Scan {
        let result: Result<Scan, DocumentError> = data.withUnsafeBytes { raw in
            Result { () throws(DocumentError) -> Scan in try scan(raw) }
        }
        return try result.get()
    }

    static func scan(_ raw: UnsafeRawBufferPointer) throws(DocumentError) -> Scan {
        guard raw.count >= headerLength else {
            return Scan(header: nil, validLength: 0, damage: raw.isEmpty ? nil : Damage(kind: .tornHeader, offset: 0))
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
        func u64(_ offset: Int) -> UInt64 {
            UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
        guard raw.prefix(4).elementsEqual(magic),
              CRC32.checksum(UnsafeRawBufferPointer(rebasing: raw[0 ..< headerLength - 4])) == u32(headerLength - 4)
        else {
            return Scan(header: nil, validLength: 0, damage: Damage(kind: .corruptHeader, offset: 0))
        }
        let version = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt16.self))
        let flags = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 6, as: UInt16.self))
        guard version >= 1, version <= formatVersion, flags == 0 else {
            throw .unsupportedFormatVersion(found: Int(version), supported: Int(formatVersion))
        }
        let header = Header(baseRev: u64(8), base: StrokesIdentity(length: u64(16), crc: u32(24)), version: version)
        var scan = Scan(header: header, validLength: headerLength)
        var offset = headerLength
        while offset < raw.count {
            switch readRecord(raw, at: offset, version: version) {
            case let .success((record, end)):
                offset = end
                scan.records.append(record)
                scan.recordEnds.append(end)
                scan.validLength = end
            case let .failure(kind):
                scan.damage = Damage(kind: kind, offset: offset)
                return scan
            }
        }
        return scan
    }

    /// Reads the framed record at `offset` (header already validated); returns it with its end offset.
    private static func readRecord(_ raw: UnsafeRawBufferPointer, at offset: Int, version: UInt16) -> Result<(Record, Int), DamageKind> {
        guard raw.count - offset >= recordHeaderLength else { return .failure(.tornRecord) }
        let length = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
        guard length <= maxPayloadLength else { return .failure(.invalidRecord) }
        let end = offset + recordHeaderLength + length
        guard end <= raw.count else { return .failure(.tornRecord) }
        let payload = UnsafeRawBufferPointer(rebasing: raw[offset + recordHeaderLength ..< end])
        var crc = CRC32.update(CRC32.initial, UnsafeRawBufferPointer(rebasing: raw[offset ..< offset + 4]))
        crc = CRC32.update(crc, payload)
        let stored = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
        guard CRC32.finalize(crc) == stored else { return .failure(.checksumMismatch) }
        guard let record = decodePayload(payload, version: version) else { return .failure(.invalidRecord) }
        return .success((record, end))
    }
}

// MARK: Edit payloads

extension Journal {
    /// Decodes one checksummed payload; `nil` if malformed (wrong lengths, unknown kind, trailing bytes).
    static func decodePayload(_ payload: UnsafeRawBufferPointer, version: UInt16 = formatVersion) -> Record? {
        var r = ByteReader(buffer: payload)
        guard r.remaining >= 9 else { return nil }
        let rev = UInt64(littleEndian: r.read(UInt64.self))
        let kind = r.read(UInt8.self)
        guard let edit = readEdit(kind: kind, &r, version: version), r.remaining == 0 else { return nil }
        return Record(rev: rev, edit: edit)
    }

    private static func readEdit(kind: UInt8, _ r: inout ByteReader, version: UInt16) -> PageEdit? {
        switch kind {
        case 0: readPlaced(&r, version: version).map(PageEdit.add)
        case 1: readPlaced(&r, version: version).map(PageEdit.remove)
        case 2: readReplaceEdit(&r, version: version)
        case 3: readTransformEdit(&r)
        case 4: readRecolorEdit(&r)
        case 5 ... 7 where version >= 3: readImageEdit(kind: kind, &r)
        default: nil
        }
    }

    private static func readReplaceEdit(_ r: inout ByteReader, version: UInt16) -> PageEdit? {
        guard let old = readPlaced(&r, version: version), let new = readPlaced(&r, version: version) else { return nil }
        return .replace(old: old, new: new)
    }

    private static func readTransformEdit(_ r: inout ByteReader) -> PageEdit? {
        guard let n = readCount(&r, itemSize: 16) else { return nil }
        let ids = (0 ..< n).map { _ in readID(&r) }
        guard r.remaining >= 96 else { return nil }
        return .transform(ids, forward: readTransform(&r), backward: readTransform(&r))
    }

    private static func readRecolorEdit(_ r: inout ByteReader) -> PageEdit? {
        guard let n = readCount(&r, itemSize: 26) else { return nil }
        var changes: [ColorChange] = []
        changes.reserveCapacity(n)
        for _ in 0 ..< n {
            let id = readID(&r)
            guard let from = try? StrokeCodec.readColor(&r), let to = try? StrokeCodec.readColor(&r) else { return nil }
            changes.append(ColorChange(id: id, from: from, to: to))
        }
        return .recolor(changes)
    }

    /// Reads a `u32` count, rejecting counts that cannot fit in what remains at `itemSize` bytes each.
    static func readCount(_ r: inout ByteReader, itemSize: Int) -> Int? {
        guard r.remaining >= 4 else { return nil }
        let n = Int(UInt32(littleEndian: r.read(UInt32.self)))
        return n <= r.remaining / itemSize ? n : nil
    }

    private static func readPlaced(_ r: inout ByteReader, version: UInt16) -> [PlacedStroke]? {
        guard let n = readCount(&r, itemSize: 4 + StrokeCodec.strokeHeaderLength) else { return nil }
        var placed: [PlacedStroke] = []
        placed.reserveCapacity(n)
        for _ in 0 ..< n {
            guard r.remaining >= 4 else { return nil }
            let index = Int(UInt32(littleEndian: r.read(UInt32.self)))
            guard let stroke = try? StrokeCodec.readStroke(&r, version: version) else { return nil }
            placed.append(PlacedStroke(index: index, stroke: stroke))
        }
        return placed
    }

    /// Caller guarantees 16 bytes remain.
    private static func readID(_ r: inout ByteReader) -> StrokeID {
        StrokeID(uuid: UUID(uuid: r.read(uuid_t.self)))
    }

    /// Caller guarantees 48 bytes remain.
    static func readTransform(_ r: inout ByteReader) -> CGAffineTransform {
        func f() -> CGFloat {
            CGFloat(Double(bitPattern: UInt64(littleEndian: r.read(UInt64.self))))
        }
        return CGAffineTransform(a: f(), b: f(), c: f(), d: f(), tx: f(), ty: f())
    }
}

extension ByteWriter {
    mutating func append(_ placed: [PlacedStroke], version: UInt16 = Journal.formatVersion) {
        append(UInt32(placed.count))
        for p in placed {
            append(UInt32(clamping: p.index))
            append(p.stroke, version: version)
        }
    }

    mutating func append(_ t: CGAffineTransform) {
        for v in [t.a, t.b, t.c, t.d, t.tx, t.ty] {
            append(Double(v).bitPattern)
        }
    }
}
