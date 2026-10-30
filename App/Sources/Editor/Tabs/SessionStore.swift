import InkModel
import Library
import Tools
import UIKit

/// The editor's open ``NotebookSession``s, one per tab that has been shown (#191). Switching tabs keeps the
/// previous session alive (flushed), so switching back costs nothing; leaving the editor closes them all,
/// so the library is the package's only writer while it's on screen (rename, duplicate, delete).
///
/// Split view (#175): each pane shows a session (``session(for:in:)``). A notebook showing in both panes
/// gets a companion for the second one: another canvas and viewport on the same open document, history
/// and undo (``NotebookSession/init(companionOf:)``). A pane keeps the session it shows while its tab
/// doesn't change, so a canvas never moves between panes.
@MainActor
final class SessionStore {
    private struct Entry {
        let session: NotebookSession
        /// Pencil double-tap / squeeze, per canvas.
        let pencil: PencilGestures
    }

    let library: any LibraryModel
    let tools: ToolState
    /// The window these sessions are in, brought forward by ``reveal(_:)``.
    weak var scene: UIWindowScene?
    /// Shows a notebook this window has open (another window asked for it, ``AppWindows``).
    var onReveal: (NotebookID) -> Void = { _ in }
    private var entries: [NotebookID: Entry] = [:]
    /// Second views of notebooks showing in both panes.
    private var companions: [NotebookID: Entry] = [:]
    /// The session each pane shows.
    private var displayed: [OpenTabs.Pane: NotebookSession] = [:]

    init(library: any LibraryModel, tools: ToolState) {
        self.library = library
        self.tools = tools
    }

    /// This window has `id` open (its package has a writer here).
    func holds(_ id: NotebookID) -> Bool {
        entries[id].map { !$0.session.isClosed } ?? false
    }

    /// Another window wants `id`: this window comes forward showing it.
    func reveal(_ id: NotebookID) {
        onReveal(id)
        if let scene {
            UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil)
        }
    }

    /// The session for `notebook`, created on first use.
    func session(for notebook: NotebookSummary, startsFocused: Bool = false) -> NotebookSession {
        if let entry = entries[notebook.id] {
            return entry.session
        }
        let session = NotebookSession(notebook: notebook, library: library, startsFocused: startsFocused)
        entries[notebook.id] = install(session)
        return session
    }

    /// The session `pane` shows for `notebook`: the one it already shows, else the notebook's session, or
    /// a companion when the other pane shows that one.
    func session(for notebook: NotebookSummary, in pane: OpenTabs.Pane, startsFocused: Bool = false) -> NotebookSession {
        if let current = displayed[pane], current.notebookID == notebook.id, !current.isClosed {
            return current
        }
        let main = session(for: notebook, startsFocused: startsFocused)
        let shown = displayed[pane.other] === main ? companion(of: main) : main
        show(shown, in: pane)
        return shown
    }

    /// The split closes with `pane`'s session left showing (as the primary pane). Returns the other pane's
    /// session, still on screen while it slides away; ``retire(_:)`` it after.
    func closeSplit(keeping pane: OpenTabs.Pane) -> NotebookSession? {
        let staying = displayed[pane], leaving = displayed[pane.other]
        displayed = [:]
        displayed[.primary] = staying
        return leaving
    }

    /// A session that left the screen: a companion no pane shows closes.
    func retire(_ session: NotebookSession) {
        guard session.isCompanion, !displayed.values.contains(where: { $0 === session }) else { return }
        if companions[session.notebookID]?.session === session {
            companions[session.notebookID] = nil
        }
        session.close()
    }

    func swapPanes() {
        let primary = displayed[.primary]
        displayed[.primary] = displayed[.secondary]
        displayed[.secondary] = primary
    }

    private func show(_ session: NotebookSession?, in pane: OpenTabs.Pane) {
        let old = displayed[pane]
        displayed[pane] = session
        if let old, old !== session, old.isCompanion, displayed[pane.other] !== old {
            companions.removeValue(forKey: old.notebookID)?.session.close()
        }
    }

    private func companion(of main: NotebookSession) -> NotebookSession {
        if let entry = companions[main.notebookID] {
            return entry.session
        }
        let session = NotebookSession(companionOf: main)
        companions[main.notebookID] = install(session)
        return session
    }

    private func install(_ session: NotebookSession) -> Entry {
        session.onErased = { [tools] in tools.finishedErasing() }
        let pencil = PencilGestures(tools: tools, state: session.state)
        pencil.install(on: session.host)
        return Entry(session: session, pencil: pencil)
    }

    /// Checkpoints every open session (scene left the foreground); companions keep nothing of their own.
    func flushAll() {
        for entry in entries.values {
            entry.session.flush()
        }
    }

    /// Closes the session of a closed tab (its companion first).
    func close(_ id: NotebookID) {
        companions.removeValue(forKey: id)?.session.close()
        entries.removeValue(forKey: id)?.session.close()
    }

    /// The editor went away: every session closes (flushes in the background).
    func closeAll() {
        for id in entries.keys {
            close(id)
        }
        displayed = [:]
    }
}
