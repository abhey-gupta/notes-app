import DesignSystem
import InkModel
import Library
import SwiftUI
import Tools

/// The editor's fixed top bar (#191): ‹ library · the tabs chip on the left; undo · redo │ pages with "3 / 11" │ ⋯
/// on the right. Tapping the chip unfolds the tab strip across the bar (``TabStrip``) and slides the right
/// group away; a touch on the page folds it back. Everything about the notebook lives here; the floating capsule keeps only the writing
/// tools. A flat surface edge to edge, under the status bar, with a hairline below, and plain buttons on it
/// (no glass: user decision, #191). Hidden in focus mode (the page pill stands in for the counter).
///
/// Compact chrome (#118): no undo/redo (the bottom bar has undo; redo is the three-finger tap).
///
/// Split view (#175): each pane has its own bar, and everything on it acts on that pane: its tab chip
/// (switching tabs there), undo · redo, pages and ⋯. ‹ only on the primary pane. A narrow pane drops
/// undo · redo (two-finger tap still undoes) and then the counter's text.
struct EditorBar: View {
    let pane: OpenTabs.Pane
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
    /// ‹ library (the primary pane's bar).
    var showsBack = true
    /// The bar is at the window's top edge (clears the window controls).
    var isAtTop = true
    let onBack: () -> Void
    let onCloseTab: (NotebookID) -> Void
    var actions = SplitActions()

    @State private var width: CGFloat = 0
    @Environment(\.chromeLayout) private var chrome
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let scale = typeSize.chromeScale
        let expanded = state.showsTabs
        HStack(spacing: Tokens.Spacing.xs) {
            if showsBack {
                ToolButton(.back, "Library", size: Tokens.Size.compactToolButton, action: onBack)
                    .accessibilityHint("Back to the library; tabs stay open")
                ChromeSeparator()
            }
            TabStrip(
                tabs: strip, active: tabs.showing(pane), isExpanded: expanded,
                onToggle: {
                    tabs.focus(pane)
                    state.toggleTabs()
                },
                onSelect: { id in
                    tabs.show(id, in: pane)
                    state.collapseTabs()
                },
                onClose: onCloseTab,
                onCloseOthers: closeOthers,
                onAdd: {
                    tabs.focus(pane)
                    onBack()
                },
                onSplit: chrome.isCompact ? nil : actions.open
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            if !expanded {
                HStack(spacing: Tokens.Spacing.xs) {
                    if !chrome.isCompact, width == 0 || width >= Self.undoWidth {
                        ToolButton(.undo, "Undo", size: Tokens.Size.compactToolButton, action: state.undo)
                            .disabled(!state.canUndo)
                        ToolButton(.redo, "Redo", size: Tokens.Size.compactToolButton, action: state.redo)
                            .disabled(!state.canRedo)
                        ChromeSeparator()
                    }
                    pages
                    ChromeSeparator()
                    MoreMenu(
                        pane: pane, tools: tools, state: state, tabs: tabs, library: library, notebookID: notebook.id,
                        title: notebook.title, page: page, paper: $paper, pattern: $pattern,
                        keepsExactColors: $keepsExactColors, isCompact: chrome.isCompact,
                        onCloseTab: { onCloseTab(notebook.id) }, onCloseOthers: closeOthers, actions: actions
                    )
                }
                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? Tokens.Motion.reducedMorph : Tokens.Motion.morph, value: expanded)
        .padding(.leading, Tokens.Spacing.m + (showsBack && isAtTop ? chrome.windowControls.leading : 0))
        .padding(.trailing, Tokens.Spacing.m)
        .frame(height: Tokens.Size.capsuleHeight * scale)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .background { BarSurface() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(pane == .primary ? "editorBar" : "editorBar-secondary")
    }

    /// Narrower than this, undo · redo leave the bar; narrower than ``counterWidth``, the counter's text.
    private static let undoWidth: CGFloat = 520
    private static let counterWidth: CGFloat = 400

    /// Open tabs with their titles; a tab whose notebook is gone isn't shown.
    private var strip: [TabStrip.Tab] {
        tabs.ids.compactMap { id in
            library.notebook(id: id).map { TabStrip.Tab(id: id, title: $0.title) }
        }
    }

    private func closeOthers() {
        for id in tabs.ids where id != tabs.showing(pane) {
            onCloseTab(id)
        }
    }

    /// Pages grid and the "1 of 11" counter: both open the overview. The counter is the same element the
    /// focus pill is (`pageIndicator`), so VoiceOver and the UI tests find the current page in one place.
    private var pages: some View {
        HStack(spacing: 0) {
            ToolButton(.pages, "Pages", size: Tokens.Size.compactToolButton) { state.pages.present() }
                .accessibilityValue("\(page.current) of \(page.total)")
                .accessibilityHint("Shows all pages")
            if width == 0 || width >= Self.counterWidth {
                counter
            }
        }
    }

    private var counter: some View {
        let scale = typeSize.chromeScale
        return Text("\(page.current) of \(page.total)")
            .font(.pill)
            .foregroundStyle(Tokens.Colors.textSecondary)
            .contentTransition(.numericText())
            .padding(.trailing, Tokens.Spacing.m)
            .padding(.leading, Tokens.Spacing.hairline)
            .frame(height: Tokens.Size.compactToolButton.height * scale)
            .contentShape(.rect)
            .onTapGesture { state.pages.present() }
            .accessibilityIdentifier(pane == .primary ? "pageIndicator" : "pageIndicator-secondary")
            .accessibilityHint("Current page")
    }
}

/// The bar's flat surface, reaching under the status bar, with a hairline along its bottom edge
/// (``ChromeGlass/surface``).
private struct BarSurface: View {
    @Environment(\.chromeGlass) private var chrome

    var body: some View {
        Rectangle()
            .fill(chrome?.surface ?? Tokens.Colors.libraryBackground.color)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(chrome?.edge ?? Tokens.Colors.separator.color)
                    .frame(height: 1 / 3)
            }
            .ignoresSafeArea(edges: .top)
    }
}

/// ⋯: the notebook's options under its title (paper, template, Keep exact colors on Night paper), Share and
/// Focus mode, then the tab actions with their keyboard shortcuts. DEBUG adds a dock picker.
///
/// Compact chrome (#118): Add Photo and Laser Pointer join it (no room on the bar); focus mode (regular
/// chrome only) leaves it.
///
/// Split view (#175): Open in Split View (another tab, or this notebook again); in split, Swap Sides and
/// Close This Side. Keyboard shortcuts belong to the focused pane's menu only.
struct MoreMenu: View {
    var pane = OpenTabs.Pane.primary
    let tools: ToolState
    let state: EditorState
    let tabs: TabsModel
    let library: any LibraryModel
    let notebookID: NotebookID
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
    var actions = SplitActions()

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
            if !isCompact {
                split
            }
            Section {
                Button("Close Tab", systemImage: "xmark", action: onCloseTab)
                    .keyboardShortcut(shortcut("w", modifiers: .command))
                if tabs.ids.count > 1 {
                    Button("Close Other Tabs", action: onCloseOthers)
                    Button("Next Tab", systemImage: "arrow.right") {
                        tabs.focus(pane)
                        tabs.activateNext()
                    }
                    .keyboardShortcut(shortcut(.tab, modifiers: .control))
                    Button("Previous Tab", systemImage: "arrow.left") {
                        tabs.focus(pane)
                        tabs.activatePrevious()
                    }
                    .keyboardShortcut(shortcut(.tab, modifiers: [.control, .shift]))
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

    private var split: some View {
        Section {
            if tabs.isSplit {
                Button("Swap Sides", systemImage: "arrow.left.arrow.right", action: actions.swap)
                Button("Close This Side", systemImage: "xmark.square", action: actions.closePane)
            } else {
                Menu("Open in Split View", systemImage: "rectangle.split.2x1") {
                    ForEach(tabs.ids.filter { $0 != notebookID }, id: \.self) { id in
                        if let other = library.notebook(id: id) {
                            Button(other.title) { actions.open(id) }
                        }
                    }
                    Button("\(title) (again)") { actions.open(notebookID) }
                }
                .accessibilityIdentifier("openInSplitView")
            }
        }
    }

    /// The focused pane's menu holds the keyboard shortcuts (two menus can't share one).
    private func shortcut(_ key: KeyEquivalent, modifiers: EventModifiers) -> KeyboardShortcut? {
        !tabs.isSplit || tabs.focus == pane ? KeyboardShortcut(key, modifiers: modifiers) : nil
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
