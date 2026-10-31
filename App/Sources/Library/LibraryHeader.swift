import DesignSystem
import Library
import SwiftUI
import UniformTypeIdentifiers

/// Library header (mock §01): serif title (the folder showing, under its breadcrumb, #117) · search · settings ·
/// New, with a sidebar button while the sidebar is hidden. Compact chrome (#118): sidebar on the left,
/// search · settings · + on the right; search swaps the row for the field and Cancel. Either way it starts
/// clear of an iPadOS window's controls. While sync runs, a quiet line sits under the title (#174 mock 05-D, #225).
struct LibraryHeader: View {
    @Binding var query: String
    @Binding var showsNewNotebook: Bool
    @Binding var pdfImport: PDFImportRequest?
    /// "Library", or the folder showing (#117).
    var title = "Library"
    /// The showing folder's ancestors, top level first: a breadcrumb over the title.
    var ancestors: [LibraryFolder] = []
    /// Shows the sidebar; nil while it's docked and showing.
    var showSidebar: (() -> Void)?
    /// A breadcrumb was tapped (`nil` = Library).
    var pickFolder: (FolderID?) -> Void = { _ in }
    /// The header starts at the window's leading edge (no docked sidebar), so it clears the window controls.
    var hugsLeadingEdge = true
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
        // The title stays level with the controls; the sync line has a fixed slot under the title, so the bar
        // never changes height (nothing shifts; its scroll-edge effect would follow anything hung below it).
        HStack(alignment: .titleCenter, spacing: Tokens.Spacing.m) {
            if let showSidebar {
                circleButton("Show Sidebar", systemImage: "sidebar.leading", action: showSidebar)
                    .accessibilityIdentifier("sidebarButton")
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.libraryTitle)
                    .tracking(-0.5)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    // One line in any window width (#195): shrinks, then truncates, before the controls give way.
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("libraryTitle")
                    // Above the title, outside its layout: the title doesn't move between Library and a folder.
                    .overlay(alignment: .topLeading) {
                        if !ancestors.isEmpty {
                            breadcrumb
                                .fixedSize()
                                .alignmentGuide(.top) { $0[.bottom] + 6 }
                        }
                    }
                    .alignmentGuide(.titleCenter) { $0[VerticalAlignment.center] }
                SyncStatusLine()
                    .frame(height: SyncStatusLine.slot, alignment: .top)
            }
            .layoutPriority(1)
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
        .padding(.leading, margin + (hugsLeadingEdge ? chrome.windowControls.leading : 0))
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
                circleButton("Show Sidebar", systemImage: "sidebar.leading") { showSidebar?() }
                    .accessibilityIdentifier("sidebarButton")
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

    /// Library › University › — each crumb goes up to that level.
    private var breadcrumb: some View {
        HStack(spacing: 4) {
            crumb("Library", id: nil)
            ForEach(ancestors) { folder in
                Image(systemName: "chevron.right")
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(Tokens.Colors.textTertiary)
                    .accessibilityHidden(true)
                crumb(folder.name, id: folder.id)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }

    private func crumb(_ name: String, id: FolderID?) -> some View {
        Button(name) { pickFolder(id) }
            .scaledFont(size: 13, weight: .medium)
            .foregroundStyle(Tokens.Colors.textTertiary)
            .lineLimit(1)
            .buttonStyle(.plain)
            .accessibilityIdentifier("crumb-\(name)")
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
        // Regular: 250 wide, giving way to the title down to 160 in narrow windows (#195).
        .frame(
            minWidth: isCompact ? nil : 160 * typeSize.chromeScale,
            maxWidth: isCompact ? .infinity : 250 * typeSize.chromeScale,
            minHeight: 40
        )
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

/// Compact chrome's serif title, scrolling with the content (#118), with the sync line's slot under it (#225).
struct CompactLibraryTitle: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.libraryTitle)
                .tracking(-0.5)
                .foregroundStyle(Tokens.Colors.textPrimary)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            SyncStatusLine()
                .frame(height: SyncStatusLine.slot, alignment: .top)
        }
    }
}

extension VerticalAlignment {
    private enum TitleCenter: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat {
            d[VerticalAlignment.center]
        }
    }

    /// The library title's center: the header's controls line up with it, whatever hangs below.
    static let titleCenter = VerticalAlignment(TitleCenter.self)
}
