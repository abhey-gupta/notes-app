import Editing

extension NotebookSession {
    /// "Keep exact colors" from the title menu: the engines of every view redraw at once, the manifest follows.
    func setKeepsExactColors(_ keep: Bool) {
        for view in views {
            view.state.keepsExactColors = keep
            view.applyPalette(keepsExactColors: keep)
        }
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
