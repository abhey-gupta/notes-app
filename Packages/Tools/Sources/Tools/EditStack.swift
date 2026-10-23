import InkModel
import Observation

/// One applied edit and the page it was applied to.
public struct EditStep: Hashable, Sendable {
    /// Page the edit belongs to.
    public var pageID: PageID
    /// The edit, as applied to that page.
    public var edit: PageEdit

    /// Creates a step.
    public init(pageID: PageID, edit: PageEdit) {
        self.pageID = pageID
        self.edit = edit
    }

    /// The step that undoes this one.
    public func inverse() -> EditStep {
        EditStep(pageID: pageID, edit: edit.inverse())
    }
}

/// One undo level: the steps of a single user action (a stroke, an eraser gesture, a lasso drag), in
/// the order they were applied. Usually one step; a coalesced gesture may hold several, possibly on
/// several pages.
public struct EditEntry: Hashable, Sendable {
    /// Steps in application order. Apply them in this order.
    public var steps: [EditStep]
    /// Short user-facing name (`"Stroke"`, `"Erase"`), shown by the system undo UI. `nil` = generic.
    public var actionName: String?

    /// Creates an entry.
    public init(steps: [EditStep], actionName: String? = nil) {
        self.steps = steps
        self.actionName = actionName
    }

    /// The entry that undoes this one: each step inverted, in reverse order.
    /// `entry.inverse().inverse() == entry`.
    public func inverse() -> EditEntry {
        EditEntry(steps: steps.reversed().map { $0.inverse() }, actionName: actionName)
    }

    /// Pages the entry touches, in first-touch order (for invalidation and scrolling to the change).
    public var pageIDs: [PageID] {
        var seen = Set<PageID>()
        return steps.map(\.pageID).filter { seen.insert($0).inserted }
    }
}

/// Per-notebook undo/redo history (ARCHITECTURE.md §6): a ring of the last ``capacity`` entries.
///
/// The stack never touches the model. The owner (`DocumentStore`) applies an edit, then ``record(_:on:)``s
/// it; ``undo()`` / ``redo()`` move the cursor and return the entry the owner must apply next. Recording
/// a new entry discards everything redoable. When full, the oldest entry falls off.
///
/// Coalescing: wrap a gesture in ``beginGroup(actionName:)`` / ``endGroup()`` (or ``group(actionName:_:)``)
/// and every edit recorded inside becomes one entry, so undo takes back the whole stroke, eraser gesture or
/// lasso drag in one step. Groups nest; only the outermost one commits. Empty groups commit nothing.
///
/// ``canUndo`` / ``canRedo`` are observable for the toolbar. To hook up ⌘Z and the system three-finger
/// gestures, attach an ``UndoManagerBridge`` and route toolbar buttons through it.
@MainActor
@Observable
public final class EditStack {
    /// Default history depth.
    public static let defaultCapacity = 200

    /// Maximum number of entries kept (undoable + redoable).
    public let capacity: Int

    /// Entries available to ``undo()``.
    public private(set) var undoCount = 0
    /// Entries available to ``redo()``.
    public private(set) var redoCount = 0

    /// Whether ``undo()`` would return an entry (counts an open group with steps in it).
    public var canUndo: Bool {
        undoCount > 0 || hasPendingSteps
    }

    /// Whether ``redo()`` would return an entry.
    public var canRedo: Bool {
        redoCount > 0
    }

    /// Whether a coalescing group is open.
    public var isGrouping: Bool {
        groupDepth > 0
    }

    /// Name of the entry ``undo()`` would return, if any.
    public var undoActionName: String? {
        pending.isEmpty ? (undoCount > 0 ? ring[slot(undoCount - 1)]?.actionName : nil) : pendingName
    }

    /// Name of the entry ``redo()`` would return, if any.
    public var redoActionName: String? {
        redoCount > 0 ? ring[slot(undoCount)]?.actionName : nil
    }

    @ObservationIgnored private var ring: [EditEntry?]
    /// Ring index of the oldest entry.
    @ObservationIgnored private var head = 0
    private var groupDepth = 0
    private var hasPendingSteps = false
    @ObservationIgnored private var pending: [EditStep] = []
    @ObservationIgnored private var pendingName: String?

    /// Called with each committed entry (``UndoManagerBridge`` registration).
    @ObservationIgnored var onCommit: ((EditEntry) -> Void)?
    /// Called after ``removeAll()``.
    @ObservationIgnored var onRemoveAll: (() -> Void)?

    /// Creates an empty stack holding at most `capacity` entries (at least 1).
    public init(capacity: Int = EditStack.defaultCapacity) {
        self.capacity = max(capacity, 1)
        ring = Array(repeating: nil, count: self.capacity)
    }

    // MARK: Recording

    /// Records an edit that has just been applied to `pageID`. Inside a group it joins the group's entry;
    /// otherwise it becomes its own entry. Discards the redo history.
    public func record(_ edit: PageEdit, on pageID: PageID, actionName: String? = nil) {
        if isGrouping {
            if pending.isEmpty {
                discardRedo()
            }
            pending.append(EditStep(pageID: pageID, edit: edit))
            if pendingName == nil {
                pendingName = actionName
            }
            hasPendingSteps = true
        } else {
            commit(EditEntry(steps: [EditStep(pageID: pageID, edit: edit)], actionName: actionName))
        }
    }

    /// Opens a coalescing group: edits recorded until the matching ``endGroup()`` form one entry.
    /// - Parameter actionName: Entry name; an inner group's name is ignored if the outer one has one.
    public func beginGroup(actionName: String? = nil) {
        if groupDepth == 0 {
            pendingName = actionName
        } else if pendingName == nil {
            pendingName = actionName
        }
        groupDepth += 1
    }

    /// Closes the innermost group. Closing the outermost commits its steps as one entry (if any).
    /// Unbalanced calls are ignored.
    public func endGroup() {
        guard groupDepth > 0 else { return }
        groupDepth -= 1
        if groupDepth == 0 {
            flushPending()
        }
    }

    /// Closes every open group, committing the pending steps as one entry (if any).
    public func endAllGroups() {
        closeOpenGroups(notify: true)
    }

    /// Runs `body` inside a group: everything it records becomes one entry.
    public func group<T>(actionName: String? = nil, _ body: () throws -> T) rethrows -> T {
        beginGroup(actionName: actionName)
        defer { endGroup() }
        return try body()
    }

    // MARK: Undo / redo

    /// Steps back one entry and returns its inverse, which the caller must apply (steps in order).
    /// An open group is closed first, so undo mid-gesture takes back the gesture so far.
    /// - Returns: `nil` if there is nothing to undo.
    public func undo() -> EditEntry? {
        closeOpenGroups()
        guard undoCount > 0, let entry = ring[slot(undoCount - 1)] else { return nil }
        undoCount -= 1
        redoCount += 1
        return entry.inverse()
    }

    /// Steps forward one entry and returns it, which the caller must re-apply (steps in order).
    /// - Returns: `nil` if there is nothing to redo.
    public func redo() -> EditEntry? {
        guard redoCount > 0, let entry = ring[slot(undoCount)] else { return nil }
        undoCount += 1
        redoCount -= 1
        return entry
    }

    /// Forgets all history and any open group (e.g. on notebook close, or after an apply failed and the
    /// history no longer matches the model).
    public func removeAll() {
        ring = Array(repeating: nil, count: capacity)
        head = 0
        undoCount = 0
        redoCount = 0
        groupDepth = 0
        pending = []
        pendingName = nil
        hasPendingSteps = false
        onRemoveAll?()
    }

    // MARK: Private

    private func slot(_ offset: Int) -> Int {
        (head + offset) % capacity
    }

    private func discardRedo() {
        guard redoCount > 0 else { return }
        for offset in undoCount ..< undoCount + redoCount {
            ring[slot(offset)] = nil
        }
        redoCount = 0
    }

    /// `notify: false` skips ``onCommit`` (the bridge calls this from inside `UndoManager.undo()`, where a
    /// registration would land on the redo stack).
    func closeOpenGroups(notify: Bool = true) {
        guard groupDepth > 0 else { return }
        groupDepth = 0
        flushPending(notify: notify)
    }

    private func flushPending(notify: Bool = true) {
        let steps = pending
        let name = pendingName
        pending = []
        pendingName = nil
        hasPendingSteps = false
        if !steps.isEmpty {
            commit(EditEntry(steps: steps, actionName: name), notify: notify)
        }
    }

    private func commit(_ entry: EditEntry, notify: Bool = true) {
        discardRedo()
        if undoCount == capacity {
            // Full: overwrite the oldest.
            ring[head] = nil
            head = (head + 1) % capacity
            undoCount -= 1
        }
        ring[slot(undoCount)] = entry
        undoCount += 1
        if notify {
            onCommit?(entry)
        }
    }
}
