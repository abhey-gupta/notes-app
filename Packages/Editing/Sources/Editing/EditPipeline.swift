import Document
import Foundation
import InkModel
import os
import Tools

/// What the pipeline keeps in step with the store: the main-actor copy of the loaded pages that the
/// screen draws from (ARCHITECTURE.md §5.4). `PageResidency` is the app's adapter; tests use an
/// in-memory one.
@MainActor
public protocol PageMirror: AnyObject {
    /// Pages in order.
    var pageIDs: [PageID] { get }
    /// The page, if loaded.
    func page(_ id: PageID) -> Page?
    /// Loads `id` now and keeps it, so the mirror can follow edits to it.
    func ensureLoaded(_ id: PageID) async throws(DocumentError) -> Page
    /// The store accepted `edit` on `page`: follow it (and show it).
    func didApply(_ edit: PageEdit, to page: PageID)
    /// The store refused an edit to `page`: drop what was drawn and re-read it.
    func reload(_ page: PageID) async
    /// The store's page order changed (insert, delete, move): follow the manifest.
    func pagesDidChange() async
}

/// The one path every change to an open notebook takes (ARCHITECTURE.md §4.4, §6).
///
/// ```
/// stroke / erase / selection edit / page insert·delete·move / undo / redo / run
///   ─▶ one serial queue ─▶ DocumentStore (journaled) ─▶ PageMirror (+ engine echo) ─▶ EditStack
/// ```
///
/// Everything runs one at a time in call order, so each change sees the state the store has, and an undo
/// always takes back the last change actually made, even one tapped while a stroke was still being
/// saved. Eraser gestures (``beginGesture(erasing:)`` … ``endGesture()``) become one undo step however
/// long the scrub. A change the store refuses is dropped and its page re-read; a history entry that no
/// longer applies clears the history.
@MainActor
public final class EditPipeline {
    /// The notebook's store.
    public let store: DocumentStore
    /// The notebook's undo history.
    public let history: EditStack
    /// A page changed (thumbnails).
    public var onPageEdited: (PageID) -> Void = { _ in }
    /// An undo or redo is about to change the document (clear transient UI such as a selection).
    public var onHistoryWillApply: () -> Void = {}
    /// An undo or redo changed these pages (reveal them).
    public var onHistoryApplied: ([PageID]) -> Void = { _ in }

    private let mirror: any PageMirror
    private var bridge: UndoManagerBridge?
    private var queue: Task<Void, Never>?
    private var eraser = EraserRun()
    private var pendingHistory: [EditEntry] = []
    private static let log = Logger(subsystem: "com.abhey.notespace", category: "editor")

    /// Starts editing. With an `undoManager`, ⌘Z / ⇧⌘Z and the system undo gestures drive ``history`` too.
    public init(store: DocumentStore, mirror: any PageMirror, history: EditStack = EditStack(), undoManager: UndoManager? = nil) {
        self.store = store
        self.mirror = mirror
        self.history = history
        if let undoManager {
            bridge = UndoManagerBridge(
                stack: history,
                undoManager: undoManager,
                schedule: { [weak self] work in self?.runHistory(work) },
                apply: { [weak self] entry in self?.pendingHistory.append(entry) }
            )
        }
    }

    // MARK: Ink

    /// Adds a finished stroke to `page` (one undo step).
    public func commitStroke(_ stroke: Stroke, to page: PageID) {
        enqueue("stroke") { [self] in
            let edit = try await mirror.ensureLoaded(page).addEdit([stroke])
            try await commit(edit, to: page)
            history.record(edit, on: page, actionName: "Stroke")
        }
    }

    /// A pen or eraser went down: ends the previous gesture; an eraser gesture opens one "Erase" step.
    public func beginGesture(erasing: Bool) {
        enqueue("gesture") { [self] in
            finishGesture()
            if erasing {
                history.beginGroup(actionName: "Erase")
            }
        }
    }

    /// Erases along `samples` on `page` now; the gesture's batches become one undo step.
    public func erase(_ samples: [Sample], on page: PageID, diameter: Float, mode: EraserSettings.Mode) {
        enqueue("erase") { [self] in
            let current = try await mirror.ensureLoaded(page)
            guard let edit = try eraser.erase(samples, on: page, current: current, diameter: diameter, mode: mode) else { return }
            try await commit(edit, to: page)
            history.record(edit, on: page, actionName: "Erase")
            eraser.accept()
        }
    }

    /// Every touch lifted: the gesture is over.
    public func endGesture() {
        enqueue("gesture end") { [self] in finishGesture() }
    }

    // MARK: Page edits

    /// Reads `page` in order with the edits before it (e.g. to resolve a lasso).
    public func read(_ page: PageID, _ body: @escaping @MainActor (Page) throws -> Void) {
        enqueue("read") { [self] in try await body(mirror.ensureLoaded(page)) }
    }

    /// One edit to `page` as one undo step named `actionName`. `make` builds it from the current page and
    /// a result to hand back (`nil` = nothing to do). `then` always runs: with the result and the edited
    /// page, or `(nil, nil)` if nothing was done or the store refused it.
    public func edit<Result>(
        _ actionName: String,
        on page: PageID,
        make: @escaping @MainActor (Page) throws -> (PageEdit, Result)?,
        then: @escaping @MainActor (Result?, Page?) -> Void = { _, _ in }
    ) {
        enqueue("edit") { [self] in
            var outcome: (Result, Page)?
            defer { then(outcome?.0, outcome?.1) }
            guard let (edit, result) = try await make(mirror.ensureLoaded(page)) else { return }
            try await commit(edit, to: page)
            history.record(edit, on: page, actionName: actionName)
            outcome = mirror.page(page).map { (result, $0) }
        }
    }

    // MARK: Page structure

    /// Inserts an empty page after `index` (`nil` appends) with `template` (`nil`: the notebook's paper);
    /// `then` gets the new page's index.
    public func insertPage(after index: Int?, template: PageTemplate?, then: @escaping @MainActor (Int) -> Void = { _ in }) {
        enqueue("insert page") { [self] in
            let count = mirror.pageIDs.count
            let at = index.map { min($0 + 1, count) } ?? count
            let template = if let template {
                template
            } else {
                await store.manifest.notebook.paper.defaultTemplate
            }
            let id = try await store.insertPage(at: at, template: template)
            await mirror.pagesDidChange()
            history.record(structure: [.insert(id, at: at, template: template, strokes: [])], actionName: "Add Page")
            then(at)
        }
    }

    /// Deletes `ids` as one undo step (undo brings their ink back). Never deletes every page.
    public func deletePages(_ ids: [PageID]) {
        enqueue("delete pages") { [self] in
            let wanted = Set(ids)
            var pages: [PageStructureEdit.Removal] = []
            for (index, id) in mirror.pageIDs.enumerated() where wanted.contains(id) {
                let page = try await store.page(id)
                pages.append(.init(id: id, index: index, template: page.template, strokes: page.strokes))
            }
            guard !pages.isEmpty, pages.count < mirror.pageIDs.count else { return }
            let edits = PageStructureEdit.deleting(pages)
            try await applyStructure(edits)
            history.record(structure: edits, actionName: pages.count == 1 ? "Delete Page" : "Delete Pages")
        }
    }

    /// Moves the page at `source` to `destination` (one undo step).
    public func movePage(from source: Int, to destination: Int) {
        guard source != destination else { return }
        enqueue("move page") { [self] in
            let range = mirror.pageIDs.indices
            guard range.contains(source), range.contains(destination) else { return }
            let edit = PageStructureEdit.move(from: source, to: destination)
            try await applyStructure([edit])
            history.record(structure: [edit], actionName: "Move Page")
        }
    }

    // MARK: History

    /// Undoes the last change, after every change already asked for.
    public func undo() {
        if let bridge {
            bridge.undo()
        } else {
            runHistory { [self] in
                history.endAllGroups()
                if let entry = history.undo() {
                    pendingHistory.append(entry)
                }
            }
        }
    }

    /// Redoes the last undone change, after every change already asked for.
    public func redo() {
        if let bridge {
            bridge.redo()
        } else {
            runHistory { [self] in
                if let entry = history.redo() {
                    pendingHistory.append(entry)
                }
            }
        }
    }

    // MARK: Other changes

    /// Runs a store change that isn't undoable (paper, metadata, flush) in order with the edits.
    public func run(_ name: StaticString, _ operation: @escaping @MainActor () async throws -> Void) {
        enqueue(name, operation)
    }

    /// Waits for every change asked for so far.
    public func drain() async {
        await queue?.value
    }

    /// The editor is going away: forget the history (and the undo manager's actions). Changes already
    /// asked for still run; ``drain()`` waits for them.
    public func close() {
        bridge?.detach()
        bridge = nil
        history.removeAll()
    }

    // MARK: Private

    /// Runs `operation` after every earlier one, logging (and recovering from) failures.
    private func enqueue(_ name: StaticString, _ operation: @escaping @MainActor () async throws -> Void) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            do {
                try await operation()
            } catch {
                Self.log.error("\(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Moves the history in order with the edits (`move` collects entries), then applies what it gave.
    private func runHistory(_ move: @escaping @MainActor () -> Void) {
        enqueue("history") { [self] in
            move()
            let entries = pendingHistory
            pendingHistory = []
            for entry in entries {
                try await applyHistory(entry)
            }
        }
    }

    private func applyHistory(_ entry: EditEntry) async throws {
        onHistoryWillApply()
        eraser.reset() // the page may change under an eraser gesture in progress
        do {
            try await applyStructure(entry.structure)
            for step in entry.steps {
                _ = try await mirror.ensureLoaded(step.pageID)
                try await commit(step.edit, to: step.pageID)
            }
        } catch {
            // The history no longer matches the document.
            history.removeAll()
            throw error
        }
        onHistoryApplied(entry.pageIDs)
    }

    /// Store first, then mirror (and through it the engine); re-reads the page if the store refused.
    private func commit(_ edit: PageEdit, to page: PageID) async throws {
        do {
            try await store.apply(edit, to: page)
        } catch {
            await mirror.reload(page)
            throw error
        }
        mirror.didApply(edit, to: page)
        onPageEdited(page)
    }

    /// Structure edits (one entry's worth) to the store, the mirror follows once, then restored pages get
    /// their ink back.
    private func applyStructure(_ edits: [PageStructureEdit]) async throws {
        guard !edits.isEmpty else { return }
        var restored: [(id: PageID, strokes: [Stroke])] = []
        for edit in edits {
            switch edit {
            case let .insert(id, index, template, strokes):
                try await store.insertPage(id: id, at: index, template: template)
                if !strokes.isEmpty {
                    restored.append((id, strokes))
                }
            case let .delete(id, _, _, _):
                try await store.deletePage(id)
            case let .move(from, to):
                try await store.movePage(from: from, to: to)
            }
        }
        await mirror.pagesDidChange()
        for (id, strokes) in restored {
            let page = try await mirror.ensureLoaded(id)
            try await commit(page.addEdit(strokes), to: id)
        }
    }

    private func finishGesture() {
        eraser.finish(in: history)
        history.endAllGroups()
    }
}
