import DesignSystem
import Library
import os
import SwiftUI

/// Library (mock §01): serif title, glass search/settings/New, "Continue" recents, folder chips, covers grid.
struct LibraryScreen: View {
    let library: any LibraryModel
    let zoom: Namespace.ID
    @Binding var showsNewNotebook: Bool
    /// DEBUG: DesignSystem gallery toggle, surfaced in Settings.
    let showsGallery: Binding<Bool>?
    let open: (EditorRoute) -> Void

    @State private var query = ""
    @State private var folder: LibraryFolder.ID?
    @State private var sort = LibrarySort.recent
    @State private var showsSettings = false
    @State private var isCreating = false
    @State private var prompt: LibraryPrompt?
    @Namespace private var chipSelection

    private let margin = Tokens.Spacing.libraryMargin

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if query.isEmpty, !library.recents.isEmpty {
                    Text("Continue")
                        .sectionLabelStyle()
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
        .background { Rectangle().fill(Tokens.Colors.libraryBackground).ignoresSafeArea() }
        .safeAreaBar(edge: .top) { header }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showsNewNotebook) {
            NewNotebookSheet(folder: library.folder(id: folder)) { draft in
                create(draft)
            }
        }
        .libraryPrompts($prompt, library: library)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Tokens.Spacing.m) {
            Text("Library")
                .font(.libraryTitle)
                .tracking(-0.5)
                .foregroundStyle(Tokens.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Tokens.Spacing.xxl)
            GlassChrome(spacing: Tokens.Spacing.s) {
                HStack(spacing: Tokens.Spacing.m) {
                    searchField
                    settingsButton
                    newButton
                }
            }
        }
        .padding(.leading, margin)
        .padding(.trailing, margin - 4)
        .padding(.top, Tokens.Spacing.l)
        .padding(.bottom, Tokens.Spacing.s)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: Symbol.search.name)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Tokens.Colors.textSecondary)
            TextField("Search notebooks", text: $query)
                .font(.system(size: 15))
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
        .frame(width: 250, height: 40)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var settingsButton: some View {
        Button {
            showsSettings = true
        } label: {
            Image(systemName: Symbol.settings.name)
                .font(.system(size: 17, weight: .medium))
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
                .frame(height: 28)
        }
        .buttonStyle(.glassProminent)
        .tint(Tokens.Colors.textPrimary.color)
        .accessibilityIdentifier("newNotebook")
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Tokens.Colors.textTertiary)
                    .padding(.horizontal, Tokens.Spacing.l)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("newFolder")
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
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Tokens.Colors.textSecondary)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
        }
    }

    private func chip(_ name: String, id: FolderID?) -> some View {
        let selected = folder == id
        return Button {
            withAnimation(.snappy(duration: 0.25)) { folder = id }
        } label: {
            Text(name)
                .font(.system(size: 13, weight: .medium))
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

    private var shownNotebooks: [NotebookSummary] {
        let notebooks = library.notebooks(in: folder, matching: query)
        return sort == .recent ? notebooks : notebooks.sorted(by: sort)
    }

    @ViewBuilder
    private var coversGrid: some View {
        let notebooks = shownNotebooks
        if notebooks.isEmpty {
            // Hidden while a slow index load/rebuild is still running: never flash "No notebooks yet".
            if library.isLoaded {
                Text(query.isEmpty ? "No notebooks yet. Tap New to start one." : "No notebooks match “\(query)”.")
                    .font(.system(size: 15))
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
                    CoverTile(notebook: notebook, folder: library.folder(id: notebook.folderID)?.name, zoom: zoom) {
                        open(EditorRoute(id: notebook.id, source: .cover))
                    }
                    .contextMenu { NotebookMenu(notebook: notebook, library: library, prompt: $prompt) }
                }
            }
        }
    }
}

extension LibraryScreen {
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
