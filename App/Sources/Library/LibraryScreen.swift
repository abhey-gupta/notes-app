import DesignSystem
import Library
import os
import SwiftUI

/// Library (mock §01): serif title, glass search/settings/New, "Continue" recents, folder chips, covers grid.
///
/// Compact chrome (#118: iPhone, iPad windows under 600 pt): sidebar · search · + on top, the serif title
/// scrolling with the content, one Continue card at a time, three columns of covers; folders open full screen
/// from the sidebar button (``FoldersSheet``) instead of chips.
struct LibraryScreen: View {
    let library: any LibraryModel
    let zoom: Namespace.ID
    /// Open editor tabs (#191): their notebooks say "Open".
    let tabs: TabsModel
    @Binding var showsNewNotebook: Bool
    /// A PDF waiting in the import sheet: picked here, or opened in Notespace from Files / the share sheet.
    @Binding var pdfImport: PDFImportRequest?
    /// DEBUG: DesignSystem gallery toggle, surfaced in Settings.
    let showsGallery: Binding<Bool>?
    let open: (EditorRoute) -> Void

    @State private var query = ""
    @State private var folder: LibraryFolder.ID?
    @State private var sort = LibrarySort.recent
    @State private var isCreating = false
    @State private var prompt: LibraryPrompt?
    @State private var showsFolders = false
    @State private var width: CGFloat = 0
    @Namespace private var chipSelection
    @Environment(\.chromeLayout) private var chrome

    private var margin: CGFloat {
        chrome.margin
    }

    private var isCompact: Bool {
        chrome.isCompact
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isCompact {
                    Text("Library")
                        .font(.libraryTitle)
                        .tracking(-0.5)
                        .foregroundStyle(Tokens.Colors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, margin)
                        .padding(.bottom, Tokens.Spacing.xxl)
                }
                if query.isEmpty, !library.recents.isEmpty {
                    Text("Continue")
                        .sectionLabelStyle()
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, margin)
                    recents
                        .padding(.top, Tokens.Spacing.l)
                        .padding(.bottom, 40)
                }
                notebooksHeader
                    .padding(.horizontal, margin)
                coversGrid
                    .padding(.horizontal, margin)
                    .padding(.top, isCompact ? Tokens.Spacing.xl : 26)
            }
            .padding(.top, isCompact ? Tokens.Spacing.s : 22)
            .padding(.bottom, 60)
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .scrollDismissesKeyboard(.immediately)
        // One presentation per view: the import sheet sits on the scroll view, the new-notebook sheet on the screen.
        .pdfImport($pdfImport, folder: folder, library: library) { notebook in
            query = ""
            open(EditorRoute(id: notebook.id, source: .cover))
        }
        .background { Rectangle().fill(Tokens.Colors.libraryBackground).ignoresSafeArea() }
        .safeAreaBar(edge: .top) {
            LibraryHeader(
                query: $query, showsNewNotebook: $showsNewNotebook, pdfImport: $pdfImport,
                showsFolders: $showsFolders, showsGallery: showsGallery
            )
        }
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $showsFolders) {
            FoldersSheet(library: library, folder: $folder)
        }
        .sheet(isPresented: $showsNewNotebook) {
            NewNotebookSheet(folder: library.folder(id: folder)) { draft in
                create(draft)
            }
        }
        .libraryPrompts($prompt, library: library)
    }

    // MARK: Continue

    private var recents: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: recentSpacing) {
                ForEach(library.recents) { notebook in
                    RecentCard(notebook: notebook, zoom: zoom, isOpen: tabs.openIDs.contains(notebook.id)) {
                        open(EditorRoute(id: notebook.id, source: .recent))
                    }
                    .contextMenu { NotebookMenu(notebook: notebook, library: library, prompt: $prompt) }
                    .containerRelativeFrame(.horizontal, count: isCompact ? 1 : 3, spacing: recentSpacing)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, margin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private var recentSpacing: CGFloat {
        isCompact ? Tokens.Spacing.l : 31
    }

    // MARK: Notebooks

    @ViewBuilder
    private var notebooksHeader: some View {
        if isCompact {
            HStack(spacing: Tokens.Spacing.s) {
                Text(library.folder(id: folder)?.name ?? "All Notebooks")
                    .sectionLabelStyle()
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Tokens.Spacing.m)
                sortMenu
            }
        } else {
            chipsHeader
        }
    }

    private var chipsHeader: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Text("Notebooks")
                .sectionLabelStyle()
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
                .padding(.trailing, Tokens.Spacing.l)
            chip("All", id: nil)
            ForEach(library.folders) { folder in
                chip(folder.name, id: folder.id)
                    .contextMenu {
                        Button("Rename Folder", systemImage: "pencil") { prompt = .renameFolder(folder) }
                        Button("Delete Folder", systemImage: "trash", role: .destructive) {
                            if self.folder == folder.id {
                                self.folder = nil
                            }
                            library.deleteFolder(folder.id)
                        }
                    }
            }
            Button {
                prompt = .newFolder
            } label: {
                Text("+ Folder")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(Tokens.Colors.textTertiary)
                    .padding(.horizontal, Tokens.Spacing.l)
                    .padding(.vertical, 7)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("newFolder")
            Spacer(minLength: Tokens.Spacing.m)
            sortMenu
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                Text("Recent").tag(LibrarySort.recent)
                Text("Title").tag(LibrarySort.title)
                Text("Created").tag(LibrarySort.created)
            }
        } label: {
            HStack(spacing: 4) {
                Text("Sorted by \(sort.rawValue)")
                Image(systemName: Symbol.disclosure.name)
                    .scaledFont(size: 10, weight: .semibold)
            }
            .scaledFont(size: 13, weight: .medium)
            .foregroundStyle(Tokens.Colors.textSecondary)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var coversGrid: some View {
        let notebooks = shownNotebooks
        if notebooks.isEmpty {
            // Hidden while a slow index load/rebuild is still running: never flash "No notebooks yet".
            if library.isLoaded {
                Text(query.isEmpty ? "No notebooks yet. Tap New to start one." : "No notebooks match “\(query)”.")
                    .scaledFont(size: 15)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Tokens.Spacing.xxxl)
            }
        } else {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: isCompact ? Tokens.Spacing.xxl : 30) {
                ForEach(notebooks) { notebook in
                    CoverTile(
                        notebook: notebook, folder: library.folder(id: notebook.folderID)?.name, zoom: zoom, width: coverWidth,
                        isOpen: tabs.openIDs.contains(notebook.id)
                    ) {
                        open(EditorRoute(id: notebook.id, source: .cover))
                    }
                    .contextMenu { NotebookMenu(notebook: notebook, library: library, prompt: $prompt) }
                }
            }
        }
    }
}

extension LibraryScreen {
    // MARK: Folders

    private func chip(_ name: String, id: FolderID?) -> some View {
        let selected = folder == id
        return Button {
            withAnimation(.snappy(duration: 0.25)) { folder = id }
        } label: {
            Text(name)
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(selected ? Tokens.Colors.libraryBackground : Tokens.Colors.chipText)
                .padding(.horizontal, Tokens.Spacing.l)
                .padding(.vertical, 7)
                .background {
                    if selected {
                        Capsule()
                            .fill(Tokens.Colors.textPrimary)
                            .matchedGeometryEffect(id: "chip", in: chipSelection)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Compact: three covers across, sized to the window. Regular: as many 150 pt covers as fit.
    private static let compactColumns = 3
    private static let compactGap = Tokens.Spacing.l

    private var gridColumns: [GridItem] {
        if isCompact {
            return Array(repeating: GridItem(.flexible(), spacing: Self.compactGap, alignment: .topLeading), count: Self.compactColumns)
        }
        return [GridItem(.adaptive(minimum: Tokens.Size.cover.width, maximum: Tokens.Size.cover.width), spacing: 39, alignment: .leading)]
    }

    private var coverWidth: CGFloat {
        guard isCompact, width > 0 else { return Tokens.Size.cover.width }
        let columns = CGFloat(Self.compactColumns)
        return min(((width - 2 * margin - (columns - 1) * Self.compactGap) / columns).rounded(.down), Tokens.Size.cover.width)
    }

    private var shownNotebooks: [NotebookSummary] {
        let notebooks = library.notebooks(in: folder, matching: query)
        return sort == .recent ? notebooks : notebooks.sorted(by: sort)
    }

    /// Package + index entry first, then the editor: no interim library state (§8).
    private func create(_ draft: NotebookDraft) {
        guard !isCreating else { return }
        isCreating = true
        OpenTrace.beginCreate()
        Task {
            defer { isCreating = false }
            do {
                let notebook = try await library.createNotebook(draft)
                showsNewNotebook = false
                query = ""
                open(EditorRoute(id: notebook.id, source: .cover))
            } catch {
                OpenTrace.cancel()
                Logger(subsystem: "com.abhey.notespace", category: "library")
                    .error("create: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

#Preview("Library") {
    @Previewable @Namespace var zoom
    @Previewable @State var showsNew = false
    @Previewable @State var pdfImport: PDFImportRequest?
    LibraryScreen(
        library: SampleLibrary(), zoom: zoom, tabs: TabsModel(), showsNewNotebook: $showsNew, pdfImport: $pdfImport, showsGallery: nil
    ) { _ in }
}
