import CoreGraphics
import Document
import Foundation
import InkModel
import Library
import os
import UIKit

/// A PDF waiting in the import sheet (#119): a private copy the app owns (``PDFInbox``), deleted when the
/// sheet goes away.
struct PDFImportRequest: Identifiable, Hashable {
    let url: URL

    var id: URL {
        url
    }

    /// Title suggestion: the file name without its extension.
    var suggestedTitle: String {
        url.deletingPathExtension().lastPathComponent
    }
}

/// Import sheet output: the PDF, title and folder. The notebook is blank paper on white, page size from
/// the PDF (``Document/NotebookPackage/create(at:notebook:pdf:)``).
struct PDFImportDraft {
    var url: URL
    var title: String
    var folderID: FolderID?

    var resolvedTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// Cover picked from the title, so a batch of imports doesn't come out one color.
    func makeNotebook(now: Date = Date()) -> Notebook {
        let seed = resolvedTitle.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let cover = CoverColor.allCases[seed % CoverColor.allCases.count]
        return Notebook(title: resolvedTitle, cover: cover, paper: .blank, theme: .white, createdAt: now)
    }
}

/// Incoming PDFs: the Files picker's security-scoped URL or an Open In copy (`Documents/Inbox`, which
/// iOS fills because `LSSupportsOpeningDocumentsInPlace` is off) become a private file in the temporary
/// directory, named as the original, until the sheet imports or discards it.
enum PDFInbox {
    static let directory = FileManager.default.temporaryDirectory.appending(path: "PDFImport", directoryHint: .isDirectory)

    /// Copies (or, out of our own Inbox, moves) `url` into a fresh folder under ``directory``.
    static func stage(_ url: URL) throws -> PDFImportRequest {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = url.pathExtension.lowercased() == "pdf" ? url.lastPathComponent : url.lastPathComponent + ".pdf"
        let staged = folder.appending(path: name, directoryHint: .notDirectory)
        if isInbox(url) {
            try FileManager.default.moveItem(at: url, to: staged)
        } else {
            try FileManager.default.copyItem(at: url, to: staged)
        }
        return PDFImportRequest(url: staged)
    }

    /// Files picker result → staged request; `nil` (logged) if picking or copying failed.
    static func stage(_ result: Result<URL, any Error>) -> PDFImportRequest? {
        do {
            return try stage(result.get())
        } catch {
            Logger(subsystem: "com.abhey.notespace", category: "library").error("pick PDF: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Deletes every staged PDF (the import sheet went away).
    static func discardAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func isInbox(_ url: URL) -> Bool {
        let inbox = URL.documentsDirectory.appending(path: "Inbox", directoryHint: .isDirectory).standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(inbox)
    }
}

/// What the import sheet shows about a PDF: page count, file size, the first pages as thumbnails.
struct PDFImportPreview: Sendable {
    enum Problem: Sendable {
        case locked, unreadable
    }

    var pageCount = 0
    var byteCount: Int64 = 0
    /// Notebook page size (thumbnails share it, as the pages will).
    var pageSize = Notebook.a4Portrait
    var thumbnails: [CGImage] = []
    var problem: Problem?

    /// Reads the PDF and renders up to `count` thumbnails `width` points wide, off main.
    @concurrent
    static func load(_ url: URL, count: Int, width: CGFloat, scale: CGFloat) async -> PDFImportPreview {
        var preview = PDFImportPreview()
        preview.byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard let source = PDFSource(url: url), source.pageCount > 0, let first = source.pageSize(at: 0) else {
            preview.problem = PDFSource.isLocked(url) ? .locked : .unreadable
            return preview
        }
        preview.pageCount = source.pageCount
        preview.pageSize = PDFSource.notebookPageSize(for: first)
        let size = CGSize(width: width, height: (width * preview.pageSize.height / preview.pageSize.width).rounded())
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        for index in 0 ..< min(count, source.pageCount) {
            let artwork = PDFArtwork(source: source, pageIndex: index)
            let image = renderer.image { context in
                let cg = context.cgContext
                cg.scaleBy(x: size.width / preview.pageSize.width, y: size.height / preview.pageSize.height)
                artwork.draw(in: cg, size: preview.pageSize)
            }
            if let cgImage = image.cgImage {
                preview.thumbnails.append(cgImage)
            }
        }
        return preview
    }

    /// "24 pages · 3.1 MB".
    var summary: String {
        let pages = pageCount == 1 ? "1 page" : "\(pageCount) pages"
        return "\(pages) · \(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))"
    }
}

#if DEBUG
    extension PDFInbox {
        /// `-importSamplePDF YES`: a 24-page lecture-slides PDF staged for the import sheet (UI tests,
        /// screenshots), as if opened from Files.
        static func sample() -> PDFImportRequest? {
            let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            let url = folder.appending(path: "Lecture 4 — Thermodynamics.pdf", directoryHint: .notDirectory)
            let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
            let ink = UIColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: url) { context in
                    for page in 1 ... 24 {
                        context.beginPage()
                        let heading = page == 1 ? "Lecture 4\nThermodynamics" : "\(page). The second law"
                        heading.draw(in: CGRect(x: 56, y: 64, width: 500, height: 120), withAttributes: [
                            .font: UIFont.systemFont(ofSize: page == 1 ? 40 : 26, weight: .semibold), .foregroundColor: ink,
                        ])
                        ink.withAlphaComponent(0.18).setFill()
                        for line in 0 ..< 14 {
                            let width = [460, 420, 380, 440][line % 4]
                            UIBezierPath(roundedRect: CGRect(x: 56, y: 220 + line * 34, width: width, height: 10), cornerRadius: 5).fill()
                        }
                    }
                }
                return PDFImportRequest(url: url)
            } catch {
                return nil
            }
        }
    }
#endif
