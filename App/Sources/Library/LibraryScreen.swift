import DesignSystem
import Library
import os
import SwiftUI

/// Library (mock §01): folder sidebar (#117), serif title, glass search/settings/New, "Continue" recents, covers grid.
struct LibraryScreen: View {
    let library: any LibraryModel
    let zoom: Namespace.ID
    @Binding var showsNewNotebook: Bool
    /// DEBUG: DesignSystem gallery toggle, surfaced in Settings.
    let showsGallery: Binding<Bool>?
    let open: (EditorRoute) -> Void

    @State private var query = ""
    /// Shown folder; `nil` = All Notebooks.
    @State private var folder: LibraryFolder.ID?
    @State private var sort = LibrarySort.recent
    @State private var showsSettings = false
    @State private var isCreating = false
    @State private var prompt: LibraryPrompt?
    /// Wide window: the sidebar sits beside the covers (user can hide it); narrow: it overlays on demand.
    @State private var isDocked = true
    @State private var showsDockedSidebar = true
    @State private var showsOverlaySidebar = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private let margin = Tokens.Spacing.libraryMargin

    var body: some View {
        HStack(spacing: 0) {
            if isDocked, showsDockedSidebar {
                sidebar
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            content
        }
        .overlay(alignment: .leading) {
            if !isDocked, showsOverlaySidebar {
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
            LazyHStack(alignment: .top, spacing: 31) {
                ForEach(library.recents) { notebook in
                    RecentCard(notebook: notebook, zoom: zoom) {
                        open(EditorRoute(id: notebook.id, source: .recent))
                    }
                    .contextMenu { NotebookMenu(notebook: notebook, library: library, prompt: $prompt) }
                    .draggable(notebook.id.description) { NotebookCover(title: notebook.title, color: notebook.cover.style) }
                    .containerRelativeFrame(.horizontal, count: 3, spacing: 31)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, margin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
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
            LazyVGrid(
                columns: [GridItem(
                    .adaptive(minimum: Tokens.Size.cover.width, maximum: Tokens.Size.cover.width),
                    spacing: 39,
                    alignment: .leading
                )],
                alignment: .leading,
                spacing: 30
            ) {
                ForEach(notebooks) { notebook in
                    CoverTile(
                        notebook: notebook,
                        folder: folder == nil || !query.isEmpty ? library.folder(id: notebook.folderID)?.name : nil,
                        zoom: zoom
                    ) {
                        open(EditorRoute(id: notebook.id, source: .cover))
                    }
                    .contextMenu { NotebookMenu(notebook: notebook, library: library, prompt: $prompt) }
                    .draggable(notebook.id.description) { NotebookCover(title: notebook.title, color: notebook.cover.style) }
                }
            }
        }
    }
}

extension LibraryScreen {
    // MARK: Header

    private var header: some View {
        HStack(spacing: Tokens.Spacing.m) {
            sidebarButton
            VStack(alignment: .leading, spacing: 0) {
                breadcrumb
                Text(library.folder(id: folder)?.name ?? "Library")
                    .font(.libraryTitle)
                    .tracking(-0.5)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: Tokens.Spacing.xxl)
            GlassChrome(spacing: Tokens.Spacing.s) {
                HStack(spacing: Tokens.Spacing.m) {
                    searchField
                    settingsButton
                    newButton
                }
            }
        }
        .padding(.leading, margin - 4)
        .padding(.trailing, margin - 4)
        .padding(.top, Tokens.Spacing.l)
        .padding(.bottom, Tokens.Spacing.s)
    }

    private var sidebarButton: some View {
        let visible = isDocked ? showsDockedSidebar : showsOverlaySidebar
        return Button {
            setSidebar(visible: !visible)
        } label: {
            Image(systemName: Symbol.sidebar.name)
                .scaledFont(size: 17, weight: .medium)
                .foregroundStyle(Tokens.Colors.pillText)
                .frame(width: 40, height: 40)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(visible ? "Hide Sidebar" : "Show Sidebar")
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

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: Symbol.search.name)
                .scaledFont(size: 16, weight: .medium)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .accessibilityHidden(true)
            TextField("Search notebooks", text: $query)
                .scaledFont(size: 15)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Tokens.Colors.textTertiary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Tokens.Spacing.l)
        .padding(.vertical, Tokens.Spacing.xs)
        .frame(width: 250 * typeSize.chromeScale)
        .frame(minHeight: 40)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var settingsButton: some View {
        Button {
            showsSettings = true
        } label: {
            Image(systemName: Symbol.settings.name)
                .scaledFont(size: 17, weight: .medium)
                .foregroundStyle(Tokens.Colors.pillText)
                .frame(width: 40, height: 40)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Settings")
        .popover(isPresented: $showsSettings) {
            SettingsView(showsGallery: showsGallery)
        }
    }

    private var newButton: some View {
        Button {
            showsNewNotebook = true
        } label: {
            Label("New", systemImage: Symbol.add.name)
                .font(.chromeTitle)
                .foregroundStyle(Tokens.Colors.libraryBackground)
                .padding(.horizontal, 2)
                .frame(minHeight: 28)
        }
        .buttonStyle(.glassProminent)
        .tint(Tokens.Colors.textPrimary.color)
        .fixedSize()
        .accessibilityIdentifier("newNotebook")
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
    LibraryScreen(library: SampleLibrary(), zoom: zoom, showsNewNotebook: $showsNew, showsGallery: nil) { _ in }
}
