import InkModel
import Testing
@testable import Tools

/// Page order in the history (#32): structure entries invert exactly and interleave with ink entries.
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct PageStructureEditTests {
    @Test func inverseRoundTrips() {
        var rng = SplitMix64(state: 7)
        let id = PageID()
        let strokes = [randomStroke(&rng), randomStroke(&rng)]
        let edits: [PageStructureEdit] = [
            .insert(id, at: 2, template: .cornell, strokes: []),
            .delete(id, at: 0, template: .lined(spacing: 24), strokes: strokes),
            .move(from: 3, to: 1),
        ]
        for edit in edits {
            #expect(edit.inverse().inverse() == edit)
        }
        #expect(edits[0].inverse() == .delete(id, at: 2, template: .cornell, strokes: []))
        #expect(edits[1].inverse() == .insert(id, at: 0, template: .lined(spacing: 24), strokes: strokes))
        #expect(edits[2].inverse() == .move(from: 1, to: 3))
        #expect(edits[2].pageID == nil)
        #expect(edits[0].pageID == id)
    }

    /// Deleting pages 1 and 3 of five: applied highest first so each index is valid, and the inverse
    /// re-inserts lowest first, landing both pages where they were.
    @Test func multiDeleteKeepsIndicesValid() throws {
        var order = (0 ..< 5).map { _ in PageID() }
        let original = order
        let removed = [1, 3].map { PageStructureEdit.Removal(id: order[$0], index: $0, template: .blank, strokes: []) }
        let steps = PageStructureEdit.deleting(removed)
        #expect(steps.map(\.index) == [3, 1])
        for step in steps {
            try apply(step, to: &order)
        }
        #expect(order == [original[0], original[2], original[4]])

        let entry = EditEntry(structure: steps, actionName: "Delete")
        for step in entry.inverse().structure {
            try apply(step, to: &order)
        }
        #expect(order == original)
        #expect(entry.pageIDs == [original[3], original[1]])
    }

    @Test func structureEntriesInterleaveWithInkAndCloseGroups() throws {
        let stack = EditStack()
        let page = PageID()
        var rng = SplitMix64(state: 3)
        stack.beginGroup(actionName: "Erase")
        stack.record(Page().addEdit([randomStroke(&rng)]), on: page)
        stack.record(structure: [.move(from: 0, to: 1)], actionName: "Move")
        #expect(!stack.isGrouping, "a page change ends the gesture")
        #expect(stack.undoCount == 2)

        let undone = try #require(stack.undo())
        #expect(undone.structure == [.move(from: 1, to: 0)])
        #expect(undone.steps.isEmpty)
        #expect(stack.undoActionName == "Erase")
        #expect(stack.redoActionName == "Move")
        let redone = try #require(stack.redo())
        #expect(redone.structure == [.move(from: 0, to: 1)])

        stack.record(structure: [], actionName: "Nothing")
        #expect(stack.undoCount == 2, "empty structure records nothing")
        _ = stack.undo()
        stack.record(structure: [.insert(page, at: 0, template: .blank, strokes: [])])
        #expect(!stack.canRedo, "recording discards the redo history")
    }

    private func apply(_ edit: PageStructureEdit, to order: inout [PageID]) throws {
        switch edit {
        case let .insert(id, index, _, _, _):
            order.insert(id, at: index)
        case let .delete(id, index, _, _, _):
            #expect(order[index] == id)
            order.remove(at: index)
        case let .move(from, to):
            order.insert(order.remove(at: from), at: to)
        }
    }
}

private extension PageStructureEdit {
    var index: Int? {
        switch self {
        case let .insert(_, index, _, _, _), let .delete(_, index, _, _, _): index
        case .move: nil
        }
    }
}
