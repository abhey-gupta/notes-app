import DesignSystem
import Library
import os
import SwiftUI
import UniformTypeIdentifiers

/// Library (mock §01): folder sidebar (#117), serif title, glass search/settings/New, "Continue" recents, covers grid.
/// Compact chrome (#118): sidebar · search · + on top, the title under them, one Continue card, three columns of
/// covers; the sidebar becomes a full-screen Folders sheet.
struct LibraryScreen: View {
    let library: any LibraryModel
    let zoom: Namespace.ID
    @Binding var showsNewNotebook: Bool
    /// A PDF waiting in the import sheet: picked here, or opened in Notespace from Files / the share sheet.
    @Binding var pdfImport: PDFImportRequest?
    /// DEBUG: DesignSystem gallery toggle, surfaced in Settings.
    let showsGallery: Binding<Bool>?
    let open: (EditorRoute) -> Void

    @State private var query = ""
    /// Shown folder; `nil` = All Notebooks.
    @State private var folder: LibraryFolder.ID?
    @State private var sort = LibrarySort.recent
    @State private var showsSettings = false
    @State private var isCreating = false
    @State private var showsPDFPicker = false
    @State private var prompt: LibraryPrompt?
    /// Wide window: the sidebar sits beside the covers (user can hide it); narrow: it overlays on demand.
    @State private var isDocked = true
    @State private var showsDockedSidebar = true
    @State private var showsOverlaySidebar = false
    @State private var showsFolders = false
    /// Compact covers grid width: three columns fill it.
    @State private var gridWidth: CGFloat = 0
    @Environment(\.isCompactLayout) private var isCompactLayout

    private var margin: CGFloat {
        isCompactLayout ? CompactLayout.libraryMargin : Tokens.Spacing.libraryMargin
    }

    var body: some View {
        HStack(spacing: 0) {
            if isDocked, showsDockedSidebar, !isCompactLayout {
                sidebar
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            content
                // One presentation per view: the import sheet sits on the content, the new-notebook sheet on the screen.
                .pdfImport($pdfImport, folder: folder, library: library) { notebook in
                    query = ""
                    open(EditorRoute(id: notebook.id, source: .cover))
                }
        }
        .overlay(alignment: .leading) {
            if !isDocked, showsOverlaySidebar, !isCompactLayout {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .onTapGesture { setSidebar(visible: false) }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                sidebar
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .background { Rectangle().fill(Tokens.Colors.libraryBackground).ignoresSafeArea() }
        .onGeometryChange(for: Bool.self) { $0.size.width >= Tokens.Size.sidebarDockWidth } action: { docked in
            isDocked = docked
            showsOverlaySidebar = false
        }
        .onChange(of: library.folders) { _, folders in
            if let folder, !folders.contains(where: { $0.id == folder }) {
                self.folder = nil
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showsNewNotebook) {
            NewNotebookSheet(folder: library.folder(id: folder)) { draft in
                create(draft)
            }
        }
        .fullScreenCover(isPresented: $showsFolders) {
            FoldersSheet(library: library, selection: $folder, showsGallery: showsGallery) {
                query = ""
                showsFolders = false
            }
        }
        .libraryPrompts($prompt, library: library)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if folder == nil, query.isEmpty, !library.recents.isEmpty {
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
                    .padding(.top, 26)
            }
            .padding(.top, 22)
            .padding(.bottom, 60)
        }
        .scrollDismissesKeyboard(.immediately)
        .safeAreaBar(edge: .top) { header }
    }

    private var sidebar: some View {
        LibrarySidebar(library: library, selection: $folder, prompt: $prompt) {
            query = ""
            if !isDocked {
                setSidebar(visible: false)
            }
        }
        .frame(width: Tokens.Size.sidebarWidth)
        .glassEffect(.regular, in: .rect(cornerRadius: Tokens.Radius.capsule))
        .padding(Tokens.Spacing.sidebarInset)
    }

    private func setSidebar(visible: Bool) {
        if isCompactLayout {
            showsFolders = visible
            return
        }
        withAnimation(.snappy(duration: 0.3)) {
            if isDocked {
                showsDockedSidebar = visible
            } else {
                showsOverlaySidebar = visible
            }
        }
    }

    // MARK: Continue

    private var recents: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: recentSpacing) {
                ForEach(library.recents) { notebook in
                    RecentCard(notebook: notebook, zoom: zoom) {
                        open(EditorRoute(id: notebook.id, source: .recent))
                    }
                    .contextMenu { NotebookMenu(notebook: notebook, library: library, prompt: $prompt) }
                    .draggable(notebook.id.description) { NotebookCover(title: notebook.title, color: notebook.cover.style) }
                    .containerRelativeFrame(.horizontal, count: isCompactLayout ? 1 : 3, spacing: recentSpacing)
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
        isCompactLayout ? CompactLayout.coverSpacing : 31
    }

    // MARK: Notebooks

    private var notebooksHeader: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Text("Notebooks")
                .sectionLabelStyle()
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Tokens.Spacing.m)
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
    }

    @ViewBuilder
    private var coversGrid: some View {
        let notebooks = shownNotebooks
        if notebooks.isEmpty {
            // Hidden while a slow index load/rebuild is still running: never flash "No notebooks yet".
            if library.isLoaded {
                Text(emptyMessage)
                    .scaledFont(size: 15)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Tokens.Spacing.xxxl)
            }
        } else {
            LazyVGrid(columns: coverColumns, alignment: .leading, spacing: isCompactLayout ? 24 : 30) {
                ForEach(notebooks) { notebook in
                    CoverTile(
                        notebook: notebook,
                        folder: folder == nil || !query.isEmpty ? library.folder(id: notebook.folderID)?.name : nil,
                        zoom: zoom,
                        width: coverWidth
                    ) {
                        open(EditorRoute(id: notebook.id, source: .cover))
                    }
                    .contextMenu { NotebookMenu(notebook: notebook, library: library, prompt: $prompt) }
                    .draggable(notebook.id.description) { NotebookCover(title: notebook.title, color: notebook.cover.style) }
                }
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { gridWidth = $0 }
        }
    }

    /// Wide: as many fixed-width covers as fit. Compact: three that share the width.
    private var coverColumns: [GridItem] {
        if isCompactLayout {
            let column = GridItem(.flexible(), spacing: CompactLayout.coverSpacing, alignment: .topLeading)
            return Array(repeating: column, count: CompactLayout.coverColumns)
        }
        return [GridItem(
            .adaptive(minimum: Tokens.Size.cover.width, maximum: Tokens.Size.cover.width),
            spacing: 39,
            alignment: .leading
        )]
    }

    private var coverWidth: CGFloat {
        guard isCompactLayout, gridWidth > 0 else { return Tokens.Size.cover.width }
        let columns = CGFloat(CompactLayout.coverColumns)
        return min((gridWidth - CompactLayout.coverSpacing * (columns - 1)) / columns, Tokens.Size.cover.width)
    }
}

extension LibraryScreen {
    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if isCompactLayout {
            compactHeader
        } else {
            wideHeader
        }
    }

    private var wideHeader: some View {
        HStack(spacing: Tokens.Spacing.m) {
            sidebarButton
            title
            Spacer(minLength: Tokens.Spacing.xxl)
            GlassChrome(spacing: Tokens.Spacing.s) {
                HStack(spacing: Tokens.Spacing.m) {
                    LibrarySearchField(query: $query)
                    settingsButton
                }
            }
            // Outside the glass container: its menu morphs out of the pill, and inside the container
            // the pill's glass kept taps from the menu's first row.
            newButton
        }
        .padding(.leading, margin - 4)
        .padding(.trailing, margin - 4)
        .padding(.top, Tokens.Spacing.l)
        .padding(.bottom, Tokens.Spacing.s)
    }

    /// Sidebar · search · + in glass, the title below.
    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(spacing: Tokens.Spacing.m) {
                GlassChrome(spacing: Tokens.Spacing.s) {
                    HStack(spacing: Tokens.Spacing.m) {
                        sidebarButton
                        LibrarySearchField(query: $query)
                    }
                }
                newButton
            }
            title
                .padding(.leading, 4)
        }
        .padding(.horizontal, margin - 4)
        .padding(.top, Tokens.Spacing.s)
        .padding(.bottom, Tokens.Spacing.s)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumb
            Text(library.folder(id: folder)?.name ?? "Library")
                .font(.libraryTitle)
                .tracking(-0.5)
                .foregroundStyle(Tokens.Colors.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var sidebarButton: some View {
        let visible = isCompactLayout ? showsFolders : isDocked ? showsDockedSidebar : showsOverlaySidebar
        return GlassCircleButton(
            symbol: Symbol.sidebar.name,
            label: isCompactLayout ? "Folders" : visible ? "Hide Sidebar" : "Show Sidebar"
        ) {
            setSidebar(visible: !visible)
        }
        .accessibilityIdentifier("sidebarToggle")
    }

    /// Enclosing folders of a nested folder, each tappable.
    @ViewBuilder
    private var breadcrumb: some View {
        let ancestors = folder.map { library.folders.path(to: $0).dropLast() } ?? []
        if !ancestors.isEmpty {
            HStack(spacing: Tokens.Spacing.xs) {
                ForEach(ancestors) { ancestor in
                    Button(ancestor.name) { folder = ancestor.id }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("crumb-\(ancestor.name)")
                    Image(systemName: Symbol.expand.name)
                        .scaledFont(size: 10, weight: .semibold)
                        .accessibilityHidden(true)
                }
            }
            .scaledFont(size: 14, weight: .medium)
            .foregroundStyle(Tokens.Colors.textSecondary)
            .lineLimit(1)
        }
    }

    private var settingsButton: some View {
        GlassCircleButton(symbol: Symbol.settings.name, label: "Settings") { showsSettings = true }
            .popover(isPresented: $showsSettings) {
                SettingsView(showsGallery: showsGallery)
            }
    }

    /// "+" menu: New Notebook, Import PDF… (#119, the Files picker feeds the import sheet).
    private var newButton: some View {
        NewNotebookButton { showsNewNotebook = true } onImportPDF: { showsPDFPicker = true }
            .fileImporter(isPresented: $showsPDFPicker, allowedContentTypes: [.pdf]) { result in
                pdfImport = PDFInbox.stage(result)
            }
    }

    /// Search spans the whole library; otherwise the selected folder's own notebooks.
    private var shownNotebooks: [NotebookSummary] {
        let notebooks = query.isEmpty ? library.notebooks(in: folder, matching: "") : library.notebooks(in: nil, matching: query)
        return sort == .recent ? notebooks : notebooks.sorted(by: sort)
    }

    private var emptyMessage: String {
        if !query.isEmpty {
            return "No notebooks match “\(query)”."
        }
        return folder == nil ? "No notebooks yet. Tap New to start one." : "No notebooks here yet. Tap New, or drag one onto this folder."
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
    LibraryScreen(library: SampleLibrary(), zoom: zoom, showsNewNotebook: $showsNew, pdfImport: $pdfImport, showsGallery: nil) { _ in }
}
