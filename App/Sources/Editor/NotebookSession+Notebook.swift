import Foundation

/// Notebook actions from the title menu (#126). The open `DocumentStore` is the package's only writer, so
/// title changes go through it, and duplicate/delete wait for it to reach disk.
extension NotebookSession {
    /// Writes the title to the manifest; the library entry follows. Returns the title as saved (blank → "Untitled").
    @discardableResult
    func rename(to title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Untitled" : trimmed
        edits?.run("rename") { [weak self] in
            guard let self, let store, await store.manifest.notebook.title != title else { return }
            try await store.updateNotebook { $0.title = title }
            await library.documentDidSave(store.manifest)
        }
        return title
    }

    /// Checkpoints first so the copy has everything written so far.
    func duplicate() {
        edits?.run("duplicate") { [weak self] in
            guard let self, let store else { return }
            try await store.flush()
            await library.documentDidSave(store.manifest)
            library.duplicate(notebookID)
        }
    }

    /// Closes the editor's store, then moves the notebook to the trash once nothing writes its package.
    func closeAndDelete() {
        close()
        let (library, id, closing) = (library, notebookID, Self.closing[notebookID])
        Task { @MainActor in
            await closing?.value
            library.delete(id)
        }
    }
}
