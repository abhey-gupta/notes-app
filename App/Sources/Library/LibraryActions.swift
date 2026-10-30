import InkModel
import Library
import SwiftUI

/// Library management prompts (§8): rename, delete confirmation, folder name.
enum LibraryPrompt: Hashable {
    case renameNotebook(NotebookSummary)
    case deleteNotebook(NotebookSummary)
    /// In `parent` (`nil` = top level).
    case newFolder(parent: FolderID?)
    case renameFolder(LibraryFolder)
    case deleteFolder(LibraryFolder)
}

/// Cover / recent-card context menu: Open in Split View (beside the showing tab, #175), Rename, Move to
/// Folder, Duplicate, Delete.
struct NotebookMenu: View {
    let notebook: NotebookSummary
    let library: any LibraryModel
    @Binding var prompt: LibraryPrompt?
    @Environment(\.openInSplitView) private var openInSplitView
    @Environment(\.chromeLayout) private var chrome

    var body: some View {
        if let openInSplitView, !chrome.isCompact {
            Button("Open in Split View", systemImage: TabStrip.splitSymbol) { openInSplitView(notebook.id) }
            Divider()
        }
        Button("Rename", systemImage: "pencil") { prompt = .renameNotebook(notebook) }
        Menu("Move to Folder", systemImage: "folder") {
            FolderMenuItems(folders: library.folders, selected: notebook.folderID) { library.move(notebook.id, to: $0) }
        }
        Button("Duplicate", systemImage: "plus.square.on.square") { library.duplicate(notebook.id) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { prompt = .deleteNotebook(notebook) }
    }
}

/// Folder picker rows for a menu (#117): None, then the folder tree. A folder with subfolders is a submenu
/// whose first row picks the folder itself.
struct FolderMenuItems: View {
    let folders: [LibraryFolder]
    var parent: FolderID?
    let selected: FolderID?
    let pick: (FolderID?) -> Void

    var body: some View {
        if parent == nil {
            item("None", id: nil)
        }
        ForEach(folders.children(of: parent)) { folder in
            if folders.children(of: folder.id).isEmpty {
                item(folder.name, id: folder.id)
            } else {
                Menu(folder.name) {
                    item(folder.name, id: folder.id)
                    Divider()
                    FolderMenuItems(folders: folders, parent: folder.id, selected: selected, pick: pick)
                }
            }
        }
    }

    private func item(_ name: String, id: FolderID?) -> some View {
        Button {
            pick(id)
        } label: {
            if selected == id {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
    }
}

extension View {
    /// Presents `prompt` as an alert and applies the answer to `library`.
    func libraryPrompts(_ prompt: Binding<LibraryPrompt?>, library: any LibraryModel) -> some View {
        modifier(LibraryPrompts(prompt: prompt, library: library))
    }
}

private struct LibraryPrompts: ViewModifier {
    @Binding var prompt: LibraryPrompt?
    let library: any LibraryModel
    @State private var text = ""

    func body(content: Content) -> some View {
        let current = prompt
        content
            .alert(title(current), isPresented: isPresented) {
                switch current {
                case let .deleteNotebook(notebook):
                    Button("Cancel", role: .cancel) {}
                    Button("Delete", role: .destructive) { library.delete(notebook.id) }
                case let .renameNotebook(notebook):
                    nameField("Title", confirm: "Rename") { library.rename(notebook.id, to: text) }
                case let .newFolder(parent):
                    nameField("Folder name", confirm: "Create") { library.createFolder(named: text, in: parent) }
                case let .renameFolder(folder):
                    nameField("Folder name", confirm: "Rename") { library.renameFolder(folder.id, to: text) }
                case let .deleteFolder(folder):
                    Button("Cancel", role: .cancel) {}
                    Button("Delete", role: .destructive) { library.deleteFolder(folder.id) }
                case nil:
                    EmptyView()
                }
            } message: {
                message(current)
            }
            .onChange(of: prompt) { _, prompt in
                switch prompt {
                case let .renameNotebook(notebook): text = notebook.title
                case let .renameFolder(folder): text = folder.name
                default: text = ""
                }
            }
    }

    @ViewBuilder
    private func message(_ prompt: LibraryPrompt?) -> some View {
        switch prompt {
        case .deleteNotebook:
            Text("It stays in the trash for 30 days.")
        case let .deleteFolder(folder):
            if let contents = Self.contents(of: folder, in: library) {
                Text("Its \(contents) will be deleted too. Notebooks stay in the trash for 30 days.")
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func nameField(_ placeholder: String, confirm: String, action: @escaping () -> Void) -> some View {
        TextField(placeholder, text: $text)
            .accessibilityIdentifier("promptField")
        Button("Cancel", role: .cancel) {}
        Button(confirm, action: action)
            .keyboardShortcut(.defaultAction)
    }

    private var isPresented: Binding<Bool> {
        Binding { prompt != nil } set: {
            if !$0 {
                prompt = nil
            }
        }
    }

    private func title(_ prompt: LibraryPrompt?) -> String {
        switch prompt {
        case let .deleteNotebook(notebook): "Delete “\(notebook.title)”?"
        case .renameNotebook: "Rename Notebook"
        case .newFolder: "New Folder"
        case .renameFolder: "Rename Folder"
        case let .deleteFolder(folder): "Delete “\(folder.name)”?"
        case nil: ""
        }
    }

    /// "2 folders and 4 notebooks"; nil when empty.
    static func contents(of folder: LibraryFolder, in library: any LibraryModel) -> String? {
        let folders = library.folders.subtree(of: folder.id).count - 1
        let notebooks = library.notebookCount(inSubtree: folder.id)
        let parts = [
            folders == 0 ? nil : folders == 1 ? "1 folder" : "\(folders) folders",
            notebooks == 0 ? nil : EditedLabel.notebooks(notebooks),
        ].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }
}

extension EnvironmentValues {
    /// Opens a notebook in split view beside the showing tab (#175); `nil` with no tab open or no room.
    @Entry var openInSplitView: ((NotebookID) -> Void)?
}
