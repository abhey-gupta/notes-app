import Foundation
import InkModel

/// An immutable view of the library for the UI: notebooks (most recent first), folders, trash.
public struct LibrarySnapshot: Hashable, Sendable {
    /// Notebooks, most recently modified first.
    public var notebooks: [LibraryEntry]
    /// Folders, display order.
    public var folders: [LibraryFolder]
    /// Deleted notebooks awaiting purge.
    public var trash: [TrashedNotebook]
    /// Increases with every change the store makes; apply a snapshot only if newer than the one shown.
    public var generation: UInt64
    /// `false` while a rebuild is still scanning packages (progressive snapshots).
    public var isComplete: Bool

    /// Creates a snapshot of `index`.
    public init(index: LibraryIndex, generation: UInt64 = 0, isComplete: Bool = true) {
        notebooks = index.notebooks
        folders = index.folders
        trash = index.trash
        self.generation = generation
        self.isComplete = isComplete
    }

    /// "Continue" row: the last 6 by modified.
    public var recents: [LibraryEntry] {
        notebooks.recents()
    }

    /// Entry for `id`.
    public func notebook(_ id: NotebookID) -> LibraryEntry? {
        notebooks.first { $0.id == id }
    }
}

/// What search and sort need from a library row; adopted by ``LibraryEntry`` and app view models.
public protocol LibraryItem {
    /// Notebook ID (stable tiebreak).
    var id: NotebookID { get }
    /// Display title.
    var title: String { get }
    /// Folder, if any.
    var folderID: FolderID? { get }
    /// Creation time.
    var createdAt: Date { get }
    /// Last modification.
    var modifiedAt: Date { get }
}

extension LibraryEntry: LibraryItem {}

/// Library orderings.
public enum LibrarySort: String, CaseIterable, Hashable, Sendable, Identifiable {
    /// Most recently modified first.
    case recent
    /// Title A→Z, Finder-style (`localizedStandardCompare`: numbers in order, case/diacritics folded).
    case title
    /// Newest first.
    case created

    public var id: Self {
        self
    }
}

public extension Sequence where Element: LibraryItem {
    /// Items in `folder` (`nil` = all) whose title contains `query` (trimmed), ignoring case and
    /// diacritics (`localizedStandardContains`, §8). Order is preserved.
    func filtered(folder: FolderID? = nil, matching query: String = "") -> [Element] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return filter { item in
            (folder == nil || item.folderID == folder) && (query.isEmpty || item.title.localizedStandardContains(query))
        }
    }

    /// Items in `sort` order; ties broken by ID, newest first.
    func sorted(by sort: LibrarySort) -> [Element] {
        sorted { a, b in
            switch sort {
            case .recent:
                if a.modifiedAt != b.modifiedAt {
                    return a.modifiedAt > b.modifiedAt
                }
            case .title:
                let order = a.title.localizedStandardCompare(b.title)
                if order != .orderedSame {
                    return order == .orderedAscending
                }
            case .created:
                if a.createdAt != b.createdAt {
                    return a.createdAt > b.createdAt
                }
            }
            return a.id > b.id
        }
    }

    /// The `count` most recently modified items.
    func recents(_ count: Int = 6) -> [Element] {
        Array(sorted(by: .recent).prefix(count))
    }
}
