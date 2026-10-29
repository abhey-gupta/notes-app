import DesignSystem
import InkModel
import SwiftUI
import Tools

/// The editor's fixed top bar (#191): ‹ library · tabs · + on the left; undo · redo │ pages with "3 / 11" │ ⋯
/// on the right. Everything about the notebook lives here; the floating capsule keeps only the writing
/// tools. One Liquid Glass slab edge to edge, under the status bar, with a hairline below; the paper scrolls
/// under it. Hidden in focus mode (the page pill stands in for the counter).
///
/// Compact chrome (#118): no undo/redo (the bottom bar has undo; redo is the three-finger tap).
struct EditorBar: View {
    let tabs: TabsModel
    let library: any LibraryModel
    let tools: ToolState
    let state: EditorState
    /// The showing notebook.
    let notebook: NotebookSummary
    @Binding var paper: DesignSystem.PaperTheme
    @Binding var pattern: PaperPattern
    @Binding var keepsExactColors: Bool
    /// Current page (1-based) and page count.
    let page: (current: Int, total: Int)
    let onBack: () -> Void
    let onCloseTab: (NotebookID) -> Void

    @Environment(\.chromeLayout) private var chrome
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let scale = typeSize.chromeScale
        HStack(spacing: Tokens.Spacing.xs) {
            ToolButton(.back, "Library", size: Tokens.Size.compactToolButton, action: onBack)
                .accessibilityHint("Back to the library; tabs stay open")
            ChromeSeparator()
            TabStrip(
                tabs: strip, active: tabs.active,
                onSelect: { tabs.activate($0) },
                onClose: onCloseTab,
                onCloseOthers: closeOthers,
                onAdd: onBack
            )
            if !chrome.isCompact {
                ToolButton(.undo, "Undo", size: Tokens.Size.compactToolButton, action: state.undo)
                    .disabled(!state.canUndo)
                ToolButton(.redo, "Redo", size: Tokens.Size.compactToolButton, action: state.redo)
                    .disabled(!state.canRedo)
                ChromeSeparator()
            }
            pages
            ChromeSeparator()
            MoreMenu(
                tools: tools, state: state, tabs: tabs, title: notebook.title, page: page,
                paper: $paper, pattern: $pattern, keepsExactColors: $keepsExactColors, isCompact: chrome.isCompact,
                onCloseTab: { onCloseTab(notebook.id) }, onCloseOthers: closeOthers
            )
        }
        .padding(.leading, Tokens.Spacing.m + chrome.windowControls.leading)
        .padding(.trailing, Tokens.Spacing.m)
        .frame(height: Tokens.Size.capsuleHeight * scale)
        .frame(maxWidth: .infinity)
        .background { BarGlass() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editorBar")
    }

    /// Open tabs with their titles; a tab whose notebook is gone isn't shown.
    private var strip: [TabStrip.Tab] {
        tabs.ids.compactMap { id in
            library.notebook(id: id).map { TabStrip.Tab(id: id, title: $0.title) }
        }
    }

    private func closeOthers() {
        for id in tabs.ids where id != tabs.active {
            onCloseTab(id)
        }
    }

    /// Pages grid and the "1 of 11" counter: both open the overview. The counter is the same element the
    /// focus pill is (`pageIndicator`), so VoiceOver and the UI tests find the current page in one place.
    private var pages: some View {
        let scale = typeSize.chromeScale
        return HStack(spacing: 0) {
            ToolButton(.pages, "Pages", size: Tokens.Size.compactToolButton) { state.pages.present() }
                .accessibilityValue("\(page.current) of \(page.total)")
                .accessibilityHint("Shows all pages")
            Text("\(page.current) of \(page.total)")
                .font(.pill)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .contentTransition(.numericText())
                .padding(.trailing, Tokens.Spacing.m)
                .padding(.leading, Tokens.Spacing.hairline)
                .frame(height: Tokens.Size.compactToolButton.height * scale)
                .contentShape(.rect)
                .onTapGesture { state.pages.present() }
                .accessibilityIdentifier("pageIndicator")
                .accessibilityHint("Current page")
        }
    }
}

/// The bar's glass: the chrome's Liquid Glass in a rectangle reaching under the status bar, with the
/// paper-white backing and a hairline along its bottom edge (``ChromeGlass``).
private struct BarGlass: View {
    @Environment(\.chromeGlass) private var chrome

    var body: some View {
        Rectangle()
            .fill(.clear)
            .glassEffect(chrome?.glass ?? .regular, in: .rect)
            .background {
                if let chrome {
                    chrome.backing
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(chrome?.edge ?? Tokens.Colors.separator.color)
                    .frame(height: 1 / 3)
            }
            .shadow(color: .black.opacity(chrome?.shadowOpacity ?? 0), radius: 10, y: 3)
            .ignoresSafeArea(edges: .top)
    }
}

/// ⋯: the notebook's options under its title (paper, template, Keep exact colors on Night paper), Share and
/// Focus mode, then the tab actions with their keyboard shortcuts. DEBUG adds a dock picker.
///
/// Compact chrome (#118): Add Photo and Laser Pointer join it (no room on the bar); focus mode (regular
/// chrome only) leaves it.
struct MoreMenu: View {
    let tools: ToolState
    let state: EditorState
    let tabs: TabsModel
    let title: String
    /// Current page (1-based) and page count, for export.
    let page: (current: Int, total: Int)
    @Binding var paper: DesignSystem.PaperTheme
    @Binding var pattern: PaperPattern
    /// "Keep exact colors", offered on Night paper.
    @Binding var keepsExactColors: Bool
    var isCompact = false
    let onCloseTab: () -> Void
    let onCloseOthers: () -> Void

    @State private var showsShare = false
    @State private var showsPhotos = false
    @State private var presenter = ActivityPresenter()
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        menu
            .background(ActivityAnchor(presenter: presenter))
            .popover(isPresented: $showsShare) { sharePopover }
            .background {
                Color.clear.popover(isPresented: $showsPhotos) {
                    PhotoFlyout(paper: paper) { data in
                        showsPhotos = false
                        state.insertPhoto(data)
                    }
                }
            }
    }

    private var sharePopover: some View {
        SharePopover(state: state, page: page, isNight: paper.isDark) { url in
            showsShare = false
            // Present once SwiftUI has started dismissing the popover.
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                presenter.share(url)
            }
        }
        .chromePopover(for: paper)
        .presentationCompactAdaptation(.popover)
    }

    private var menu: some View {
        let scale = typeSize.chromeScale
        let size = Tokens.Size.compactToolButton
        return Menu {
            Section(title) {
                Picker("Paper", systemImage: "doc", selection: $paper) {
                    ForEach(PaperTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.menu)
                Picker("Template", systemImage: "squareshape.split.3x3", selection: $pattern) {
                    ForEach(PaperPattern.allCases) { pattern in
                        Text(pattern.displayName).tag(pattern)
                    }
                }
                .pickerStyle(.menu)
                if paper == .night {
                    Toggle("Keep exact colors", systemImage: "eyedropper", isOn: $keepsExactColors)
                }
            }
            Section {
                Button("Share", systemImage: Symbol.share.name) { showsShare = true }
                if isCompact {
                    Button("Add Photo", systemImage: Symbol.photo.name) { showsPhotos = true }
                    Toggle("Laser Pointer", systemImage: Symbol.laser.name, isOn: laserBinding)
                } else {
                    Button("Focus mode", systemImage: Symbol.focus.name) { state.enterFocus() }
                }
            }
            Section {
                Button("Close Tab", systemImage: "xmark", action: onCloseTab)
                    .keyboardShortcut("w", modifiers: .command)
                if tabs.ids.count > 1 {
                    Button("Close Other Tabs", action: onCloseOthers)
                    Button("Next Tab", systemImage: "arrow.right") { tabs.activateNext() }
                        .keyboardShortcut(.tab, modifiers: .control)
                    Button("Previous Tab", systemImage: "arrow.left") { tabs.activatePrevious() }
                        .keyboardShortcut(.tab, modifiers: [.control, .shift])
                }
            }
            #if DEBUG
                Picker("Toolbar dock (debug)", selection: dockBinding) {
                    ForEach(ToolbarDock.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            #endif
        } label: {
            Image(systemName: Symbol.more.name)
                .font(.system(size: Tokens.Size.toolIcon * scale))
                .foregroundStyle(Tokens.Colors.icon)
                .frame(width: size.width * scale, height: size.height * scale)
                .contentShape(.capsule)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("More")
        .accessibilityValue(title)
        .accessibilityHint("\(paper.displayName) paper, \(pattern.displayName). Share, tabs and notebook options")
    }

    /// Off goes back to the tool before the laser.
    private var laserBinding: Binding<Bool> {
        Binding { tools.tool == .laser } set: { on in
            if on {
                _ = tools.select(.laser)
            } else if tools.tool == .laser {
                tools.switchToPrevious()
            }
        }
    }

    #if DEBUG
        private var dockBinding: Binding<ToolbarDock> {
            Binding { tools.dock } set: { tools.dock = $0 }
        }
    #endif
}
