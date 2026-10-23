import Foundation
import InkModel
import Testing

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct UUIDv7Tests {
    @Test func versionVariantAndTimestamp() throws {
        let before = UInt64(Date().timeIntervalSince1970 * 1000)
        let id = UUIDv7.make()
        let after = UInt64(Date().timeIntervalSince1970 * 1000)
        #expect(id.uuid.6 >> 4 == 7)
        #expect(id.uuid.8 >> 6 == 0b10)
        let ms = try #require(UUIDv7.milliseconds(of: id))
        #expect(ms >= before && ms <= after + 1)
        #expect(UUIDv7.date(of: id) != nil)
    }

    @Test func fieldsRoundTrip() {
        let id = UUIDv7.make(milliseconds: 0x0123_4567_89AB, randA: 0xFFF, randB: .max)
        #expect(UUIDv7.milliseconds(of: id) == 0x0123_4567_89AB)
        #expect(id.uuidString.hasPrefix("01234567-89AB-7FFF-BFFF"))
    }

    @Test func rejectsNonV7() throws {
        let v1 = try #require(UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"))
        let badVariant = try #require(UUID(uuidString: "6BA7B810-9DAD-71D1-00B4-00C04FD430C8"))
        #expect(UUIDv7.milliseconds(of: v1) == nil)
        #expect(UUIDv7.date(of: badVariant) == nil)
    }

    @Test func sharedGeneratorIsMonotonic() {
        let ids = (0 ..< 5000).map { _ in StrokeID() }
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
    }

    @Test func generatorHandlesBurstsAndClockSteppingBack() {
        var gen = UUIDv7Generator()
        var rng = SplitMix64(state: 1)
        var previous = StrokeID(uuid: gen.next(milliseconds: 1000, using: &rng))
        // 10k in one millisecond overflows the 12-bit counter; then the clock steps back.
        for i in 0 ..< 12000 {
            let ms: UInt64 = i < 10000 ? 1000 : 900
            let next = StrokeID(uuid: gen.next(milliseconds: ms, using: &rng))
            #expect(previous < next)
            previous = next
        }
        #expect(UUIDv7.milliseconds(of: previous.uuid).map { $0 > 1000 } == true)
    }

    @Test func typedIDCodableAndDescription() throws {
        let id = PageID()
        let data = try JSONEncoder().encode([id])
        #expect(String(bytes: data, encoding: .utf8) == "[\"\(id.uuid.uuidString)\"]")
        #expect(try JSONDecoder().decode([PageID].self, from: data) == [id])
        #expect(id.description == id.uuid.uuidString)
        #expect(PageID(uuidString: id.uuid.uuidString) == id)
        #expect(PageID(uuidString: "nope") == nil)
    }
}
