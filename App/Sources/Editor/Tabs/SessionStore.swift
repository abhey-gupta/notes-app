import InkModel
import Tools

/// The editor's open ``NotebookSession``s, one per tab that has been shown (#191). Switching tabs keeps the
/// previous session alive (flushed), so switching back costs nothing; leaving the editor closes them all,
/// so the library is the package's only writer while it's on screen (rename, duplicate, delete).
@MainActor
final class SessionStore {
    private struct Entry {
        let session: NotebookSession
        /// Pencil double-tap / squeeze, per canvas.
        let pencil: PencilGestures
    }

    let library: any LibraryModel
    let tools: ToolState
    private var entries: [NotebookID: Entry] = [:]

    init(library: any LibraryModel, tools: ToolState) {
        self.library = library
        self.tools = tools
    }

    /// The session for `notebook`, created on first use.
    func session(for notebook: NotebookSummary, startsFocused: Bool = false) -> NotebookSession {
        if let entry = entries[notebook.id] {
            return entry.session
        }
        let session = NotebookSession(notebook: notebook, library: library, startsFocused: startsFocused)
        session.onErased = { [tools] in tools.finishedErasing() }
        let pencil = PencilGestures(tools: tools, state: session.state)
        pencil.install(on: session.host)
        entries[notebook.id] = Entry(session: session, pencil: pencil)
        return session
    }

    /// Checkpoints every open session (scene left the foreground).
    func flushAll() {
        for entry in entries.values {
            entry.session.flush()
        }
    }

    /// Closes the session of a closed tab.
    func close(_ id: NotebookID) {
        entries.removeValue(forKey: id)?.session.close()
    }

    /// The editor went away: every session closes (flushes in the background).
    func closeAll() {
        for id in entries.keys {
            close(id)
        }
    }
}
