import CoreGraphics
import Foundation
import InkModel
import Library

/// Where a notebook's package sits: in the library (`Documents/Notebooks`, `Library/Trash`) and in the
/// backup folder (`Notebooks/`, `Trash/`).
public enum BackupLocation: String, Hashable, Sendable, Codable {
    case notebooks
    case trash

    /// Directory in the backup folder.
    var directory: String {
        switch self {
        case .notebooks: "Notebooks"
        case .trash: "Trash"
        }
    }
}

/// Paths inside the backup folder (#174): `library.json` · `Notebooks/<id>.nb/` · `Trash/<id>.nb/`.
enum BackupLayout {
    static let catalog = "library.json"

    /// `Notebooks/<id>.nb` or `Trash/<id>.nb`.
    static func package(_ id: NotebookID, in location: BackupLocation) -> String {
        "\(location.directory)/\(id).nb"
    }
}

/// `library.json` in the backup folder: what Restore lists, so it never reads a manifest. Rewritten by every
/// run that changed it; notebooks another device (or an earlier install) backed up stay listed while their
/// packages are there.
public struct BackupCatalog: Hashable, Sendable, Codable {
    /// Version written by, and the newest readable by, this build.
    public static let formatVersion = 1

    /// One backed-up notebook.
    public struct Notebook: Hashable, Sendable, Codable, Identifiable {
        public let id: NotebookID
        public var title: String
        public var folderID: FolderID?
        public var cover: CoverColor
        public var paper: PaperStyle
        public var theme: PaperTheme
        public var pageCount: Int
        public var pageSize: CGSize
        public var modifiedAt: Date
        /// Manifest `rev` of the backed-up copy.
        public var rev: UInt64
        /// In the backup's `Trash/` (deleted on the iPad, kept until its 30-day purge).
        public var trashed: Bool

        public init(entry: LibraryEntry, rev: UInt64, trashed: Bool) {
            id = entry.id
            title = entry.title
            folderID = entry.folderID
            cover = entry.cover
            paper = entry.paper
            theme = entry.theme
            pageCount = entry.pageCount
            pageSize = entry.pageSize
            modifiedAt = entry.modifiedAt
            self.rev = rev
            self.trashed = trashed
        }
    }

    public var formatVersion = Self.formatVersion
    /// Folders the notebooks are filed in (with their ancestors).
    public var folders: [LibraryFolder]
    /// Most recently modified first.
    public var notebooks: [Notebook]
    /// The device that wrote it ("iPad").
    public var device: String
    public var writtenAt: Date

    public init(folders: [LibraryFolder], notebooks: [Notebook], device: String, writtenAt: Date) {
        self.folders = folders
        self.notebooks = notebooks
        self.device = device
        self.writtenAt = writtenAt
    }

    /// Same folders and notebooks (whoever wrote them, whenever).
    public func hasContents(of other: BackupCatalog) -> Bool {
        folders == other.folders && notebooks == other.notebooks
    }

    /// Pretty JSON, sorted keys, dates as Unix ms: people open it in Files.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    /// `nil` if the data isn't a catalog this build reads.
    public static func decode(_ data: Data) -> BackupCatalog? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let catalog = try? decoder.decode(BackupCatalog.self, from: data), catalog.formatVersion <= formatVersion else {
            return nil
        }
        return catalog
    }

    /// The catalog's contents after a run: this library's backed-up notebooks (as `state` has them) and, from
    /// `remote`, notebooks this library doesn't back up whose packages are still in the folder (`listing`), with
    /// the folders they need. `removed`: deleted from the folder this run.
    static func merged(
        snapshot: LibrarySnapshot, state: BackupState, remote: BackupCatalog?, listing: RemoteListing, removed: Set<NotebookID>
    ) -> (folders: [LibraryFolder], notebooks: [Notebook]) {
        var notebooks: [Notebook] = []
        let entries = snapshot.notebooks.map { ($0, BackupLocation.notebooks) } + snapshot.trash.map { ($0.entry, BackupLocation.trash) }
        for (entry, location) in entries {
            guard let backedUp = state.notebooks[entry.id], backedUp.location == location else { continue }
            notebooks.append(Notebook(entry: entry, rev: backedUp.rev, trashed: location == .trash))
        }
        var folders = snapshot.folders
        let known = Set(notebooks.map(\.id))
        for item in remote?.notebooks ?? []
            where !known.contains(item.id) && state.notebooks[item.id] == nil && !removed.contains(item.id)
        {
            guard listing.contains(item.id, at: item.trashed ? .trash : .notebooks) else { continue }
            notebooks.append(item)
            for folder in item.folderID.map({ remote?.folders.path(to: $0) ?? [] }) ?? []
                where !folders.contains(where: { $0.id == folder.id })
            {
                folders.append(folder)
            }
        }
        notebooks.sort { $0.modifiedAt != $1.modifiedAt ? $0.modifiedAt > $1.modifiedAt : $0.id > $1.id }
        return (folders, notebooks)
    }
}
