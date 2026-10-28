import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// Library header (mock §01): serif title · search · settings · New. Compact chrome (#118): sidebar (folders)
/// on the left, search · settings · + on the right; search swaps the row for the field and Cancel. Either way
/// it starts clear of an iPadOS window's controls.
struct LibraryHeader: View {
    @Binding var query: String
    @Binding var showsNewNotebook: Bool
    @Binding var pdfImport: PDFImportRequest?
    @Binding var showsFolders: Bool
    /// DEBUG: DesignSystem gallery toggle, surfaced in Settings.
    let showsGallery: Binding<Bool>?

    @State private var showsSettings = false
    @State private var showsPDFPicker = false
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.chromeLayout) private var chrome

    private var margin: CGFloat {
        chrome.margin
    }

    private var isCompact: Bool {
        chrome.isCompact
    }

    var body: some View {
        if isCompact {
            compactHeader
        } else {
            header
        }
    }

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
                }
            }
            // Outside the glass container: its menu morphs out of the pill, and inside the container
            // the pill's glass kept taps from the menu's first row.
            newButton
        }
        .padding(.leading, margin + chrome.windowControls.leading)
        .padding(.trailing, margin - 4)
        .padding(.top, Tokens.Spacing.l)
        .padding(.bottom, Tokens.Spacing.s)
    }

    private var compactHeader: some View {
        HStack(spacing: Tokens.Spacing.m) {
            // A query typed in a wider window stays visible.
            if isSearching || !query.isEmpty {
                searchField
                Button("Cancel") {
                    query = ""
                    searchFocused = false
                    withAnimation(Tokens.Motion.morph) { isSearching = false }
                }
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(Tokens.Colors.textPrimary)
                .buttonStyle(.plain)
                .frame(minHeight: 40)
            } else {
                circleButton("Folders", systemImage: "sidebar.leading") { showsFolders = true }
                    .accessibilityIdentifier("foldersButton")
                Spacer(minLength: Tokens.Spacing.m)
                GlassChrome(spacing: Tokens.Spacing.s) {
                    HStack(spacing: Tokens.Spacing.m) {
                        circleButton("Search", systemImage: Symbol.search.name) {
                            withAnimation(Tokens.Motion.morph) { isSearching = true }
                            searchFocused = true
                        }
                        .accessibilityIdentifier("searchButton")
                        settingsButton
                    }
                }
                newButton
            }
        }
        .padding(.leading, margin + chrome.windowControls.leading)
        .padding(.trailing, margin - 4)
        .padding(.top, Tokens.Spacing.s)
        .padding(.bottom, Tokens.Spacing.s)
    }

    private func circleButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .scaledFont(size: 17, weight: .medium)
                .foregroundStyle(Tokens.Colors.pillText)
                .frame(width: 40, height: 40)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
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
                .focused($searchFocused)
                .accessibilityIdentifier("searchField")
            if !query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Tokens.Colors.textTertiary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Tokens.Spacing.l)
        .padding(.vertical, Tokens.Spacing.xs)
        .frame(width: isCompact ? nil : 250 * typeSize.chromeScale)
        .frame(maxWidth: isCompact ? .infinity : nil, minHeight: 40)
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

    /// "+" menu: New Notebook, Import PDF… (#119, the Files picker feeds the import sheet).
    private var newButton: some View {
        Menu {
            Button("New Notebook", systemImage: "square.and.pencil") { showsNewNotebook = true }
                .accessibilityIdentifier("newNotebookItem")
            Button("Import PDF…", systemImage: "doc.richtext") { showsPDFPicker = true }
                .accessibilityIdentifier("importPDFItem")
        } label: {
            // Compact: the + alone, a dark circle.
            Group {
                if isCompact {
                    Image(systemName: Symbol.add.name)
                } else {
                    Label("New", systemImage: Symbol.add.name)
                }
            }
            .font(.chromeTitle)
            .foregroundStyle(Tokens.Colors.libraryBackground)
            .padding(.horizontal, isCompact ? 0 : Tokens.Spacing.l)
            .frame(minWidth: 40, minHeight: 40)
            .contentShape(.capsule)
        }
        .menuIndicator(.hidden)
        // A plain label in dark glass (the title menu's pattern), kept out of `GlassChrome`: a glass button
        // style, or a glass container around the menu, swallowed taps on the menu's first row.
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Tokens.Colors.textPrimary.color).interactive(), in: .capsule)
        .fixedSize()
        .accessibilityLabel("New")
        .accessibilityIdentifier("newNotebook")
        .fileImporter(isPresented: $showsPDFPicker, allowedContentTypes: [.pdf]) { result in
            pdfImport = PDFInbox.stage(result)
        }
    }
}
