import Editing

extension NotebookSession {
    /// "Keep exact colors" from the ⋯ popover: the engine redraws at once, the manifest follows.
    func setKeepsExactColors(_ keep: Bool) {
        state.keepsExactColors = keep
        applyPalette(keepsExactColors: keep)
        edits?.run("exactColors") { [weak self] in
            guard let self, let store, await store.manifest.notebook.keepsExactColors != keep else { return }
            try await store.updateNotebook { $0.keepsExactColors = keep }
            await library.documentDidSave(store.manifest)
        }
    }

    func applyPalette(keepsExactColors: Bool) {
        engine.setPalette(DesignSystemInkPalette(keepsExactColors: keepsExactColors))
    }
}
