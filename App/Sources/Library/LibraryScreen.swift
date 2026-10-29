import DesignSystem
import Library
import os
import SwiftUI

/// Library (mock §01): serif title, glass search/settings/New, "Continue" recents, covers grid; folders in a
/// sidebar tree (#117, ``LibrarySidebar``). The sidebar docks beside the covers in wide windows (hide/show,
/// remembered) and slides over them otherwise. A folder shows its own notebooks; Continue only shows on All.
///
/// Compact chrome (#118: iPhone, iPad windows under 600 pt): sidebar · search · + on top, the serif title
/// scrolling with the content, one Continue card at a time, three columns of covers.
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
    @State private var width: CGFloat = 0
    @State private var screenWidth: CGFloat = 0
    /// Narrow windows: the sidebar is over the covers.
    @State private var showsOverlay = false
    /// Persisted, but @State: an @AppStorage write drops the `withAnimation` transaction, so the sidebar popped.
    @State private var sidebarHidden = UserDefaults.standard.bool(forKey: Self.sidebarHiddenKey)
    /// Open folders, as space-separated UUIDs.
    @AppStorage(Self.openFoldersKey) private var openFolders = ""

    static let sidebarHiddenKey = "librarySidebarHidden"
    static let openFoldersKey = "libraryOpenFolders"
    @Environment(\.chromeLayout) private var chrome

    /// The sidebar docks from this width (11" landscape is 1194 pt; portrait 834 gets the overlay).
    private static let dockWidth: CGFloat = 1000

    private var margin: CGFloat {
        chrome.margin
    }

    private var isCompact: Bool {
        chrome.isCompact
    }

    private var docks: Bool {
        !isCompact && screenWidth >= Self.dockWidth
    }

    private var showsDockedSidebar: Bool {
        docks && !sidebarHidden
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsDockedSidebar {
                sidebar(leadingInset: chrome.windowControls.leading)
                    .frame(width: Tokens.Size.sidebarWidth)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Tokens.Colors.separator).frame(width: 0.5).ignoresSafeArea()
                    }
                    .transition(.move(edge: .leading))
            }
            content
        }
        .overlay { overlaySidebar }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { screenWidth = $0 }
        .onChange(of: docks) { showsOverlay = false }
        .onChange(of: library.folders) { old, new in
            // The folder showing was deleted (with a parent, perhaps).
            if library.folder(id: folder) == nil {
                folder = nil
            }
            // A new subfolder shows: its parent opens.
            let known = Set(old.map(\.id))
            let parents = new.filter { !known.contains($0.id) }.compactMap(\.parentID)
            if !parents.isEmpty {
                expanded.wrappedValue.formUnion(parents)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showsNewNotebook) {
            NewNotebookSheet(folder: library.folder(id: folder)) { draft in
                create(draft)
            }
        }
        .libraryPrompts($prompt, library: library)
    }

    private var content: some View {
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
                if query.isEmpty, folder == nil, !library.recents.isEmpty {
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
        .safeAreaBar(edge: .top) { header }
    }

    private var header: some View {
        LibraryHeader(
            query: $query, showsNewNotebook: $showsNewNotebook, pdfImport: $pdfImport,
            title: library.folder(id: folder)?.name ?? "Library", ancestors: ancestors,
            showSidebar: showsDockedSidebar ? nil : { showSidebar() }, pickFolder: { pick($0) },
            hugsLeadingEdge: !showsDockedSidebar, showsGallery: showsGallery
        )
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
            regularHeader
        }
    }

    private var regularHeader: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Text(folder == nil ? "All Notebooks" : "Notebooks")
                .sectionLabelStyle()
                .accessibilityAddTraits(.isHeader)
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
                Text(emptyText)
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
                    .draggable(NotebookReference(id: notebook.id)) {
                        NotebookCover(title: notebook.title, color: notebook.cover.style, width: 110)
                    }
                    .contextMenu { NotebookMenu(notebook: notebook, library: library, prompt: $prompt) }
                }
            }
        }
    }
}

extension LibraryScreen {
    // MARK: Sidebar

    private func sidebar(leadingInset: CGFloat) -> some View {
        LibrarySidebar(
            library: library, folder: $folder, expanded: expanded, prompt: $prompt, zoom: zoom, leadingInset: leadingInset,
            hide: hideSidebar, didPick: closeOverlay, open: open
        )
    }

    /// A pick in the overlay closes it; the docked sidebar stays.
    private func closeOverlay() {
        if !docks {
            hideSidebar()
        }
    }

    /// The container stays; scrim and sidebar come and go inside it, so each gets its own transition.
    private var overlaySidebar: some View {
        ZStack(alignment: .leading) {
            if !docks, showsOverlay {
                Rectangle()
                    .fill(.black.opacity(0.18))
                    .ignoresSafeArea()
                    .onTapGesture(perform: hideSidebar)
                    .accessibilityLabel("Close Sidebar")
                    .accessibilityAddTraits(.isButton)
                    .transition(.opacity)
            }
            if !docks, showsOverlay {
                sidebar(leadingInset: chrome.windowControls.leading)
                    .frame(width: min(Tokens.Size.sidebarWidth, screenWidth - 56))
                    .background {
                        Rectangle()
                            .fill(Tokens.Colors.librarySidebar)
                            .shadow(color: .black.opacity(0.18), radius: 24, x: 8)
                            .ignoresSafeArea()
                    }
                    .transition(.move(edge: .leading))
            }
        }
        // Empty, it takes no touches; mid-transition, the sidebar stays on the leading edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func showSidebar() {
        withAnimation(Tokens.Motion.dock) {
            if docks {
                sidebarHidden = false
                UserDefaults.standard.set(false, forKey: Self.sidebarHiddenKey)
            } else {
                showsOverlay = true
            }
        }
    }

    private func hideSidebar() {
        withAnimation(Tokens.Motion.dock) {
            if docks {
                sidebarHidden = true
                UserDefaults.standard.set(true, forKey: Self.sidebarHiddenKey)
            } else {
                showsOverlay = false
            }
        }
    }

    private func pick(_ id: FolderID?) {
        withAnimation(.snappy(duration: 0.25)) { folder = id }
    }

    private var ancestors: [LibraryFolder] {
        guard let folder else { return [] }
        return Array(library.folders.path(to: folder).dropLast())
    }

    private var expanded: Binding<Set<FolderID>> {
        Binding {
            Set(openFolders.split(separator: " ").compactMap { UUID(uuidString: String($0)).map(FolderID.init(uuid:)) })
        } set: {
            openFolders = $0.map(\.uuid.uuidString).sorted().joined(separator: " ")
        }
    }

    // MARK: Grid

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

    private var emptyText: String {
        if !query.isEmpty {
            return "No notebooks match “\(query)”."
        }
        if let name = library.folder(id: folder)?.name {
            return "No notebooks in “\(name)” yet."
        }
        return "No notebooks yet. Tap New to start one."
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
