import CoreTransferable
import InkModel
import Library
import SwiftUI
import UniformTypeIdentifiers

extension LibrarySidebar {
    // MARK: Tree

    enum Row: Identifiable {
        case folder(LibraryFolder, depth: Int)
        case notebook(NotebookSummary, depth: Int)

        var id: String {
            switch self {
            case let .folder(item, _): "f\(item.id)"
            case let .notebook(notebook, _): "n\(notebook.id)"
            }
        }
    }

    /// Folders and notebooks by parent, built once per render.
    struct Contents {
        let folders: [FolderID?: [LibraryFolder]]
        let notebooks: [FolderID: [NotebookSummary]]

        @MainActor
        init(_ library: any LibraryModel) {
            let all = library.folders
            let topLevel = Set(all.children(of: nil).map(\.id))
            folders = Dictionary(grouping: all) { topLevel.contains($0.id) ? nil : $0.parentID }
            let filed = library.notebooks.compactMap { notebook in notebook.folderID.map { ($0, notebook) } }
            notebooks = Dictionary(grouping: filed, by: \.0).mapValues { $0.map(\.1).sorted(by: .title) }
        }

        func hasContents(_ id: FolderID) -> Bool {
            folders[id] != nil || notebooks[id] != nil
        }
    }

    /// The visible tree, depth first: an open folder's subfolders, then its notebooks.
    func rows(_ contents: Contents) -> [Row] {
        var rows: [Row] = []
        func add(_ parent: FolderID?, depth: Int) {
            for item in contents.folders[parent] ?? [] {
                rows.append(.folder(item, depth: depth))
                guard expanded.contains(item.id) else { continue }
                add(item.id, depth: depth + 1)
                rows += (contents.notebooks[item.id] ?? []).map { .notebook($0, depth: depth + 1) }
            }
        }
        add(nil, depth: 0)
        return rows
    }
}

/// Where a dragged notebook would land.
enum DropTarget: Hashable {
    /// All Notebooks: no folder.
    case all
    case folder(FolderID)
}

/// A notebook being dragged inside the app (cover or sidebar row → sidebar folder).
struct NotebookReference: Codable, Transferable {
    let id: NotebookID

    /// The notebook last picked up, for a drop target to show before the drop loads it (#175).
    @MainActor static var dragged: NotebookID?

    /// The payload of a drag starting now (`draggable` asks for it as the drag begins).
    @MainActor static func picking(_ id: NotebookID) -> NotebookReference {
        dragged = id
        return NotebookReference(id: id)
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .notebookReference)
    }
}

extension UTType {
    /// Declared in Info.plist (`UTExportedTypeDeclarations`).
    static let notebookReference = UTType(exportedAs: "com.abhey.notespace.notebook-reference")
}
