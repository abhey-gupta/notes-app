import Foundation
import InkModel
import Testing
@testable import Tools

@MainActor
struct UndoManagerBridgeTests {
    /// Stack + bridge + model, with an undo manager configured like a test host (no run-loop grouping).
    @MainActor
    final class Harness {
        let stack = EditStack()
        let undoManager = UndoManager()
        var model = Model(pageCount: 2)
        var applied: [EditEntry] = []
        var bridge: UndoManagerBridge?
        var rng = SplitMix64(state: 42)

        init() {
            undoManager.groupsByEvent = false
            bridge = UndoManagerBridge(stack: stack, undoManager: undoManager) { [weak self] entry in
                self?.applied.append(entry)
                try? self?.model.apply(entry)
            }
        }

        func edit(named name: String? = nil) throws {
            let step = try model.randomStep(&rng)
            stack.record(step.edit, on: step.pageID, actionName: name)
        }
    }

    @Test func registersOneActionPerEntry() throws {
        let h = Harness()
        #expect(!h.undoManager.canUndo)
        try h.edit(named: "Stroke")
        #expect(h.undoManager.canUndo)
        #expect(h.undoManager.undoActionName == "Stroke")
        #expect(h.undoManager.levelsOfUndo == h.stack.capacity)

        h.stack.beginGroup(actionName: "Erase")
        try h.edit()
        try h.edit()
        h.stack.endGroup()
        #expect(h.undoManager.undoActionName == "Erase")
        h.undoManager.undo()
        #expect(h.applied.count == 1 && h.applied[0].steps.count == 2)
        #expect(h.undoManager.undoActionName == "Stroke")
        #expect(h.undoManager.redoActionName == "Erase")
    }

    @Test func systemUndoRedoDrivesTheStack() throws {
        let h = Harness()
        let original = h.model
        for _ in 0 ..< 5 {
            try h.edit()
        }
        let final = h.model
        while h.undoManager.canUndo {
            h.undoManager.undo()
        }
        #expect(h.applied.count == 5)
        #expect(h.model.approximatelyEquals(original))
        #expect(!h.stack.canUndo && h.stack.redoCount == 5)

        while h.undoManager.canRedo {
            h.undoManager.redo()
        }
        #expect(h.model.approximatelyEquals(final))
        #expect(h.stack.undoCount == 5 && !h.stack.canRedo)
        #expect(h.undoManager.canUndo && !h.undoManager.canRedo)
    }

    @Test func toolbarButtonsGoThroughTheManager() throws {
        let h = Harness()
        try h.edit()
        try h.edit()
        h.bridge?.undo()
        #expect(h.stack.undoCount == 1 && h.undoManager.canRedo)
        h.bridge?.redo()
        #expect(h.stack.undoCount == 2 && !h.undoManager.canRedo)
        // A new edit after undo clears redo in both histories.
        h.bridge?.undo()
        try h.edit()
        #expect(!h.stack.canRedo && !h.undoManager.canRedo)
    }

    @Test func toolbarUndoMidGestureTakesBackTheGesture() throws {
        let h = Harness()
        try h.edit()
        h.stack.beginGroup()
        try h.edit()
        try h.edit()
        h.bridge?.undo()
        #expect(h.applied.last?.steps.count == 2)
        #expect(h.stack.undoCount == 1 && h.stack.redoCount == 1)
        #expect(h.undoManager.canUndo && h.undoManager.canRedo)
    }

    @Test func removeAllAndDetachUnregister() throws {
        let h = Harness()
        try h.edit()
        h.stack.removeAll()
        #expect(!h.undoManager.canUndo)

        try h.edit()
        h.bridge?.detach()
        #expect(!h.undoManager.canUndo)
        try h.edit()
        #expect(!h.undoManager.canUndo)
        // Detached toolbar undo still works through the stack.
        h.bridge?.undo()
        #expect(h.stack.undoCount == 1 && h.applied.count == 1)
    }
}
