import InkEnginePencilKit

extension NotebookSession {
    /// "Keep exact colors" from the title menu: the engine redraws at once, the manifest follows.
    func setKeepsExactColors(_ keep: Bool) {
        state.keepsExactColors = keep
        applyPalette(keepsExactColors: keep)
        enqueue("exactColors") { [weak self] in
            guard let self, let store, await store.manifest.notebook.keepsExactColors != keep else { return }
            try await store.updateNotebook { $0.keepsExactColors = keep }
            await library.documentDidSave(store.manifest)
        }
    }

    func applyPalette(keepsExactColors: Bool) {
        (engine as? PencilKitInkEngine)?.setPalette(DesignSystemInkPalette(keepsExactColors: keepsExactColors))
    }
}
