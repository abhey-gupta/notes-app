import Foundation
import InkModel

/// A notebook on disk: a `.nb` directory package (ARCHITECTURE.md §4.2).
///
/// ```
/// <notebookID>.nb/
///   manifest.json            Manifest (formatVersion, notebook fields, page entries in order)
///   pages/<pageID>.strokes   StrokeCodec file; absent = page has no strokes yet
///   pages/<pageID>.wal       autosave journal, reserved for the WAL (§4.4)
///   thumbs/<pageID>.heic     page thumbnail;  thumbs/cover.heic  library cover
/// ```
///
/// A value holding the package URL and the manifest as last written. Reads are page-scoped:
/// ``open(at:)`` reads only `manifest.json`, ``loadPage(_:)`` only that page's stroke file. Every file
/// write is atomic (temp file + `rename`). Mutating methods write first and update ``manifest`` only on
/// success. Not synchronized: confine a package to one actor (the future `DocumentStore`).
public struct NotebookPackage: Sendable {
    /// Package directory extension.
    public static let pathExtension = "nb"
    /// Exported UTType (declared in `project.yml`), conforming to `com.apple.package`.
    public static let typeIdentifier = "com.abhey.notespace.notebook"

    /// Package root.
    public let url: URL
    /// Manifest as last read or written.
    public private(set) var manifest: Manifest

    private init(url: URL, manifest: Manifest) {
        self.url = url
        self.manifest = manifest
    }

    // MARK: Locations

    /// `Documents/Notebooks`, where packages live (§15.7).
    public static func notebooksDirectory(in documents: URL = .documentsDirectory) -> URL {
        documents.appending(path: "Notebooks", directoryHint: .isDirectory)
    }

    /// Package URL for a notebook: `<directory>/<notebookID>.nb`. Named by ID so renames never move files.
    public static func url(for id: NotebookID, in directory: URL) -> URL {
        directory.appending(path: "\(id).\(pathExtension)", directoryHint: .isDirectory)
    }

    /// Every `.nb` package directly in `directory`, sorted by name; empty if the directory does not exist.
    /// For rebuilding the library index (§8).
    public static func packageURLs(in directory: URL) throws(DocumentError) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == pathExtension }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            throw .io(directory, reason: "\(error)")
        }
    }

    /// `manifest.json`.
    public var manifestURL: URL {
        Self.manifestURL(in: url)
    }

    /// `pages/`.
    public var pagesDirectory: URL {
        url.appending(path: "pages", directoryHint: .isDirectory)
    }

    /// `thumbs/`.
    public var thumbnailsDirectory: URL {
        url.appending(path: "thumbs", directoryHint: .isDirectory)
    }

    /// `pages/<id>.strokes`.
    public func strokesURL(for id: PageID) -> URL {
        pagesDirectory.appending(path: "\(id).strokes", directoryHint: .notDirectory)
    }

    /// `pages/<id>.wal`: the page's autosave journal (§4.4).
    public func journalURL(for id: PageID) -> URL {
        pagesDirectory.appending(path: "\(id).wal", directoryHint: .notDirectory)
    }

    /// `thumbs/<id>.heic`: page thumbnail (§5.5).
    public func thumbnailURL(for id: PageID) -> URL {
        thumbnailsDirectory.appending(path: "\(id).heic", directoryHint: .notDirectory)
    }

    /// `thumbs/cover.heic`: first page at cover size for library recents (§5.5).
    public var coverThumbnailURL: URL {
        thumbnailsDirectory.appending(path: "cover.heic", directoryHint: .notDirectory)
    }

    // MARK: Create / open

    /// Writes a new package at `url` (e.g. ``url(for:in:)``). Parent directories are created.
    ///
    /// The package is assembled in a hidden sibling directory and renamed into place, so a crash never
    /// leaves a half-written `.nb`. A notebook with no pages gets one (paper's default template).
    /// - Throws: ``DocumentError/alreadyExists(_:)`` if anything is at `url`.
    public static func create(at url: URL, notebook: Notebook) throws(DocumentError) -> NotebookPackage {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path(percentEncoded: false)) else { throw .alreadyExists(url) }
        var notebook = notebook
        if notebook.pages.isEmpty {
            notebook.pages = [PageID()]
        }
        let manifest = Manifest(notebook: notebook)
        let data = try manifest.encoded()
        let staging = url.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString).staging", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: staging.appending(path: "pages"), withIntermediateDirectories: true)
            try fm.createDirectory(at: staging.appending(path: "thumbs"), withIntermediateDirectories: false)
            try data.write(to: manifestURL(in: staging))
            try fm.moveItem(at: staging, to: url)
        } catch {
            try? fm.removeItem(at: staging)
            if fm.fileExists(atPath: url.path(percentEncoded: false)) {
                throw .alreadyExists(url)
            }
            throw .io(url, reason: "\(error)")
        }
        return NotebookPackage(url: url, manifest: manifest)
    }

    /// Opens a package, reading only `manifest.json`.
    public static func open(at url: URL) throws(DocumentError) -> NotebookPackage {
        try NotebookPackage(url: url, manifest: readManifest(at: url))
    }

    /// Reads and decodes a package's manifest without opening it (library index rebuild).
    public static func readManifest(at url: URL) throws(DocumentError) -> Manifest {
        let file = manifestURL(in: url)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw .notFound(url)
        } catch {
            throw .io(file, reason: "\(error)")
        }
        return try Manifest.decode(data)
    }

    // MARK: Pages

    /// Loads one page: its manifest entry plus `pages/<id>.strokes`, nothing else.
    /// A page with no stroke file yet is empty.
    public func loadPage(_ id: PageID) throws(DocumentError) -> Page {
        guard let entry = manifest.entry(for: id) else { throw .unknownPage(id) }
        let file = strokesURL(for: id)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Page(id: id, template: entry.template, rev: entry.rev)
        } catch {
            throw .io(file, reason: "\(error)")
        }
        let strokes: [Stroke]
        do {
            strokes = try StrokeCodec.decode(data)
        } catch let .unsupportedVersion(found, supported) {
            throw .unsupportedFormatVersion(found: Int(found), supported: Int(supported))
        } catch {
            throw .corruptPage(id, error)
        }
        return Page(id: id, template: entry.template, strokes: strokes, rev: entry.rev)
    }

    /// Loads the page at `index` in page order.
    public func loadPage(at index: Int) throws(DocumentError) -> Page {
        let pages = manifest.notebook.pages
        guard pages.indices.contains(index) else { throw .pageIndexOutOfRange(index) }
        return try loadPage(pages[index])
    }

    /// Saves one page; see ``savePages(_:)``.
    public mutating func savePage(_ page: Page) throws(DocumentError) {
        try savePages(CollectionOfOne(page))
    }

    /// Checkpoints pages: rewrites each stroke file atomically, then the manifest once (entries take each
    /// page's `rev` and template; notebook `rev`/`modifiedAt` bumped). All pages are encoded before
    /// anything is written.
    public mutating func savePages(_ pages: some Collection<Page>) throws(DocumentError) {
        var next = manifest
        var files: [(URL, Data)] = []
        files.reserveCapacity(pages.count)
        for page in pages {
            guard var entry = next.entry(for: page.id) else { throw .unknownPage(page.id) }
            entry.rev = page.rev
            entry.template = page.template
            try next.updateEntry(entry)
            do {
                try files.append((strokesURL(for: page.id), StrokeCodec.encode(page.strokes)))
            } catch {
                throw .pageTooLarge(page.id)
            }
        }
        for (file, data) in files {
            try Self.writeAtomically(data, to: file)
        }
        try commit(next)
    }

    /// Inserts an empty page (no stroke file is written until it has ink).
    /// - Parameters:
    ///   - index: Position in `0...pageCount`; `nil` appends.
    ///   - template: Background; `nil` uses the notebook paper's default.
    /// - Returns: The new page's ID.
    @discardableResult
    public mutating func insertPage(at index: Int? = nil, template: PageTemplate? = nil) throws(DocumentError) -> PageID {
        var next = manifest
        let id = PageID()
        let entry = PageEntry(id: id, template: template ?? next.notebook.paper.defaultTemplate)
        try next.insertPage(entry, at: index ?? next.notebook.pages.count)
        try commit(next)
        return id
    }

    /// Removes a page from the manifest, then deletes its stroke file, journal and thumbnail.
    /// A crash in between leaves only unreferenced files, never a dangling reference.
    public mutating func deletePage(_ id: PageID) throws(DocumentError) {
        var next = manifest
        try next.removePage(id)
        try commit(next)
        for file in [strokesURL(for: id), journalURL(for: id), thumbnailURL(for: id)] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Moves the page at `source` to `destination` (both in `0..<pageCount`).
    public mutating func movePage(from source: Int, to destination: Int) throws(DocumentError) {
        var next = manifest
        try next.movePage(from: source, to: destination)
        try commit(next)
    }

    /// Changes notebook metadata (title, cover, paper, theme…) and writes the manifest.
    public mutating func updateNotebook(_ change: (inout Notebook) -> Void) throws(DocumentError) {
        var next = manifest
        change(&next.notebook)
        try commit(next)
    }

    // MARK: Private

    private static func manifestURL(in package: URL) -> URL {
        package.appending(path: "manifest.json", directoryHint: .notDirectory)
    }

    /// Bumps the notebook's `rev`/`modifiedAt`, writes the manifest atomically, then adopts it.
    private mutating func commit(_ next: Manifest) throws(DocumentError) {
        var next = next
        next.notebook.markModified(at: Date().roundedToMilliseconds)
        try Self.writeAtomically(next.encoded(), to: manifestURL)
        manifest = next
    }

    /// Writes `data` to a hidden temp file beside `url`, then `rename`s it over `url`.
    static func writeAtomically(_ data: Data, to url: URL) throws(DocumentError) {
        let temp = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        do {
            try data.write(to: temp)
        } catch {
            throw .io(url, reason: "\(error)")
        }
        let status = temp.withUnsafeFileSystemRepresentation { from in
            url.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return EINVAL }
                return rename(from, to) == 0 ? 0 : errno
            }
        }
        guard status == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw .io(url, reason: String(cString: strerror(status)))
        }
    }
}
