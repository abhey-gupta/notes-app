import InkModel
import Observation
import Testing
@testable import Tools

@MainActor
struct EditStackTests {
    @Test(arguments: 0 ..< 50)
    func undoAllRedoAllRestoresOriginalAndFinal(seed: UInt64) throws {
        var rng = SplitMix64(state: seed)
        var model = Model(pageCount: 3)
        let original = model
        let stack = EditStack()
        for _ in 0 ..< Int.random(in: 1 ... 60, using: &rng) {
            let step = try model.randomStep(&rng)
            stack.record(step.edit, on: step.pageID)
        }
        let final = model

        while let entry = stack.undo() {
            try model.apply(entry)
        }
        #expect(model.approximatelyEquals(original))
        #expect(!stack.canUndo && stack.canRedo)

        while let entry = stack.redo() {
            try model.apply(entry)
        }
        #expect(model.approximatelyEquals(final))
        #expect(stack.canUndo && !stack.canRedo)
    }

    /// Random interleaving of edits, undos and redos tracks a reference list of snapshots.
    @Test(arguments: 0 ..< 30)
    func interleavedUndoRedoMatchesSnapshots(seed: UInt64) throws {
        var rng = SplitMix64(state: seed &+ 500)
        var model = Model(pageCount: 2)
        var snapshots = [model]
        var cursor = 0
        let stack = EditStack()
        for _ in 0 ..< 150 {
            switch Int.random(in: 0 ..< 4, using: &rng) {
            case 0:
                if let entry = stack.undo() {
                    try model.apply(entry)
                    cursor -= 1
                }
            case 1:
                if let entry = stack.redo() {
                    try model.apply(entry)
                    cursor += 1
                }
            default:
                let step = try model.randomStep(&rng)
                stack.record(step.edit, on: step.pageID)
                snapshots.removeSubrange(cursor + 1 ..< snapshots.count)
                snapshots.append(model)
                cursor += 1
            }
            #expect(model.approximatelyEquals(snapshots[cursor]))
            #expect(stack.undoCount == cursor)
            #expect(stack.redoCount == snapshots.count - 1 - cursor)
        }
    }

    @Test(arguments: 0 ..< 50)
    func entryInverseIsAnInvolution(seed: UInt64) throws {
        var rng = SplitMix64(state: seed &+ 900)
        var model = Model(pageCount: 2)
        let entry = try EditEntry(steps: (0 ..< 4).map { _ in try model.randomStep(&rng) }, actionName: "Erase")
        #expect(entry.inverse().inverse() == entry)
        #expect(entry.inverse().steps.map(\.pageID) == entry.steps.map(\.pageID).reversed())
        #expect(Set(entry.pageIDs) == Set(entry.steps.map(\.pageID)))
    }

    @Test func undoWorksAcrossPages() throws {
        var model = Model(pageCount: 3)
        let original = model
        let stack = EditStack()
        var rng = SplitMix64(state: 1)
        for id in model.order {
            guard let page = model.pages[id] else { continue }
            let edit = page.addEdit([randomStroke(&rng)])
            try model.apply(EditStep(pageID: id, edit: edit))
            stack.record(edit, on: id)
        }
        let first = try #require(stack.undo())
        #expect(first.pageIDs == [model.order[2]])
        try model.apply(first)
        #expect(model.pages[model.order[2]]?.strokes.isEmpty == true)
        #expect(model.pages[model.order[1]]?.strokes.count == 1)
        while let entry = stack.undo() {
            try model.apply(entry)
        }
        #expect(model.approximatelyEquals(original))
    }

    @Test func ringOverflowDropsOldest() throws {
        var rng = SplitMix64(state: 2)
        var model = Model(pageCount: 1)
        let stack = EditStack()
        #expect(stack.capacity == 200)
        var snapshots = [model]
        for _ in 0 ..< 250 {
            let step = try model.randomStep(&rng)
            stack.record(step.edit, on: step.pageID)
            snapshots.append(model)
        }
        #expect(stack.undoCount == 200)
        var undone = 0
        while let entry = stack.undo() {
            try model.apply(entry)
            undone += 1
        }
        #expect(undone == 200)
        #expect(model.approximatelyEquals(snapshots[50]))
        // Redo after overflow walks the surviving 200 back in order.
        for i in 51 ... 250 {
            try model.apply(#require(stack.redo()))
            #expect(model.approximatelyEquals(snapshots[i]))
        }
        #expect(stack.redo() == nil)
    }

    @Test func ringWrapsRepeatedlyWithSmallCapacity() {
        let stack = EditStack(capacity: 3)
        let page = PageID()
        let edits = (0 ..< 10).map { _ in PageEdit.recolor([ColorChange(id: StrokeID(), from: .primary, to: .semantic(.red))]) }
        for (i, edit) in edits.enumerated() {
            stack.record(edit, on: page)
            if i == 4 {
                _ = stack.undo()
                _ = stack.undo()
            }
        }
        #expect(stack.undoCount == 3 && stack.redoCount == 0)
        #expect(stack.undo()?.steps.first?.edit == edits[9].inverse())
        #expect(stack.undo()?.steps.first?.edit == edits[8].inverse())
        #expect(stack.undo()?.steps.first?.edit == edits[7].inverse())
        #expect(stack.undo() == nil)
        #expect(stack.redo()?.steps.first?.edit == edits[7])
    }

    @Test func newEditInvalidatesRedo() throws {
        var rng = SplitMix64(state: 3)
        var model = Model(pageCount: 1)
        let stack = EditStack()
        for _ in 0 ..< 3 {
            let step = try model.randomStep(&rng)
            stack.record(step.edit, on: step.pageID)
        }
        try model.apply(#require(stack.undo()))
        try model.apply(#require(stack.undo()))
        #expect(stack.redoCount == 2)
        let step = try model.randomStep(&rng)
        stack.record(step.edit, on: step.pageID)
        #expect(!stack.canRedo)
        #expect(stack.redo() == nil)
        #expect(stack.undoCount == 2)
    }

    @Test func groupCoalescesOneGesture() throws {
        var rng = SplitMix64(state: 4)
        var model = Model(pageCount: 2)
        let original = model
        let stack = EditStack()
        stack.beginGroup(actionName: "Erase")
        #expect(stack.isGrouping && !stack.canUndo)
        for _ in 0 ..< 5 {
            let step = try model.randomStep(&rng)
            stack.record(step.edit, on: step.pageID)
        }
        #expect(stack.canUndo && stack.undoCount == 0)
        stack.endGroup()
        #expect(stack.undoCount == 1 && !stack.isGrouping)
        #expect(stack.undoActionName == "Erase")
        let entry = try #require(stack.undo())
        #expect(entry.steps.count == 5)
        try model.apply(entry)
        #expect(model.approximatelyEquals(original))
        #expect(stack.redoActionName == "Erase")
    }

    @Test func nestedAndEmptyGroups() {
        let stack = EditStack()
        let page = PageID()
        let edit = PageEdit.recolor([])
        stack.group(actionName: "Outer") {
            stack.record(edit, on: page)
            stack.group(actionName: "Inner") {
                stack.record(edit, on: page)
            }
            #expect(stack.undoCount == 0)
        }
        #expect(stack.undoCount == 1)
        #expect(stack.undoActionName == "Outer")

        stack.group {}
        stack.endGroup() // unbalanced: ignored
        #expect(stack.undoCount == 1)
    }

    @Test func undoMidGestureCommitsAndUndoesTheGestureSoFar() throws {
        var rng = SplitMix64(state: 5)
        var model = Model(pageCount: 1)
        let stack = EditStack()
        let first = try model.randomStep(&rng)
        stack.record(first.edit, on: first.pageID)
        let afterFirst = model
        stack.beginGroup()
        for _ in 0 ..< 3 {
            let step = try model.randomStep(&rng)
            stack.record(step.edit, on: step.pageID)
        }
        let entry = try #require(stack.undo())
        #expect(entry.steps.count == 3)
        try model.apply(entry)
        #expect(model.approximatelyEquals(afterFirst))
        #expect(!stack.isGrouping && stack.undoCount == 1 && stack.redoCount == 1)
    }

    @Test func removeAllClearsHistory() {
        let stack = EditStack()
        stack.record(.recolor([]), on: PageID())
        stack.beginGroup()
        stack.record(.recolor([]), on: PageID())
        stack.removeAll()
        #expect(!stack.canUndo && !stack.canRedo && !stack.isGrouping)
        #expect(stack.undo() == nil)
    }

    @Test func canUndoAndCanRedoAreObservable() {
        let stack = EditStack()
        let changes = Counter()
        func observe() {
            withObservationTracking {
                _ = stack.canUndo
                _ = stack.canRedo
            } onChange: {
                changes.increment()
            }
        }
        observe()
        stack.record(.recolor([]), on: PageID())
        #expect(changes.value == 1)
        observe()
        _ = stack.undo()
        #expect(changes.value == 2)
        observe()
        stack.beginGroup()
        stack.record(.recolor([]), on: PageID())
        #expect(changes.value == 3) // a pending gesture enables undo before the group ends
    }
}

/// Sendable counter for `onChange` (which is `@Sendable`). Unchecked: only touched synchronously on the
/// main actor by these tests.
private final class Counter: @unchecked Sendable {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
