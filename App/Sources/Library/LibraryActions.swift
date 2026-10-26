import InkModel
import Library
import SwiftUI

/// Library management prompts (§8): rename, delete confirmation, folder name.
enum LibraryPrompt: Hashable {
    case renameNotebook(NotebookSummary)
    case deleteNotebook(NotebookSummary)
    /// New folder inside `parent` (`nil` = top level).
    case newFolder(parent: FolderID?)
    case renameFolder(LibraryFolder)
}

/// Cover / recent-card context menu: Rename, Move to Folder, Duplicate, Delete. The editor's title menu
/// reuses it (#126) with its own duplicate, since the open notebook's store must checkpoint first.
struct NotebookMenu: View {
    let notebook: NotebookSummary
    let library: any LibraryModel
    @Binding var prompt: LibraryPrompt?
    var deleteTitle = "Delete"
    var onDuplicate: (() -> Void)?

    var body: some View {
        Button("Rename", systemImage: "pencil") { prompt = .renameNotebook(notebook) }
        Menu("Move to Folder", systemImage: "folder") {
            folderButton("None", id: nil)
            ForEach(library.folders) { folder in
                folderButton(library.folderPath(id: folder.id) ?? folder.name, id: folder.id)
            }
        }
        Button("Duplicate", systemImage: "plus.square.on.square") {
            if let onDuplicate {
                onDuplicate()
            } else {
                library.duplicate(notebook.id)
            }
        }
        Divider()
        Button(deleteTitle, systemImage: "trash", role: .destructive) { prompt = .deleteNotebook(notebook) }
    }

    private func folderButton(_ name: String, id: FolderID?) -> some View {
        Button {
            library.move(notebook.id, to: id)
        } label: {
            if notebook.folderID == id {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
    }
}

extension View {
    /// Presents `prompt` as an alert and applies the answer to `library`, or to `onRename` / `onDelete` when
    /// given (the editor, whose open store owns the notebook's package).
    func libraryPrompts(
        _ prompt: Binding<LibraryPrompt?>,
        library: any LibraryModel,
        onRename: ((NotebookID, String) -> Void)? = nil,
        onDelete: ((NotebookID) -> Void)? = nil
    ) -> some View {
        modifier(LibraryPrompts(prompt: prompt, library: library, onRename: onRename, onDelete: onDelete))
    }
}

private struct LibraryPrompts: ViewModifier {
    @Binding var prompt: LibraryPrompt?
    let library: any LibraryModel
    let onRename: ((NotebookID, String) -> Void)?
    let onDelete: ((NotebookID) -> Void)?
    @State private var text = ""

    func body(content: Content) -> some View {
        let current = prompt
        content
            .alert(title(current), isPresented: isPresented) {
                switch current {
                case let .deleteNotebook(notebook):
                    Button("Cancel", role: .cancel) {}
                    Button("Delete", role: .destructive) { (onDelete ?? library.delete)(notebook.id) }
                case let .renameNotebook(notebook):
                    nameField("Title", confirm: "Rename") { (onRename ?? library.rename)(notebook.id, text) }
                case let .newFolder(parent):
                    nameField("Folder name", confirm: "Create") { library.createFolder(named: text, in: parent) }
                case let .renameFolder(folder):
                    nameField("Folder name", confirm: "Rename") { library.renameFolder(folder.id, to: text) }
                case nil:
                    EmptyView()
                }
            } message: {
                if case .deleteNotebook = current {
                    Text("It stays in the trash for 30 days.")
                }
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
        case nil: ""
        }
    }
}
