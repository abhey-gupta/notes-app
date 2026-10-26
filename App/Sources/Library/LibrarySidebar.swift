import DesignSystem
import InkModel
import Library
import SwiftUI

/// Library sidebar (#117): All Notebooks + the folder tree. Rows take dropped covers (move to that folder).
struct LibrarySidebar: View {
    let library: any LibraryModel
    /// Shown folder; `nil` = All Notebooks.
    @Binding var selection: FolderID?
    @Binding var prompt: LibraryPrompt?
    /// Called after a row is tapped (the overlay sidebar closes).
    var didSelect: () -> Void = {}

    @State private var expanded: Set<FolderID> = []
    @State private var dropTarget: FolderID??

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                row(SidebarRow.Item(id: nil, name: "All Notebooks", symbol: .allNotebooks, notebooks: library.notebooks.count))
                foldersHeader
                ForEach(visibleFolders, id: \.folder.id) { entry in
                    let folder = entry.folder
                    row(SidebarRow.Item(
                        id: folder.id, name: folder.name, symbol: .folder,
                        notebooks: library.notebooks.count { $0.folderID == folder.id },
                        depth: entry.depth, hasChildren: !library.folders.children(of: folder.id).isEmpty
                    ))
                    .contextMenu { folderMenu(folder) }
                }
            }
            .padding(.horizontal, Tokens.Spacing.m)
            .padding(.vertical, Tokens.Spacing.l)
        }
        .scrollIndicators(.hidden)
        .onAppear { reveal(selection) }
        .onChange(of: selection) { _, id in reveal(id) }
    }

    private var foldersHeader: some View {
        HStack {
            Text("Folders")
                .sectionLabelStyle()
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("New Folder", systemImage: Symbol.add.name) { prompt = .newFolder(parent: nil) }
                .labelStyle(.iconOnly)
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
                .buttonStyle(.plain)
                .accessibilityIdentifier("newFolder")
        }
        .padding(.leading, Tokens.Spacing.m)
        .padding(.top, Tokens.Spacing.xl)
    }

    // MARK: Rows

    private func row(_ item: SidebarRow.Item) -> some View {
        let id = item.id
        return SidebarRow(
            item: item,
            isSelected: selection == id,
            isOpen: id.map(expanded.contains) ?? false,
            isDropTarget: dropTarget == .some(id),
            toggle: {
                if let id {
                    withAnimation(.snappy(duration: 0.25)) { toggle(id) }
                }
            },
            select: {
                selection = id
                didSelect()
            }
        )
        .animation(.snappy(duration: 0.2), value: dropTarget)
        .dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap { NotebookID(uuidString: $0) }.filter { library.notebook(id: $0) != nil }
            for notebook in ids {
                library.move(notebook, to: id)
            }
            return !ids.isEmpty
        } isTargeted: { targeted in
            if targeted {
                dropTarget = .some(id)
            } else if dropTarget == .some(id) {
                dropTarget = nil
            }
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: LibraryFolder) -> some View {
        Button("New Subfolder", systemImage: "folder.badge.plus") { prompt = .newFolder(parent: folder.id) }
        Button("Rename Folder", systemImage: "pencil") { prompt = .renameFolder(folder) }
        Button("Delete Folder", systemImage: "trash", role: .destructive) {
            if let selection, library.folders.subtree(of: folder.id).contains(selection) {
                self.selection = selection == folder.id ? folder.parentID : selection
            }
            library.deleteFolder(folder.id)
        }
    }

    // MARK: Tree

    /// Depth-first, children only under expanded folders.
    private var visibleFolders: [(folder: LibraryFolder, depth: Int)] {
        var rows: [(folder: LibraryFolder, depth: Int)] = []
        func add(_ parent: FolderID?, depth: Int) {
            for folder in library.folders.children(of: parent) {
                rows.append((folder, depth))
                if expanded.contains(folder.id) {
                    add(folder.id, depth: depth + 1)
                }
            }
        }
        add(nil, depth: 0)
        return rows
    }

    private func toggle(_ id: FolderID) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    /// Opens the folders above `id` so the selected row is visible.
    private func reveal(_ id: FolderID?) {
        guard let id else { return }
        expanded.formUnion(library.folders.path(to: id).dropLast().map(\.id))
    }
}

/// One sidebar row: disclosure (its own target, so expanding doesn't select), glyph, name, count.
private struct SidebarRow: View {
    struct Item {
        let id: FolderID?
        let name: String
        let symbol: Symbol
        let notebooks: Int
        var depth = 0
        var hasChildren = false
    }

    let item: Item
    let isSelected: Bool
    let isOpen: Bool
    let isDropTarget: Bool
    let toggle: () -> Void
    let select: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            disclosure
            Button(action: select) {
                HStack(spacing: Tokens.Spacing.m) {
                    Image(systemName: item.symbol.name)
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(item.id == nil ? Tokens.Colors.icon : Tokens.Colors.folder)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    Text(item.name)
                        .scaledFont(size: 15, weight: isSelected ? .semibold : .medium)
                        .foregroundStyle(isSelected ? Tokens.Colors.textPrimary : Tokens.Colors.icon)
                        .lineLimit(1)
                    Spacer(minLength: Tokens.Spacing.s)
                    if item.notebooks > 0 {
                        Text("\(item.notebooks)")
                            .font(.meta.monospacedDigit())
                            .foregroundStyle(Tokens.Colors.textSecondary)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier(item.id == nil ? "sidebar-all" : "sidebar-\(item.name)")
            .accessibilityValue(item.notebooks == 1 ? "1 notebook" : "\(item.notebooks) notebooks")
        }
        .padding(.leading, CGFloat(item.depth) * Tokens.Spacing.sidebarIndent)
        .padding(.trailing, Tokens.Spacing.m)
        .background {
            if isSelected || isDropTarget {
                RoundedRectangle(cornerRadius: Tokens.Radius.segmented, style: .continuous)
                    .fill(Tokens.Colors.subtleFill)
            }
        }
    }

    @ViewBuilder
    private var disclosure: some View {
        if item.hasChildren {
            Button(isOpen ? "Collapse" : "Expand", systemImage: Symbol.expand.name, action: toggle)
                .labelStyle(.iconOnly)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(Tokens.Colors.textTertiary)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .frame(width: 24, height: 44)
                .contentShape(.rect)
                .buttonStyle(.plain)
        } else {
            Color.clear.frame(width: item.id == nil ? 4 : 24)
        }
    }
}

/// Compact library (#118): the sidebar's tree as a full-screen sheet. Picking a row closes it; ✕ closes it too.
/// Settings lives here, since the compact header has no room for it.
struct FoldersSheet: View {
    let library: any LibraryModel
    @Binding var selection: FolderID?
    let showsGallery: Binding<Bool>?
    let close: () -> Void

    @State private var prompt: LibraryPrompt?
    @State private var showsSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Tokens.Spacing.m) {
                Text("Folders")
                    .font(.libraryTitle)
                    .tracking(-0.5)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Tokens.Spacing.m)
                GlassChrome(spacing: Tokens.Spacing.s) {
                    HStack(spacing: Tokens.Spacing.m) {
                        GlassCircleButton(symbol: Symbol.settings.name, label: "Settings") { showsSettings = true }
                            .popover(isPresented: $showsSettings) {
                                SettingsView(showsGallery: showsGallery)
                                    .presentationCompactAdaptation(.popover)
                            }
                        GlassCircleButton(symbol: "xmark", label: "Close", action: close)
                            .accessibilityIdentifier("closeFolders")
                    }
                }
            }
            .padding(.horizontal, CompactLayout.libraryMargin)
            .padding(.top, Tokens.Spacing.l)
            LibrarySidebar(library: library, selection: $selection, prompt: $prompt, didSelect: close)
        }
        .background { Rectangle().fill(Tokens.Colors.libraryBackground).ignoresSafeArea() }
        .libraryPrompts($prompt, library: library)
    }
}
