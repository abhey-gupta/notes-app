import CoreGraphics
@testable import Document
import Foundation
import InkModel
import Testing

/// One edit of every kind, valid in sequence starting from `base` (returns the edits and the result).
func everyEditKind(on base: Page, rng: inout SplitMix64) throws -> (edits: [PageEdit], result: Page) {
    var page = base
    var edits: [PageEdit] = []
    func push(_ edit: PageEdit) throws {
        try page.apply(edit)
        edits.append(edit)
    }
    try push(page.addEdit(Fixtures.strokes(&rng, count: 3, samples: 12)))
    try push(page.recolorEdit([page.strokes[0].id, page.strokes[2].id], to: .custom(RGBA8(rgba: 0x1122_33FF))))
    try push(page.transformEdit([page.strokes[1].id], by: CGAffineTransform(a: 0.5, b: 0.25, c: -0.25, d: 0.5, tx: 7, ty: -3)))
    try push(page.replaceEdit([page.strokes[1].id: Fixtures.strokes(&rng, count: 2, samples: 4)]))
    try push(page.removeEdit([page.strokes[0].id]))
    try push(page.replaceEdit([page.strokes[0].id: []]))
    return (edits, page)
}

private func journalBytes(_ edits: [PageEdit], base: Page, identity: StrokesIdentity = .absent) throws -> (Data, [Int]) {
    var data = Data(Journal.encodeHeader(Journal.Header(baseRev: base.rev, base: identity)))
    var ends: [Int] = []
    var rev = base.rev
    for edit in edits {
        rev += 1
        try data.append(contentsOf: Journal.encodeRecord(rev: rev, edit: edit))
        ends.append(data.count)
    }
    return (data, ends)
}

struct JournalTests {
    @Test func everyEditKindRoundTrips() throws {
        var rng = SplitMix64(seed: 1)
        let base = Page(strokes: Fixtures.strokes(&rng, count: 4, samples: 8), rev: 7)
        let (edits, result) = try everyEditKind(on: base, rng: &rng)
        let (data, ends) = try journalBytes(edits, base: base)
        let scan = try Journal.scan(data)
        #expect(scan.header == Journal.Header(baseRev: 7, base: .absent))
        #expect(scan.records.map(\.edit) == edits)
        #expect(scan.records.map(\.rev) == Array(8 ... 13))
        #expect(scan.recordEnds == ends)
        #expect(scan.validLength == data.count)
        #expect(scan.damage == nil)

        let recovery = try Journal.recover(base, identity: .absent, journal: data)
        #expect(recovery.page == result)
        #expect(recovery.page.rev == 13)
        #expect(recovery.replayed == edits.count)
        #expect(recovery.disposition == .keep(length: data.count))
    }

    @Test func tornTailAtEveryOffsetKeepsPrefix() throws {
        var rng = SplitMix64(seed: 2)
        let base = Page(strokes: Fixtures.strokes(&rng, count: 4, samples: 8))
        let (edits, _) = try everyEditKind(on: base, rng: &rng)
        let (data, ends) = try journalBytes(edits, base: base)
        let starts = [Journal.headerLength] + ends.dropLast()
        for cut in 0 ..< data.count {
            let scan = try Journal.scan(data.prefix(cut))
            if cut < Journal.headerLength {
                #expect(scan.header == nil && scan.records.isEmpty && scan.validLength == 0)
                #expect(scan.damage?.kind == (cut == 0 ? nil : .tornHeader))
                continue
            }
            let whole = ends.count { $0 <= cut }
            #expect(scan.records.map(\.edit) == Array(edits.prefix(whole)), "cut \(cut)")
            #expect(scan.validLength == (whole == 0 ? Journal.headerLength : ends[whole - 1]))
            #expect(scan.damage == (starts.contains(cut) ? nil : Journal.Damage(kind: .tornRecord, offset: starts[whole])))
        }
    }

    @Test func flippedByteAnywhereKeepsRecordsBeforeIt() throws {
        var rng = SplitMix64(seed: 3)
        let base = Page(strokes: Fixtures.strokes(&rng, count: 4, samples: 8))
        let (edits, _) = try everyEditKind(on: base, rng: &rng)
        let (data, ends) = try journalBytes(edits, base: base)
        for offset in stride(from: 0, to: data.count, by: 3) {
            var damaged = data
            damaged[offset] ^= 0x5A
            let scan = try Journal.scan(damaged)
            if offset < Journal.headerLength {
                // A flipped version byte with a valid CRC is impossible; the header CRC catches it first.
                #expect(scan.header == nil && scan.damage?.kind == .corruptHeader)
                continue
            }
            let intact = ends.count { $0 <= offset }
            #expect(scan.records.map(\.edit) == Array(edits.prefix(intact)), "offset \(offset)")
            #expect(scan.damage != nil)
        }
    }

    @Test func garbageNeverTraps() throws {
        var rng = SplitMix64(seed: 4)
        let header = Journal.encodeHeader(Journal.Header(baseRev: 0, base: .absent))
        for _ in 0 ..< 2000 {
            let count = Int.random(in: 0 ... 300, using: &rng)
            var bytes = header + (0 ..< count).map { _ in UInt8.random(in: 0 ... 255, using: &rng) }
            // Some with plausible lengths and correct checksums, so the payload decoder is exercised.
            if count >= 9, Bool.random(using: &rng) {
                let payload = Array(bytes[(Journal.headerLength + 8)...])
                var crc = withUnsafeBytes(of: UInt32(payload.count).littleEndian) { CRC32.update(CRC32.initial, $0) }
                crc = payload.withUnsafeBytes { CRC32.update(crc, $0) }
                bytes.replaceSubrange(Journal.headerLength ..< Journal.headerLength + 8, with: withUnsafeBytes(
                    of: (UInt32(payload.count).littleEndian, CRC32.finalize(crc).littleEndian)
                ) { Array($0) })
            }
            let scan = try Journal.scan(Data(bytes))
            #expect(scan.validLength >= Journal.headerLength)
        }
    }

    @Test func newerJournalIsRefusedNotDiscarded() throws {
        var header = Journal.encodeHeader(Journal.Header(baseRev: 0, base: .absent))
        header[4] = 99
        let crc = header.prefix(28).withUnsafeBytes { CRC32.checksum($0) }
        header.replaceSubrange(28 ..< 32, with: withUnsafeBytes(of: crc.littleEndian) { Array($0) })
        #expect(throws: DocumentError.unsupportedFormatVersion(found: 99, supported: 2)) {
            try Journal.scan(Data(header))
        }
    }

    @Test func staleJournalIsDiscardedWithLatestRev() throws {
        var rng = SplitMix64(seed: 5)
        let base = Page(strokes: Fixtures.strokes(&rng, count: 4, samples: 8), rev: 3)
        let (edits, result) = try everyEditKind(on: base, rng: &rng)
        let (data, _) = try journalBytes(edits, base: base, identity: StrokesIdentity(length: 100, crc: 42))
        // Stroke file already holds the result (checkpoint renamed it) but the manifest still says rev 3.
        let checkpointed = Page(id: result.id, template: result.template, strokes: result.strokes, rev: 3)
        let recovery = try Journal.recover(checkpointed, identity: StrokesIdentity(length: 200, crc: 43), journal: data)
        #expect(recovery.stale)
        #expect(recovery.disposition == .discard)
        #expect(recovery.page == result, "edits not applied twice; rev adopted from the journal")
        #expect(recovery.isDirty)
    }

    @Test func inapplicableRecordStopsReplay() throws {
        var rng = SplitMix64(seed: 6)
        let base = Page(strokes: Fixtures.strokes(&rng, count: 2, samples: 4))
        let good = base.addEdit(Fixtures.strokes(&rng, count: 1, samples: 4))
        let bad = PageEdit.remove([PlacedStroke(index: 0, stroke: Fixtures.stroke(&rng, samples: 2))])
        let (data, ends) = try journalBytes([good, bad, good], base: base)
        let recovery = try Journal.recover(base, identity: .absent, journal: data)
        #expect(recovery.replayed == 1)
        #expect(recovery.disposition == .keep(length: ends[0]))
        #expect(recovery.damage == Journal.Damage(kind: .invalidRecord, offset: ends[0]))
        #expect(try recovery.page == base.applying(good))
    }
}
