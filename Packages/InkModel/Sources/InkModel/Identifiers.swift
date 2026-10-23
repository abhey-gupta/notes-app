import Foundation
import Synchronization

/// RFC 9562 UUID version 7: 48-bit Unix-epoch milliseconds, then random bits.
///
/// IDs sort by creation time (byte order == time order), which keeps journals, file listings and
/// future sync merges naturally ordered. ``make()`` is monotonic within a process: IDs minted in the
/// same millisecond use a 12-bit counter in `rand_a` (RFC 9562 §6.2, method 1).
public enum UUIDv7 {
    private static let shared = Mutex(UUIDv7Generator())

    /// Returns a new, process-wide monotonically increasing UUIDv7 for the current time.
    public static func make() -> UUID {
        let now = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
        return shared.withLock { generator in
            var rng = SystemRandomNumberGenerator()
            return generator.next(milliseconds: now, using: &rng)
        }
    }

    /// Assembles a UUIDv7 from its fields. Extra high bits of each field are discarded.
    /// - Parameters:
    ///   - milliseconds: Unix time in milliseconds (low 48 bits used).
    ///   - randA: 12-bit `rand_a` field (counter or random).
    ///   - randB: 62-bit `rand_b` field.
    public static func make(milliseconds: UInt64, randA: UInt16, randB: UInt64) -> UUID {
        let ms = milliseconds & 0xFFFF_FFFF_FFFF
        let a = randA & 0x0FFF
        let b = randB & 0x3FFF_FFFF_FFFF_FFFF
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: ms >> 40), UInt8(truncatingIfNeeded: ms >> 32),
            UInt8(truncatingIfNeeded: ms >> 24), UInt8(truncatingIfNeeded: ms >> 16),
            UInt8(truncatingIfNeeded: ms >> 8), UInt8(truncatingIfNeeded: ms),
            0x70 | UInt8(truncatingIfNeeded: a >> 8), UInt8(truncatingIfNeeded: a),
            0x80 | UInt8(truncatingIfNeeded: b >> 56), UInt8(truncatingIfNeeded: b >> 48),
            UInt8(truncatingIfNeeded: b >> 40), UInt8(truncatingIfNeeded: b >> 32),
            UInt8(truncatingIfNeeded: b >> 24), UInt8(truncatingIfNeeded: b >> 16),
            UInt8(truncatingIfNeeded: b >> 8), UInt8(truncatingIfNeeded: b)
        ))
    }

    /// Unix milliseconds embedded in `uuid`, or `nil` if it is not a version-7 UUID.
    public static func milliseconds(of uuid: UUID) -> UInt64? {
        let u = uuid.uuid
        guard u.6 >> 4 == 7, u.8 >> 6 == 0b10 else { return nil }
        return [u.0, u.1, u.2, u.3, u.4, u.5].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// Creation date embedded in `uuid`, or `nil` if it is not a version-7 UUID.
    public static func date(of uuid: UUID) -> Date? {
        milliseconds(of: uuid).map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}

/// Stateful, monotonic UUIDv7 generator. Value type; wrap in a lock to share (``UUIDv7/make()`` does).
///
/// Within one millisecond (or if the clock steps backwards) the 12-bit `rand_a` counter increments;
/// on counter overflow the timestamp is advanced by 1 ms, so output is strictly increasing.
public struct UUIDv7Generator: Sendable {
    private var lastMilliseconds: UInt64 = 0
    private var counter: UInt16 = 0

    /// Creates a generator with no history.
    public init() {}

    /// Returns the next UUID, strictly greater (bytewise) than every UUID this generator returned before.
    /// - Parameters:
    ///   - milliseconds: Current Unix time in milliseconds.
    ///   - rng: Randomness source for `rand_b` and the per-millisecond counter seed.
    public mutating func next(milliseconds: UInt64, using rng: inout some RandomNumberGenerator) -> UUID {
        if milliseconds > lastMilliseconds {
            lastMilliseconds = milliseconds
            // Seed in the lower half so a burst within one millisecond rarely overflows.
            counter = UInt16.random(in: 0 ..< 0x800, using: &rng)
        } else if counter >= 0x0FFF {
            lastMilliseconds += 1
            counter = 0
        } else {
            counter += 1
        }
        return UUIDv7.make(milliseconds: lastMilliseconds, randA: counter, randB: rng.next())
    }
}

/// Phantom-typed, time-ordered identifier. Distinct tags make `PageID` and `StrokeID` incompatible types.
///
/// Encodes as a plain UUID string. Ordering is byte order, i.e. creation order for UUIDv7.
public struct TypedID<Tag>: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    /// Underlying UUID.
    public let uuid: UUID

    /// Mints a fresh UUIDv7-backed identifier.
    public init() {
        uuid = UUIDv7.make()
    }

    /// Wraps an existing UUID (e.g. decoded from disk).
    public init(uuid: UUID) {
        self.uuid = uuid
    }

    /// Parses a UUID string; `nil` if malformed.
    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.uuid = uuid
    }

    public init(from decoder: any Decoder) throws {
        uuid = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        withUnsafeBytes(of: lhs.uuid.uuid) { l in
            withUnsafeBytes(of: rhs.uuid.uuid) { r in l.lexicographicallyPrecedes(r) }
        }
    }

    public var description: String {
        uuid.uuidString
    }
}

/// Tag for ``NotebookID``.
public enum NotebookTag {}
/// Tag for ``PageID``.
public enum PageTag {}
/// Tag for ``StrokeID``.
public enum StrokeTag {}

/// Identifies a ``Notebook``.
public typealias NotebookID = TypedID<NotebookTag>
/// Identifies a ``Page``.
public typealias PageID = TypedID<PageTag>
/// Identifies a ``Stroke``.
public typealias StrokeID = TypedID<StrokeTag>
