import CoreTransferable
import DesignSystem
import InkModel
import Library
import SwiftUI
import UniformTypeIdentifiers

/// Library sidebar (#117, mock B): All Notebooks, then the folder tree to any depth. An open folder lists its
/// subfolders, then its notebooks (a cover-coloured book; tap opens). Docked beside the covers in wide
/// windows, over them otherwise (``LibraryScreen``). Covers and notebook rows drop onto a folder row (or
/// All Notebooks, to unfile); hovering a closed folder springs it open. Settings sits at the foot (#228) and
/// shows in the detail area.
struct LibrarySidebar: View {
    let library: any LibraryModel
    @Binding var folder: FolderID?
    /// Settings shows in the detail area instead of the notebooks (#228).
    @Binding var showsSettings: Bool
    @Binding var expanded: Set<FolderID>
    @Binding var prompt: LibraryPrompt?
    let zoom: Namespace.ID
    /// Sideways room for the window controls when the sidebar hugs the window's top-leading corner.
    var leadingInset: CGFloat = 0
    let hide: () -> Void
    /// A row was picked (the overlay closes).
    let didPick: () -> Void
    let open: (EditorRoute) -> Void

    @State private var dropTarget: DropTarget?
    @State private var springOpen: Task<Void, Never>?

    private static let indent: CGFloat = 18
    private static let springDelay = Duration.milliseconds(700)

    var body: some View {
        let contents = Contents(library)
        VStack(alignment: .leading, spacing: 0) {
            topRow
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    allRow(count: library.notebooks.count)
                    Text("Folders")
                        .sectionLabelStyle()
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, Tokens.Spacing.m)
                        .padding(.top, Tokens.Spacing.xl)
                        .padding(.bottom, Tokens.Spacing.xs)
                    ForEach(rows(contents)) { row in
                        switch row {
                        case let .folder(item, depth): folderRow(item, depth: depth, contents: contents)
                        case let .notebook(notebook, depth): notebookRow(notebook, depth: depth)
                        }
                    }
                    newFolderRow
                }
                .padding(.horizontal, Tokens.Spacing.m)
                .padding(.bottom, Tokens.Spacing.xxl)
            }
            .scrollIndicators(.hidden)
            settingsRow
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background { Rectangle().fill(Tokens.Colors.librarySidebar).ignoresSafeArea() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("librarySidebar")
    }

    // MARK: Rows

    private var topRow: some View {
        HStack(spacing: Tokens.Spacing.s) {
            iconButton("Hide Sidebar", systemImage: "sidebar.leading", action: hide)
                .accessibilityIdentifier("hideSidebar")
            Spacer(minLength: 0)
            iconButton("New Folder", systemImage: "folder.badge.plus") { prompt = .newFolder(parent: nil) }
                .accessibilityIdentifier("newFolderIcon")
        }
        .padding(.leading, Tokens.Spacing.s + leadingInset)
        .padding(.trailing, Tokens.Spacing.s)
        .padding(.top, Tokens.Spacing.l)
        .padding(.bottom, Tokens.Spacing.s)
    }

    private func allRow(count: Int) -> some View {
        let selected = folder == nil && !showsSettings
        return row(depth: 0, selected: selected, target: .all) {
            Button {
                select(nil)
            } label: {
                label("All Notebooks", selected: selected, target: .all, count: count) {
                    Image(systemName: "books.vertical")
                }
            }
            .buttonStyle(.plain)
            .rowAccessibility("All Notebooks", count: count, selected: selected)
            .accessibilityIdentifier("folder-All Notebooks")
        }
        .dropsNotebooks(on: .all, target: $dropTarget) { library.move($0, to: nil) }
    }

    private func folderRow(_ item: LibraryFolder, depth: Int, contents: Contents) -> some View {
        let selected = folder == item.id && !showsSettings
        let isOpen = expanded.contains(item.id)
        let hasContents = contents.hasContents(item.id)
        let count = library.notebookCount(inSubtree: item.id)
        return row(depth: depth, selected: selected, target: .folder(item.id)) {
            // Beside the row's button, not on it: the row's activation point stays the row.
            Button {
                select(item.id)
            } label: {
                // An open folder lists what's in it.
                label(item.name, selected: selected, target: .folder(item.id), count: isOpen && hasContents ? nil : count) {
                    Image(systemName: selected ? "folder.fill" : "folder")
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("New Subfolder", systemImage: "folder.badge.plus") { prompt = .newFolder(parent: item.id) }
                Button("Rename Folder", systemImage: "pencil") { prompt = .renameFolder(item) }
                Divider()
                Button("Delete Folder", systemImage: "trash", role: .destructive) { prompt = .deleteFolder(item) }
            }
            .rowAccessibility(item.name, count: count, selected: selected)
            .accessibilityIdentifier("folder-\(item.name)")
        } disclosure: {
            if hasContents {
                disclosure(item.name, isOpen: isOpen) { toggle(item.id) }
            }
        }
        .dropsNotebooks(on: .folder(item.id), target: $dropTarget) { library.move($0, to: item.id) }
        .onChange(of: dropTarget == .folder(item.id)) { _, hovering in
            springOpen?.cancel()
            guard hovering, !isOpen, hasContents else { return }
            springOpen = Task {
                try? await Task.sleep(for: Self.springDelay)
                guard !Task.isCancelled else { return }
                _ = withAnimation(.snappy(duration: 0.25)) { expanded.insert(item.id) }
            }
        }
    }

    private func notebookRow(_ notebook: NotebookSummary, depth: Int) -> some View {
        row(depth: depth, selected: false, target: nil) {
            Button {
                open(EditorRoute(id: notebook.id, source: .sidebar))
            } label: {
                label(notebook.title, selected: false, target: nil, count: nil, secondary: true) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(notebook.cover.style.color)
                        .overlay(alignment: .leading) { Rectangle().fill(.black.opacity(0.14)).frame(width: 2) }
                        .clipShape(.rect(cornerRadius: 2.5, style: .continuous))
                        // Dark covers on the dark sidebar.
                        .overlay { RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(
                            Tokens.Colors.swatchHairline,
                            lineWidth: 0.5
                        ) }
                        .frame(width: 13, height: 17)
                        .matchedTransitionSource(id: EditorRoute.TransitionID(id: notebook.id, source: .sidebar), in: zoom)
                }
            }
            .buttonStyle(.plain)
            .draggable(NotebookReference.picking(notebook.id)) {
                NotebookCover(title: notebook.title, color: notebook.cover.style, width: 90)
            }
            .contextMenu { NotebookMenu(notebook: notebook, library: library, prompt: $prompt) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(notebook.title)
            .accessibilityHint("Opens the notebook")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("sidebarNotebook-\(notebook.title)")
        }
    }

    /// Pinned under the tree, a hairline above it.
    private var settingsRow: some View {
        row(depth: 0, selected: showsSettings, target: nil) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { showsSettings = true }
                didPick()
            } label: {
                label("Settings", selected: showsSettings, target: nil, count: nil) {
                    Image(systemName: Symbol.settings.name)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Settings")
            .accessibilityAddTraits(showsSettings ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("settingsRow")
        }
        .padding(.horizontal, Tokens.Spacing.m)
        .padding(.vertical, Tokens.Spacing.s)
        .overlay(alignment: .top) {
            Rectangle().fill(Tokens.Colors.separator).frame(height: 0.5)
        }
    }

    private var newFolderRow: some View {
        row(depth: 0, selected: false, target: nil) {
            Button {
                prompt = .newFolder(parent: nil)
            } label: {
                label("New Folder", selected: false, target: nil, count: nil, weight: .medium, secondary: true) {
                    Image(systemName: "plus")
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("newFolder")
        }
    }

    // MARK: Actions

    private func select(_ id: FolderID?) {
        withAnimation(.snappy(duration: 0.25)) {
            folder = id
            showsSettings = false
            if let id {
                expanded.insert(id)
            }
        }
        didPick()
    }

    private func toggle(_ id: FolderID) {
        withAnimation(.snappy(duration: 0.25)) {
            if expanded.remove(id) == nil {
                expanded.insert(id)
            }
        }
    }
}

extension LibrarySidebar {
    // MARK: Row parts

    private func disclosure(_ name: String, isOpen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(Tokens.Colors.textTertiary)
                .rotationEffect(.degrees(isOpen ? 0 : -90))
                .frame(width: Self.disclosureWidth, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen ? "Collapse \(name)" : "Expand \(name)")
        .accessibilityIdentifier("disclose-\(name)")
    }

    private static let disclosureWidth: CGFloat = 22

    /// A row: indent · disclosure slot · `content`, a soft fill when selected, tinted under a drag.
    private func row(
        depth: Int, selected: Bool, target: DropTarget?,
        @ViewBuilder content: () -> some View, @ViewBuilder disclosure: () -> some View = { EmptyView() }
    ) -> some View {
        let dropping = target != nil && dropTarget == target
        return HStack(spacing: 0) {
            ZStack { disclosure() }
                .frame(width: Self.disclosureWidth)
            content()
        }
        // Keeps the row's button its own element (its frame, its activation point), not the whole row.
        .accessibilityElement(children: .contain)
        .padding(.leading, CGFloat(depth) * Self.indent)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(dropping ? Tokens.Colors.dropTarget.color : selected ? Tokens.Colors.subtleFill.color : .clear)
            if dropping {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Tokens.Colors.selection.color.opacity(0.55), lineWidth: 1.5)
            }
        }
    }

    /// A row's button label: icon · name · count.
    private func label(
        _ name: String, selected: Bool, target: DropTarget?, count: Int?,
        weight: Font.Weight = .regular, secondary: Bool = false, @ViewBuilder icon: () -> some View
    ) -> some View {
        let dropping = target != nil && dropTarget == target
        return HStack(spacing: Tokens.Spacing.s) {
            icon()
                .scaledFont(size: 16, weight: .regular)
                .foregroundStyle(dropping ? Tokens.Colors.selection.color : selected ? Tokens.Colors.textPrimary.color : Tokens.Colors
                    .textSecondary.color)
                .frame(width: 24)
            Text(name)
                .scaledFont(size: 15, weight: selected ? .semibold : weight)
                .foregroundStyle(dropping ? Tokens.Colors.selection.color : secondary ? Tokens.Colors.textSecondary.color : Tokens.Colors
                    .textPrimary.color)
                .lineLimit(1)
            Spacer(minLength: Tokens.Spacing.s)
            if let count {
                Text("\(count)")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(Tokens.Colors.textTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.leading, Tokens.Spacing.s)
        .padding(.trailing, Tokens.Spacing.m)
        .frame(minHeight: 40)
        .contentShape(.rect)
    }

    private func iconButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .scaledFont(size: 17, weight: .medium)
                .foregroundStyle(Tokens.Colors.pillText)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private extension View {
    /// Drops dragged notebooks here, tracking which row is under the drag.
    func dropsNotebooks(on row: DropTarget, target: Binding<DropTarget?>, move: @escaping (NotebookID) -> Void) -> some View {
        dropDestination(for: NotebookReference.self) { items, _ in
            for item in items {
                move(item.id)
            }
            target.wrappedValue = nil
            return !items.isEmpty
        } isTargeted: { hovering in
            if hovering {
                target.wrappedValue = row
            } else if target.wrappedValue == row {
                target.wrappedValue = nil
            }
        }
    }

    func rowAccessibility(_ name: String, count: Int, selected: Bool) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityValue(EditedLabel.notebooks(count))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
