import Foundation
import InkModel

/// PDF import (#119): `backgrounds/<file>.pdf` in the package, pages drawn on it (``PageBackground/pdf(file:page:)``).
public extension NotebookPackage {
    /// `backgrounds/`: imported PDFs (#119).
    var backgroundsDirectory: URL {
        url.appending(path: "backgrounds", directoryHint: .isDirectory)
    }

    /// `backgrounds/<file>`.
    func backgroundURL(_ file: String) -> URL {
        backgroundsDirectory.appending(path: file, directoryHint: .notDirectory)
    }

    /// Writes a new package from a PDF (#119): the file is copied into `backgrounds/` and every PDF page
    /// becomes a blank-template page drawn on it, in order. The notebook takes the first page's size
    /// (``PDFSource/notebookPageSize(for:)``); other pages are fitted into it. Staged like
    /// ``create(at:notebook:)``, so the package appears complete or not at all.
    /// - Throws: ``DocumentError/unreadablePDF(_:)`` for a file CoreGraphics can't open (or locked, or
    ///   empty), ``DocumentError/alreadyExists(_:)``, ``DocumentError/io(_:reason:)``.
    static func create(at url: URL, notebook: Notebook, pdf source: URL) throws(DocumentError) -> NotebookPackage {
        guard let pdf = PDFSource(url: source), pdf.pageCount > 0, let first = pdf.pageSize(at: 0) else {
            throw .unreadablePDF(source)
        }
        let file = "\(UUID().uuidString.lowercased()).pdf"
        var notebook = notebook
        notebook.pageSize = PDFSource.notebookPageSize(for: first)
        return try create(at: url, notebook: notebook) { staging in
            let backgrounds = staging.appending(path: "backgrounds", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: backgrounds, withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: source, to: backgrounds.appending(path: file, directoryHint: .notDirectory))
            return (0 ..< pdf.pageCount).map { PageEntry(id: PageID(), template: .blank, background: .pdf(file: file, page: $0)) }
        }
    }

    /// Artwork for every page with a PDF background, each file opened once and drawn lazily. Pages whose
    /// file is missing or unreadable get none (plain paper).
    func artwork() -> [PageID: any PageArtwork] {
        var sources: [String: PDFSource?] = [:]
        var out: [PageID: any PageArtwork] = [:]
        for entry in manifest.pages {
            guard case let .pdf(file, page) = entry.background else { continue }
            let source = sources[file] ?? {
                let opened = PDFSource(url: backgroundURL(file))
                sources[file] = opened
                return opened
            }()
            if let source {
                out[entry.id] = PDFArtwork(source: source, pageIndex: page)
            }
        }
        return out
    }
}
