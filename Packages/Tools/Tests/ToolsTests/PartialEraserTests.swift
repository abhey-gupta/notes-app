import CoreGraphics
import Foundation
import InkGeometry
import InkModel
import Testing
@testable import Tools

/// A page of handwriting: rows of word-sized zigzag strokes (~1.5 pt per sample), every fifth one a
/// highlighter, every third one carrying PencilKit point sizes.
func handwritingPage(strokes count: Int, seed: UInt64) -> Page {
    var rng = SplitMix64(state: seed)
    let perRow = 20
    let strokes = (0 ..< count).map { i -> Stroke in
        let origin = CGPoint(x: 20 + CGFloat(i % perRow) * 28, y: 30 + CGFloat(i / perRow) * 40)
        let n = Int.random(in: 20 ... 60, using: &rng)
        let samples = (0 ..< n).map { k in
            let u = Float(k) / Float(n - 1)
            return Sample(
                x: Float(origin.x) + 24 * u,
                y: Float(origin.y) + 10 * sin(u * 9 + Float.random(in: 0 ... 0.3, using: &rng)),
                force: .random(in: 0.2 ... 0.9, using: &rng),
                t: Float(k) / 240
            )
        }
        let tool: PenKind = i % 5 == 0 ? .highlighter : .fountain
        let width: Float = tool == .highlighter ? 16 : 2
        let rendering = i % 3 == 0
            ? StrokeRendering(
                ink: StrokeRendering.Ink.for(tool),
                randomSeed: 1,
                points: samples.map { _ in PointRendering(width: width, height: width / 2) }
            )
            : nil
        return Stroke(tool: tool, color: .primary, width: width, samples: samples, rendering: rendering)
    }
    return Page(strokes: strokes)
}

private func point(_ x: Float, _ y: Float) -> Sample {
    Sample(x: x, y: y, t: 0)
}

/// Horizontal ballpoint line from `x0` to `x1` at `y`, 2 pt apart.
private func line(_ x0: Float, _ x1: Float, y: Float, tool: PenKind = .ballpoint, width: Float = 2) -> Stroke {
    Stroke(
        tool: tool, color: .primary, width: width,
        samples: stride(from: x0, through: x1, by: 2).map { Sample(x: $0, y: y, force: $0 / 1000, t: $0 / 240) }
    )
}

struct PartialEraserTests {
    /// Acceptance (#28): erasing through a stroke yields two strokes with the original samples outside
    /// the disk preserved.
    @Test func eraseThroughYieldsTwoPiecesWithOriginalSamples() throws {
        let stroke = line(0, 200, y: 100)
        let page = Page(strokes: [stroke])
        var eraser = PartialEraser(page: page, diameter: 16)
        // A vertical swipe at x = 100, over two batches.
        #expect(eraser.erase([point(100, 60), point(100, 90)]).isEmpty)
        let batch = eraser.erase([point(100, 100), point(100, 140)])
        let pieces = try #require(batch[stroke.id])
        #expect(pieces.count == 2)
        // Reach: radius 8 + half width 1 = 9 → cut at x = 91 and x = 109.
        #expect(pieces[0].samples.first?.x == 0 && pieces[0].samples.last?.x == 91)
        #expect(pieces[1].samples.first?.x == 109 && pieces[1].samples.last?.x == 200)
        let outside = stroke.samples.filter { abs($0.x - 100) > 9 }
        let kept = pieces.flatMap { $0.samples.filter { s in s.x.truncatingRemainder(dividingBy: 2) == 0 } }
        #expect(kept.map(\.x) == outside.map(\.x) && kept.map(\.force) == outside.map(\.force))
        #expect(pieces.allSatisfy { $0.id != stroke.id && $0.tool == stroke.tool && $0.color == stroke.color })
        #expect(eraser.gestureReplacements == batch)
        #expect(eraser.liveCount == 2)
    }

    /// Later probes cut the pieces again; the gesture maps the original to its final pieces in order and
    /// each batch is keyed by what was on the page before it.
    @Test func recutsPiecesAcrossBatches() throws {
        let stroke = line(0, 300, y: 100)
        var eraser = PartialEraser(page: Page(strokes: [stroke]), diameter: 8)
        let first = eraser.erase([point(100, 80), point(100, 120)])
        let firstPieces = try #require(first[stroke.id])
        #expect(firstPieces.count == 2)
        let second = eraser.erase([point(200, 120), point(200, 80)])
        #expect(second.keys.contains(firstPieces[1].id) && second[firstPieces[1].id]?.count == 2)
        let gesture = try #require(eraser.gestureReplacements[stroke.id])
        #expect(gesture.count == 3)
        #expect(gesture[0] == firstPieces[0])
        #expect(gesture.map { $0.samples.first?.x ?? -1 } == [0, 105, 205])
        // Scrubbing along the whole line erases everything left.
        _ = eraser.erase([point(0, 100), point(300, 100)])
        #expect(eraser.gestureReplacements[stroke.id] == [])
        #expect(eraser.liveCount == 0)
    }

    @Test func emptyPageAndNonFiniteInput() {
        var eraser = PartialEraser(page: Page(), diameter: 16)
        #expect(eraser.erase([point(10, 10), Sample(x: .nan, y: 3, t: 0)]).isEmpty)
        var other = PartialEraser(page: Page(strokes: [line(0, 100, y: 0)]), diameter: 16)
        #expect(other.erase([Sample(x: .infinity, y: 0, t: 0)]).isEmpty)
        #expect(other.gestureReplacements.isEmpty)
    }

    /// Acceptance (#28): highlighter strokes are erasable in both modes.
    @Test(arguments: EraserSettings.Mode.allCases)
    func erasesHighlighter(mode: EraserSettings.Mode) throws {
        let highlight = line(0, 200, y: 100, tool: .highlighter, width: 16)
        let page = Page(strokes: [highlight])
        var gesture = EraserGesture(page: page, diameter: 8, mode: mode)
        // 10 pt off the centerline: inside the 16 pt chisel's half-width plus the eraser radius.
        let edit = try #require(try gesture.erase([point(100, 110)], on: page))
        let after = try page.applying(edit)
        switch mode {
        case .stroke:
            #expect(after.strokes.isEmpty)
        case .partial:
            #expect(after.strokes.count == 2 && after.strokes.allSatisfy { $0.tool == .highlighter })
        }
    }

    /// Acceptance (#28): applying every batch edit in order equals the one gesture edit, and its inverse
    /// (one undo) restores the starting page exactly. Both modes, random scrubs over a real page.
    @Test(arguments: EraserSettings.Mode.allCases, 0 ..< 6)
    func gestureEditEqualsBatchesAndUndoes(mode: EraserSettings.Mode, seed: UInt64) throws {
        var rng = SplitMix64(state: seed &+ 31)
        let start = handwritingPage(strokes: 120, seed: seed)
        var gesture = EraserGesture(page: start, diameter: EraserSettings.widths.randomElement(using: &rng) ?? 16, mode: mode)
        var page = start
        var batches = 0
        var p = CGPoint(x: .random(in: 0 ... 595, using: &rng), y: .random(in: 0 ... 260, using: &rng))
        for _ in 0 ..< 80 {
            let batch = (0 ..< 3).map { _ in
                p.x = min(max(p.x + .random(in: -12 ... 12, using: &rng), 0), 595)
                p.y = min(max(p.y + .random(in: -12 ... 12, using: &rng), 0), 260)
                return Sample(x: Float(p.x), y: Float(p.y), t: 0)
            }
            if let edit = try gesture.erase(batch, on: page) {
                try page.apply(edit)
                batches += 1
            }
        }
        let whole = try #require(try gesture.edit())
        #expect(batches > 0)
        #expect(try start.applying(whole).strokes == page.strokes)
        #expect(try page.applying(whole.inverse()).strokes == start.strokes)
    }

    /// Acceptance (#28): through `EditStack`, one undo takes back the whole gesture (both modes), and
    /// redo puts it back.
    @MainActor
    @Test(arguments: EraserSettings.Mode.allCases)
    func oneUndoRestoresGesture(mode: EraserSettings.Mode) throws {
        let pageID = PageID()
        let start = handwritingPage(strokes: 60, seed: 9)
        var page = start
        let stack = EditStack()
        stack.beginGroup(actionName: "Erase")
        var gesture = EraserGesture(page: page, diameter: 16, mode: mode)
        var recorded = 0
        for x in stride(from: Float(0), through: 595, by: 6) {
            guard let edit = try gesture.erase([point(x, 50 + x / 10)], on: page) else { continue }
            try page.apply(edit)
            stack.record(edit, on: pageID, actionName: "Erase")
            recorded += 1
        }
        let erased = page
        #expect(recorded > 5)
        let whole = try #require(try gesture.edit())
        #expect(stack.coalesceLast(recorded, into: [EditStep(pageID: pageID, edit: whole)]))
        stack.endAllGroups()
        #expect(stack.undoCount == 1 && stack.undoActionName == "Erase")

        let undo = try #require(stack.undo())
        #expect(undo.steps.count == 1)
        for step in undo.steps {
            try page.apply(step.edit)
        }
        #expect(page.strokes == start.strokes)
        #expect(!stack.canUndo)
        let redo = try #require(stack.redo())
        for step in redo.steps {
            try page.apply(step.edit)
        }
        #expect(page.strokes == erased.strokes)
    }

    @MainActor
    @Test func coalesceIsANoOpOutsideAGroup() {
        let stack = EditStack()
        let edit = Page().addEdit([line(0, 10, y: 0)])
        stack.record(edit, on: PageID())
        #expect(!stack.coalesceLast(1, into: []))
        stack.beginGroup()
        #expect(!stack.coalesceLast(1, into: []), "nothing recorded in the group")
        stack.record(edit, on: PageID())
        #expect(stack.coalesceLast(1, into: []))
        stack.endAllGroups()
        #expect(stack.undoCount == 1, "an emptied group commits nothing")
    }
}

/// Budget (#28): eraser hit-testing on a 400-stroke page < 2 ms per touch event. An event is one
/// coalesced batch (2 samples, ~8 pt of travel at ~1000 pt/s), the largest eraser (32 pt).
struct EraserPerformanceTests {
    @Test(arguments: EraserSettings.Mode.allCases)
    func hitTestUnder2msPerEvent(mode: EraserSettings.Mode) throws {
        let page = handwritingPage(strokes: 400, seed: 400)
        #expect(page.strokes.count == 400)
        let clock = ContinuousClock()
        var perEvent: [Duration] = []
        var hits = 0
        for row in 0 ..< 3 {
            var gesture = EraserGesture(page: page, diameter: EraserSettings.widths.last ?? 32, mode: mode)
            var current = page
            let y = Float(35 + row * 160)
            for x in stride(from: Float(10), to: 590, by: 8) {
                let batch = [point(x, y), point(x + 4, y + 3)]
                var edit: PageEdit?
                try perEvent.append(clock.measure { edit = try gesture.erase(batch, on: current) })
                if let edit {
                    try current.apply(edit)
                    hits += 1
                }
            }
        }
        perEvent.sort()
        let median = perEvent[perEvent.count / 2]
        let worst = perEvent[perEvent.count - 1]
        let report = "eraser \(mode) 400 strokes: median \(median), worst \(worst), \(perEvent.count) events\n"
        FileHandle.standardError.write(Data(report.utf8))
        #expect(hits > 20)
        #expect(median < .milliseconds(2), "median \(median)")
        #if !DEBUG
            #expect(worst < .milliseconds(2), "worst \(worst)")
        #endif
    }
}

/// `NotebookSession` stand-in: two pages, a history, and an `EraserRun` driven batch by batch.
@MainActor
private struct Editor {
    let a = PageID()
    let b = PageID()
    let stack = EditStack()
    var run = EraserRun()
    var pages: [PageID: Page]

    init() {
        pages = [a: handwritingPage(strokes: 80, seed: 1), b: handwritingPage(strokes: 80, seed: 2)]
    }

    /// One pass along the row at `y`, a batch every 10 pt: erase, apply, record, accept. With
    /// `accept: false` every edit is dropped instead (as if the store refused it).
    mutating func scrub(_ page: PageID, y: Float, mode: EraserSettings.Mode, accept: Bool = true) throws {
        for x in stride(from: Float(0), through: 595, by: 10) {
            let current = try #require(pages[page])
            guard let edit = try run.erase([point(x, y)], on: page, current: current, diameter: 16, mode: mode), accept else { continue }
            pages[page] = try current.applying(edit)
            stack.record(edit, on: page, actionName: "Erase")
            run.accept()
        }
    }

    mutating func apply(_ entry: EditEntry) throws {
        for step in entry.steps {
            pages[step.pageID] = try pages[step.pageID]?.applying(step.edit)
        }
    }

    func strokes(_ page: PageID) -> [Stroke]? {
        pages[page]?.strokes
    }
}

/// `EraserRun` as `NotebookSession` drives it: apply + record each batch, collapse at gesture end.
@MainActor
struct EraserRunTests {
    /// A gesture over page A, then B, then A again is one undo step of three edits; undo restores both
    /// pages, redo re-erases them.
    @Test(arguments: EraserSettings.Mode.allCases)
    func collapsesMultiPageGestureToOneStepPerVisit(mode: EraserSettings.Mode) throws {
        var editor = Editor()
        let (a, b) = (editor.a, editor.b)
        let start = editor
        editor.stack.beginGroup(actionName: "Erase")
        try editor.scrub(a, y: 35, mode: mode)
        try editor.scrub(b, y: 75, mode: mode)
        try editor.scrub(a, y: 115, mode: mode)
        let erased = editor
        #expect(erased.strokes(a) != start.strokes(a) && erased.strokes(b) != start.strokes(b))
        editor.run.finish(in: editor.stack)
        editor.stack.endAllGroups()
        #expect(editor.stack.undoCount == 1)

        let undo = try #require(editor.stack.undo())
        #expect(undo.steps.map(\.pageID) == [a, b, a])
        try editor.apply(undo)
        #expect(editor.strokes(a) == start.strokes(a) && editor.strokes(b) == start.strokes(b))
        try editor.apply(#require(editor.stack.redo()))
        #expect(editor.strokes(a) == erased.strokes(a) && editor.strokes(b) == erased.strokes(b))
    }

    /// Batches that were never applied don't reach history; later batches build on what was applied.
    @Test(arguments: EraserSettings.Mode.allCases)
    func forgetsUnacceptedBatches(mode: EraserSettings.Mode) throws {
        var editor = Editor()
        let a = editor.a
        let start = editor
        editor.stack.beginGroup(actionName: "Erase")
        try editor.scrub(a, y: 35, mode: mode, accept: false)
        #expect(editor.strokes(a) == start.strokes(a))
        try editor.scrub(a, y: 75, mode: mode)
        editor.run.finish(in: editor.stack)
        editor.stack.endAllGroups()
        let undo = try #require(editor.stack.undo())
        #expect(undo.steps.count == 1)
        try editor.apply(undo)
        #expect(editor.strokes(a) == start.strokes(a))
    }

    /// Undo mid-gesture closes the group with the per-event steps; finishing afterwards changes nothing.
    @Test func undoMidGestureTakesBackWhatIsDone() throws {
        var editor = Editor()
        let a = editor.a
        let start = editor
        editor.stack.beginGroup(actionName: "Erase")
        try editor.scrub(a, y: 35, mode: .partial)
        let undo = try #require(editor.stack.undo())
        #expect(undo.steps.count > 1)
        try editor.apply(undo)
        #expect(editor.strokes(a) == start.strokes(a))
        editor.run.reset()
        editor.run.finish(in: editor.stack)
        editor.stack.endAllGroups()
        #expect(editor.stack.undoCount == 0 && editor.stack.redoCount == 1)
    }
}
