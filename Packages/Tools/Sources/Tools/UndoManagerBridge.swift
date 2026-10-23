import Foundation

/// Mirrors an ``EditStack`` into a window's `UndoManager`, so ⌘Z / ⇧⌘Z and the system three-finger
/// swipe/tap undo and redo the notebook (ARCHITECTURE.md §6).
///
/// The stack stays the source of truth. Each committed entry registers one undo action; when the system
/// (or ``undo()`` / ``redo()``) invokes it, the bridge moves the stack and hands the resulting entry to
/// `apply`, which forwards it to the document store. Route toolbar buttons through the bridge, not the
/// stack, so both histories move together; enable them from ``EditStack/canUndo`` / ``EditStack/canRedo``.
///
/// Keep one bridge per editor window and ``detach()`` it when the editor goes away.
@MainActor
public final class UndoManagerBridge {
    /// The bridged stack.
    public let stack: EditStack
    /// The bridged undo manager (`nil` after ``detach()``).
    public private(set) weak var undoManager: UndoManager?
    private let apply: @MainActor (EditEntry) -> Void

    /// Connects `stack` to `undoManager`. Only entries committed after this call are registered.
    /// - Parameters:
    ///   - apply: Applies an entry returned by the stack (undo inverse or redo) to the model.
    ///     Called synchronously from inside the undo manager's undo/redo.
    public init(stack: EditStack, undoManager: UndoManager, apply: @escaping @MainActor (EditEntry) -> Void) {
        self.stack = stack
        self.undoManager = undoManager
        self.apply = apply
        undoManager.levelsOfUndo = stack.capacity
        stack.onCommit = { [weak self] entry in self?.registerUndo(named: entry.actionName) }
        stack.onRemoveAll = { [weak self] in self?.removeAllActions() }
    }

    /// Undoes through the undo manager (toolbar button). Falls back to the stack alone if the manager has
    /// nothing registered (e.g. after ``detach()``).
    public func undo() {
        stack.endAllGroups()
        if let undoManager, undoManager.canUndo {
            undoManager.undo()
        } else if let entry = stack.undo() {
            apply(entry)
        }
    }

    /// Redoes through the undo manager (toolbar button). Falls back to the stack alone like ``undo()``.
    public func redo() {
        if let undoManager, undoManager.canRedo {
            undoManager.redo()
        } else if let entry = stack.redo() {
            apply(entry)
        }
    }

    /// Unregisters from the undo manager and stops observing the stack. The stack keeps its history.
    public func detach() {
        removeAllActions()
        stack.onCommit = nil
        stack.onRemoveAll = nil
        undoManager = nil
    }

    // MARK: Private

    private func registerUndo(named name: String?) {
        guard let undoManager else { return }
        // Without event grouping (tests, some hosts) each registration needs its own top-level group.
        let wrap = !undoManager.groupsByEvent && undoManager.groupingLevel == 0
        if wrap {
            undoManager.beginUndoGrouping()
        }
        undoManager.registerUndo(withTarget: self) { $0.performUndo() }
        if let name {
            undoManager.setActionName(name)
        }
        if wrap {
            undoManager.endUndoGrouping()
        }
    }

    /// Runs inside `UndoManager.undo()`: registering here records the redo action.
    private func performUndo() {
        // Mid-gesture system undo: take back the open gesture. Its entry was never registered, so the
        // manager ends up one level short; the toolbar's ``undo()`` fallback still reaches it.
        stack.closeOpenGroups(notify: false)
        let name = stack.undoActionName
        guard let entry = stack.undo() else { return }
        undoManager?.registerUndo(withTarget: self) { $0.performRedo() }
        if let name {
            undoManager?.setActionName(name)
        }
        apply(entry)
    }

    /// Runs inside `UndoManager.redo()`: registering here records the undo action again.
    private func performRedo() {
        let name = stack.redoActionName
        guard let entry = stack.redo() else { return }
        undoManager?.registerUndo(withTarget: self) { $0.performUndo() }
        if let name {
            undoManager?.setActionName(name)
        }
        apply(entry)
    }

    private func removeAllActions() {
        undoManager?.removeAllActions(withTarget: self)
    }
}
