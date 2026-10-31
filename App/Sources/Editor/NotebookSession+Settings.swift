import Canvas
import InkModel
import Tools

extension NotebookSession {
    // MARK: Settings

    func setTool(_ tool: ActiveTool, allowsFingerDrawing: Bool, snapsShapes: Bool, holdsToErase: Bool) {
        if tool != .lasso {
            clearSelection()
        }
        self.tool = tool
        engine.setTool(tool.configuration(
            allowsFingerDrawing: allowsFingerDrawing, snapsShapes: snapsShapes, holdsToErase: holdsToErase
        ))
        host.allowsFingerDrawing = allowsFingerDrawing
    }

    /// Paper color and pattern from the title menu: the engine re-themes at once; the pattern becomes the
    /// template of every page and of new pages. Every view of the notebook follows.
    func setPaper(theme: PaperTheme, style: PaperStyle) {
        for view in views {
            view.engine.setTheme(theme)
            view.tintSelection(for: theme)
            view.applyPaperAppearance(theme, to: view.host)
            view.initialTheme = theme
        }
        edits?.run("paper") { [weak self] in
            guard let self, let store, let residency else { return }
            let manifest = await store.manifest
            guard manifest.notebook.theme != theme || manifest.notebook.paper != style else { return }
            try await store.updateNotebook { notebook in
                notebook.theme = theme
                notebook.paper = style
            }
            if manifest.notebook.paper != style {
                try await store.setTemplate(style.defaultTemplate)
                for view in views {
                    if let residency = view.residency {
                        residency.setTemplate(style.defaultTemplate, for: residency.pageIDs)
                    }
                }
            }
            await library.documentDidSave(store.manifest)
            regenerateThumbnails()
        }
    }

    // MARK: History

    /// Undo/redo changed `ids`: scrolls to the first page `ids` touched if none of them is on screen.
    func reveal(_ ids: [PageID]) {
        guard let residency, residency.window != nil, !ids.contains(where: residency.isVisible),
              let first = ids.lazy.compactMap(residency.pageIDs.firstIndex(of:)).first else { return }
        host.scrollToPage(first, animated: true)
    }
}
