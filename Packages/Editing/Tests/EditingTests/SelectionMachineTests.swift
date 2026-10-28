import CoreGraphics
@testable import Editing
import InkModel
import Testing
import Tools

/// Records what the machine shows: the outline and the lifted ink, as the screen would have them.
@MainActor
final class RecordingDisplay: SelectionDisplay {
    private(set) var shown: LassoSelection?
    private(set) var shows: [LassoSelection?] = []
    private(set) var lifted: (strokes: [StrokeID], transform: CGAffineTransform)?
    private(set) var lifts = 0

    func showSelection(_ selection: LassoSelection?) {
        shown = selection
        shows.append(selection)
    }

    func liftSelection(_ selection: LassoSelection?, transform: CGAffineTransform) {
        lifted = selection.map { ($0.strokeIDs, transform) }
        lifts += 1
    }
}

/// Two strokes on the first page and a machine over a real pipeline.
@MainActor
final class SelectionHarness {
    let h: Harness
    let display = RecordingDisplay()
    let machine: SelectionMachine
    let a = line(y: 100, from: 20, to: 100)
    let b = line(y: 140, from: 20, to: 100)
    /// Lasso around both strokes.
    let loop = [CGPoint(x: 0, y: 80), CGPoint(x: 140, y: 80), CGPoint(x: 140, y: 160), CGPoint(x: 0, y: 160)]

    init() async throws {
        h = try Harness()
        machine = SelectionMachine(edits: h.pipeline, display: display)
        h.pipeline.commitStroke(a, to: h.first)
        h.pipeline.commitStroke(b, to: h.first)
        await h.pipeline.drain()
    }

    func select() async {
        machine.lassoClosed(loop, on: h.first)
        await h.pipeline.drain()
    }

    func page() async throws -> Page {
        try await h.store.page(h.first)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SelectionMachineTests {
    @Test func lassoSelectsStrokesInside() async throws {
        let s = try await SelectionHarness()
        await s.select()
        #expect(s.machine.selection?.strokeIDs == [s.a.id, s.b.id])
        #expect(s.display.shown == s.machine.selection)
    }

    @Test func lassoAroundNothingSelectsNothing() async throws {
        let s = try await SelectionHarness()
        s.machine.lassoClosed([CGPoint(x: 400, y: 400), CGPoint(x: 500, y: 400), CGPoint(x: 500, y: 500)], on: s.h.first)
        await s.h.pipeline.drain()
        #expect(s.machine.state == .none)
        #expect(s.display.shown == nil)
    }

    /// A lasso still waiting for its page when the user switches tool or starts writing must not pop up
    /// a selection afterwards.
    @Test func clearWhileResolvingDropsTheLateResult() async throws {
        let s = try await SelectionHarness()
        s.machine.lassoClosed(s.loop, on: s.h.first)
        #expect(s.machine.state == .resolving)
        s.machine.clear()
        await s.h.pipeline.drain()
        #expect(s.machine.state == .none)
        #expect(s.display.shows.allSatisfy { $0 == nil })
    }

    @Test func dragMovesInkAsOneUndoStep() async throws {
        let s = try await SelectionHarness()
        await s.select()
        let move = CGAffineTransform(translationX: 50, y: 30)
        #expect(s.machine.beginDrag(from: nil))
        #expect(s.display.lifted?.transform == .identity)
        s.machine.drag(move)
        #expect(s.display.lifted?.transform == move)
        s.machine.endDrag(move)
        // Shown at the drop point, ink still lifted until the edit lands.
        #expect(try s.machine.state == .committing(#require(s.display.shown)))
        #expect(s.display.lifted != nil)
        await s.h.pipeline.drain()
        #expect(s.display.lifted == nil)
        let page = try await s.page()
        #expect(page.strokes.first?.samples.first?.x == 70)
        #expect(s.machine.selection == LassoSelection([s.a.id, s.b.id], on: page))
        #expect(s.h.pipeline.history.undoActionName == "Move")
        s.h.pipeline.undo()
        await s.h.pipeline.drain()
        #expect(try await s.page().strokes.first?.samples.first?.x == 20)
    }

    @Test func dragFromCornerIsResize() async throws {
        let s = try await SelectionHarness()
        await s.select()
        #expect(s.machine.beginDrag(from: .bottomRight))
        s.machine.endDrag(CGAffineTransform(scaleX: 2, y: 2))
        await s.h.pipeline.drain()
        #expect(s.h.pipeline.history.undoActionName == "Resize")
    }

    @Test func dropInPlaceAndCancelPutInkBackWithoutAnEdit() async throws {
        let s = try await SelectionHarness()
        await s.select()
        let selected = s.machine.selection
        #expect(s.machine.beginDrag(from: nil))
        s.machine.endDrag(.identity)
        #expect(s.machine.beginDrag(from: nil))
        s.machine.drag(CGAffineTransform(translationX: 10, y: 0))
        s.machine.cancelDrag()
        await s.h.pipeline.drain()
        #expect(try s.machine.state == .selected(#require(selected)))
        #expect(s.display.lifted == nil)
        #expect(s.h.pipeline.history.undoActionName == "Stroke")
    }

    @Test func noDragWhileSaving() async throws {
        let s = try await SelectionHarness()
        await s.select()
        #expect(s.machine.beginDrag(from: nil))
        s.machine.endDrag(CGAffineTransform(translationX: 5, y: 5))
        #expect(!s.machine.beginDrag(from: nil))
        s.machine.recolor(to: .semantic(.red)) // ignored too
        await s.h.pipeline.drain()
        #expect(s.machine.beginDrag(from: nil))
        #expect(try await s.page().strokes.allSatisfy { $0.color == .primary })
    }

    /// Cleared (e.g. tool change) while a drop is saving: the outline goes now, but the ink stays lifted
    /// at the drop point until the edit lands, and the selection doesn't come back.
    @Test func clearWhileSavingKeepsInkLiftedUntilTheEditLands() async throws {
        let s = try await SelectionHarness()
        await s.select()
        _ = s.machine.beginDrag(from: nil)
        s.machine.endDrag(CGAffineTransform(translationX: 5, y: 5))
        s.machine.clear()
        #expect(s.display.shown == nil)
        #expect(s.display.lifted != nil)
        await s.h.pipeline.drain()
        #expect(s.display.lifted == nil)
        #expect(s.display.shown == nil)
        #expect(s.machine.state == .none)
    }

    /// The drop can't be saved (its strokes went meanwhile): the outline follows the real page, not the
    /// drop point. It used to stay where it was dropped, over nothing.
    @Test func refusedDropFollowsThePage() async throws {
        let s = try await SelectionHarness()
        await s.select()
        _ = s.machine.beginDrag(from: nil)
        s.h.pipeline.edit("Delete", on: s.h.first, make: { page in try ([page.removeEdit([s.a.id])], ()) })
        s.machine.endDrag(CGAffineTransform(translationX: 5, y: 5))
        await s.h.pipeline.drain()
        let page = try await s.page()
        #expect(s.machine.selection == LassoSelection([s.b.id], on: page))
        #expect(s.display.shown == s.machine.selection)
        #expect(s.display.lifted == nil)
    }

    @Test func recolorKeepsTheSelection() async throws {
        let s = try await SelectionHarness()
        await s.select()
        s.machine.recolor(to: .semantic(.red))
        await s.h.pipeline.drain()
        #expect(try await s.page().strokes.allSatisfy { $0.color == .semantic(.red) })
        #expect(s.machine.selection?.strokeIDs == [s.a.id, s.b.id])
        #expect(s.h.pipeline.history.undoActionName == "Recolor")
        // Same color again: nothing to do, still selected.
        s.machine.recolor(to: .semantic(.red))
        await s.h.pipeline.drain()
        #expect(s.machine.selection?.strokeIDs == [s.a.id, s.b.id])
        #expect(s.h.pipeline.history.undoActionName == "Recolor")
    }

    @Test func duplicateSelectsTheCopies() async throws {
        let s = try await SelectionHarness()
        await s.select()
        s.machine.duplicate()
        await s.h.pipeline.drain()
        let page = try await s.page()
        #expect(page.strokes.count == 4)
        #expect(s.machine.selection?.strokeIDs == page.strokes.suffix(2).map(\.id))
    }

    @Test func deleteEndsTheSelection() async throws {
        let s = try await SelectionHarness()
        await s.select()
        s.machine.delete()
        await s.h.pipeline.drain()
        #expect(try await s.page().strokes.isEmpty)
        #expect(s.machine.state == .none)
        #expect(s.display.shown == nil)
    }

    /// A new lasso replaces the old selection; the old action finishing later doesn't bring it back.
    @Test func newLassoWinsOverAnEarlierAction() async throws {
        let s = try await SelectionHarness()
        await s.select()
        s.machine.duplicate()
        s.machine.lassoClosed([CGPoint(x: 0, y: 90), CGPoint(x: 140, y: 90), CGPoint(x: 140, y: 110), CGPoint(x: 0, y: 110)], on: s.h.first)
        await s.h.pipeline.drain()
        #expect(s.machine.selection?.strokeIDs == [s.a.id])
    }
}
