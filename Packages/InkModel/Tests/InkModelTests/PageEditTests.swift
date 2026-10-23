import CoreGraphics
import Foundation
import InkModel
import Testing

private func randomStroke(_ rng: inout SplitMix64) -> Stroke {
    let count = Int.random(in: 1 ... 12, using: &rng)
    let samples = (0 ..< count).map { i in
        Sample(
            x: Float.random(in: 0 ... 595, using: &rng),
            y: Float.random(in: 0 ... 842, using: &rng),
            force: Float.random(in: 0 ... 1, using: &rng),
            t: Float(i) / 240
        )
    }
    let tool = PenKind.allCases.randomElement(using: &rng) ?? .fountain
    return Stroke(tool: tool, color: .primary, width: Float.random(in: 1 ... 8, using: &rng), samples: samples)
}

private func randomSubset(_ page: Page, _ rng: inout SplitMix64) -> [StrokeID] {
    let ids = page.strokes.map(\.id).filter { _ in Bool.random(using: &rng) }
    return ids.isEmpty ? [page.strokes[0].id] : ids.shuffled(using: &rng)
}

private func randomEdit(_ page: Page, _ rng: inout SplitMix64) throws -> PageEdit {
    if page.strokes.isEmpty {
        return page.addEdit([randomStroke(&rng)])
    }
    switch Int.random(in: 0 ..< 5, using: &rng) {
    case 0:
        return page.addEdit((0 ..< Int.random(in: 1 ... 3, using: &rng)).map { _ in randomStroke(&rng) })
    case 1:
        return try page.removeEdit(randomSubset(page, &rng))
    case 2:
        var replacements: [StrokeID: [Stroke]] = [:]
        for id in randomSubset(page, &rng) {
            replacements[id] = (0 ..< Int.random(in: 0 ... 3, using: &rng)).map { _ in randomStroke(&rng) }
        }
        return try page.replaceEdit(replacements)
    case 3:
        let t = CGAffineTransform(translationX: .random(in: -50 ... 50, using: &rng), y: .random(in: -50 ... 50, using: &rng))
            .scaledBy(x: .random(in: 0.5 ... 2, using: &rng), y: .random(in: 0.5 ... 2, using: &rng))
            .rotated(by: .random(in: -1 ... 1, using: &rng))
        return try page.transformEdit(randomSubset(page, &rng), by: t)
    default:
        let color = InkColor.custom(RGBA8(rgba: UInt32.random(in: 0 ... .max, using: &rng)))
        return try page.recolorEdit(randomSubset(page, &rng), to: color)
    }
}

/// Equal up to Float rounding introduced by transform round trips.
private func approximatelyEqual(_ a: Page, _ b: Page) -> Bool {
    guard a.strokes.count == b.strokes.count else { return false }
    return zip(a.strokes, b.strokes).allSatisfy { s, t in
        s.id == t.id && s.tool == t.tool && s.color == t.color && abs(s.width - t.width) <= 1e-3 * s.width
            && s.samples.count == t.samples.count
            && zip(s.samples, t.samples).allSatisfy { abs($0.x - $1.x) < 1e-2 && abs($0.y - $1.y) < 1e-2 && $0.force == $1.force }
    }
}

struct PageEditTests {
    @Test(arguments: 0 ..< 300)
    func inverseRoundTrips(seed: UInt64) throws {
        var rng = SplitMix64(state: seed)
        var page = Page()
        for _ in 0 ..< Int.random(in: 0 ... 6, using: &rng) {
            try page.apply(page.addEdit([randomStroke(&rng)]))
        }
        let edit = try randomEdit(page, &rng)
        #expect(edit.inverse().inverse() == edit)
        #expect(try roundTrip(edit) == edit)

        let edited = try page.applying(edit)
        #expect(edited.rev == page.rev + 1)
        let restored = try edited.applying(edit.inverse())
        #expect(restored.rev == page.rev + 2)
        if case .transform = edit {
            #expect(approximatelyEqual(restored, page))
        } else {
            #expect(restored.strokes == page.strokes)
        }
    }

    @Test(arguments: 0 ..< 20)
    func undoingAChainRestoresThePage(seed: UInt64) throws {
        var rng = SplitMix64(state: seed &+ 1000)
        let original = Page(template: .lined(spacing: 24), strokes: (0 ..< 5).map { _ in randomStroke(&rng) })
        var page = original
        var history: [PageEdit] = []
        for _ in 0 ..< 25 {
            let edit = try randomEdit(page, &rng)
            try page.apply(edit)
            history.append(edit)
        }
        for edit in history.reversed() {
            try page.apply(edit.inverse())
        }
        #expect(approximatelyEqual(page, original))
        #expect(page.rev == 50)
    }

    @Test func replaceKeepsZOrderAndReportsDirtyRect() throws {
        var rng = SplitMix64(state: 7)
        let strokes = (0 ..< 4).map { _ in randomStroke(&rng) }
        var page = Page(strokes: strokes)
        let pieces = [randomStroke(&rng), randomStroke(&rng)]
        let edit = try page.replaceEdit([strokes[1].id: pieces, strokes[3].id: []])
        let dirty = try page.apply(edit)
        #expect(page.strokes.map(\.id) == [strokes[0].id, pieces[0].id, pieces[1].id, strokes[2].id])
        #expect(dirty == strokes[1].bounds.union(strokes[3].bounds).union(pieces[0].bounds).union(pieces[1].bounds))
        #expect(Set(edit.strokeIDs) == Set([strokes[1].id, strokes[3].id, pieces[0].id, pieces[1].id]))
        #expect(page.index(of: pieces[1].id) == 2)
        #expect(page.index(of: strokes[1].id) == nil)
    }

    @Test func recolorRecordsPriorColors() throws {
        var rng = SplitMix64(state: 9)
        var page = Page(strokes: [randomStroke(&rng), randomStroke(&rng).recolored(.semantic(.red))])
        let ids = page.strokes.map(\.id)
        let edit = try page.recolorEdit(ids, to: .semantic(.blue))
        #expect(edit == .recolor([
            ColorChange(id: ids[0], from: .primary, to: .semantic(.blue)),
            ColorChange(id: ids[1], from: .semantic(.red), to: .semantic(.blue)),
        ]))
        try page.apply(edit)
        #expect(page.strokes.allSatisfy { $0.color == .semantic(.blue) })
        #expect(edit.strokeIDs == ids)
    }

    @Test func invalidEditsThrowAndLeavePageUnchanged() throws {
        var rng = SplitMix64(state: 11)
        let a = randomStroke(&rng)
        let b = randomStroke(&rng)
        let stranger = randomStroke(&rng)
        let page = Page(strokes: [a, b])

        #expect(throws: PageEditError.unknownStroke(stranger.id)) { try page.removeEdit([stranger.id]) }
        #expect(throws: PageEditError.duplicateStroke(a.id)) { try page.recolorEdit([a.id, a.id], to: .primary) }
        #expect(throws: PageEditError.unknownStroke(stranger.id)) { try page.replaceEdit([stranger.id: []]) }
        #expect(throws: PageEditError.nonInvertibleTransform) {
            try page.transformEdit([a.id], by: CGAffineTransform(scaleX: 0, y: 1))
        }

        let failing: [(PageEdit, PageEditError)] = [
            (.add([PlacedStroke(index: 0, stroke: a)]), .duplicateStroke(a.id)),
            (.add([PlacedStroke(index: 5, stroke: stranger)]), .indexOutOfRange(5)),
            (.remove([PlacedStroke(index: 0, stroke: b)]), .indexMismatch(index: 0, expected: b.id)),
            (.remove([PlacedStroke(index: 2, stroke: b)]), .indexOutOfRange(2)),
            (.remove([PlacedStroke(index: 1, stroke: b), PlacedStroke(index: 0, stroke: a)]), .unsortedIndices),
            // Valid removal followed by an invalid insert: must not half-apply.
            (.replace(old: [PlacedStroke(index: 0, stroke: a)], new: [PlacedStroke(index: 0, stroke: b)]), .duplicateStroke(b.id)),
            (.transform([stranger.id], forward: .identity, backward: .identity), .unknownStroke(stranger.id)),
            (.recolor([ColorChange(id: stranger.id, from: .primary, to: .primary)]), .unknownStroke(stranger.id)),
        ]
        for (edit, error) in failing {
            var copy = page
            #expect(throws: error) { try copy.apply(edit) }
            #expect(copy == page)
        }
    }
}
