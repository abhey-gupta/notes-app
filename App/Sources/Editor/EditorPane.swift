import Canvas
import DesignSystem
import InkModel
import Library
import SwiftUI
import Tools

/// One notebook in the editor (#175): its canvas, its own bar, the lasso context bar, the widen hint and
/// the pages overview, all inside the pane's frame. The editor shows one pane, or two in split view;
/// ``EditorScreen`` places them and owns what they share (the tools capsule, focus mode).
struct EditorPane: View {
    let pane: OpenTabs.Pane
    let session: NotebookSession
    let library: any LibraryModel
    let tools: ToolState
    let tabs: TabsModel
    /// Bars are hidden (focus mode, shared by both panes).
    let isFocused: Bool
    /// Room the canvas keeps under the bar for the floating tools capsule.
    let capsuleRoom: CGFloat
    /// The bar sits at the window's top edge (status bar, window controls).
    let isAtTop: Bool
    /// Desk each side of a fitted page (less side by side in a split).
    let fitDesk: CGFloat
    /// The pane's bar height, measured (the tools capsule docks below the top one).
    let onBarHeight: (CGFloat) -> Void
    let onBack: () -> Void
    let onCloseTab: (NotebookID) -> Void
    let actions: SplitActions

    @State private var notebook: NotebookSummary
    @State private var barHeight: CGFloat = 0
    @AppStorage(SettingsView.tapToUndoKey) private var tapToUndo = true
    @AppStorage(SettingsView.snapsShapesKey) private var snapsShapes = true
    @AppStorage(SettingsView.holdsToEraseKey) private var holdsToErase = true
    @AppStorage(SettingsView.newPagesKey) private var newPages = NewPages.manual
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        pane: OpenTabs.Pane, session: NotebookSession, notebook: NotebookSummary, library: any LibraryModel, tools: ToolState,
        tabs: TabsModel, isFocused: Bool, capsuleRoom: CGFloat, isAtTop: Bool, fitDesk: CGFloat,
        onBarHeight: @escaping (CGFloat) -> Void,
        onBack: @escaping () -> Void, onCloseTab: @escaping (NotebookID) -> Void, actions: SplitActions
    ) {
        self.pane = pane
        self.session = session
        self.library = library
        self.tools = tools
        self.tabs = tabs
        self.isFocused = isFocused
        self.capsuleRoom = capsuleRoom
        self.isAtTop = isAtTop
        self.fitDesk = fitDesk
        self.onBarHeight = onBarHeight
        self.onBack = onBack
        self.onCloseTab = onCloseTab
        self.actions = actions
        _notebook = State(initialValue: notebook)
    }

    /// The Pencil's double-tap / squeeze go to this pane: the only one, or the focused one in a split.
    private var takesPencil: Bool {
        (!tabs.isSplit || tabs.focus == pane) && tabs.showing(pane) == session.notebookID
    }

    private var topMargin: CGFloat {
        (isFocused ? 0 : barHeight) + capsuleRoom
    }

    var body: some View {
        let viewport = session.host.state
        let state = session.state
        let page = (min(viewport.currentPage + 1, max(viewport.pageCount, 1)), viewport.pageCount)
        let pages = state.pages
        let chromeHidden = pages.phase == .opening || pages.phase == .open
        ZStack {
            CanvasView(host: session.host)
                .id(ObjectIdentifier(session))
                .ignoresSafeArea()
            // The chrome fades out in the first 100 ms of the pages flight and back in during its last 100 ms
            // (#124); it leaves the hierarchy meanwhile, so the overview's buttons are the only ones.
            Group {
                if !chromeHidden {
                    Group {
                        SelectionBar(tools: tools, state: state, paper: notebook.theme.style)
                        if state.showsWidenHint {
                            WidenHint()
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                                .zIndex(2)
                        }
                        if !isFocused {
                            bar(page: page)
                                .zIndex(3)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .animation(FlightTiming.segment(0, 0.3, opening: chromeHidden, reduceMotion: reduceMotion), value: chromeHidden)
            if pages.isPresented {
                PagesOverview(
                    model: pages, state: state, viewport: viewport, title: notebook.title, paper: notebook.theme.style
                )
                .transition(.identity)
                .zIndex(1)
            }
        }
        .animation(Tokens.Motion.morph, value: state.showsWidenHint)
        .onChange(of: ObjectIdentifier(session), initial: true) {
            if let current = library.notebook(id: session.notebookID) {
                notebook = current
            }
        }
        .task(id: ObjectIdentifier(session)) {
            state.onTouch = { [tabs, pane] in tabs.focus(pane) }
            state.takesPencil = takesPencil
            configure(session)
            await session.open()
            if LaunchOptions.showsHints {
                session.state.offerWidenHint()
            }
            #if DEBUG
                if LaunchOptions.insertsSamplePhoto {
                    try? await Task.sleep(for: .seconds(1.5))
                    session.state.insertPhoto(PhotoImport.samplePhotoData())
                }
                if LaunchOptions.showsPagesOverview {
                    try? await Task.sleep(for: .seconds(4))
                    session.state.pages.present()
                }
            #endif
        }
        .onChange(of: pane) { _, pane in state.onTouch = { [tabs] in tabs.focus(pane) } }
        .onChange(of: takesPencil) { _, takes in state.takesPencil = takes }
        // Paper changed in the other pane on the same notebook: the library entry carries it here.
        .onChange(of: library.notebook(id: session.notebookID)?.theme) { _, theme in
            if let theme, theme != notebook.theme {
                notebook.theme = theme
            }
        }
        .onChange(of: [snapsShapes, holdsToErase]) {
            session.setTool(
                tools.active, allowsFingerDrawing: LaunchOptions.allowsFingerDrawing, snapsShapes: snapsShapes, holdsToErase: holdsToErase
            )
        }
        .onChange(of: tapToUndo) { _, on in session.host.allowsTapUndo = on }
        .onChange(of: newPages) { _, mode in session.addsPagesAutomatically = mode == .automatic }
        .onChange(of: topMargin) { _, margin in session.host.margins.top = margin }
        .onChange(of: fitDesk) { _, desk in session.host.fitDesk = desk }
    }

    /// The pane's bar, slid away in focus mode.
    private func bar(page: (current: Int, total: Int)) -> some View {
        EditorBar(
            pane: pane, tabs: tabs, library: library, tools: tools, state: session.state, notebook: notebook,
            paper: paperBinding, pattern: patternBinding, keepsExactColors: exactColorsBinding,
            page: page, showsBack: pane == .primary, isAtTop: isAtTop, onBack: onBack, onCloseTab: onCloseTab,
            actions: actions
        )
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
            barHeight = height
            onBarHeight(height)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .transition(.move(edge: .top).combined(with: .opacity))
        .chromeGlass(for: notebook.theme.style)
    }

    /// Settings and the current tool, applied to a session when it comes on screen.
    private func configure(_ session: NotebookSession) {
        session.setTool(
            tools.active, allowsFingerDrawing: LaunchOptions.allowsFingerDrawing, snapsShapes: snapsShapes, holdsToErase: holdsToErase
        )
        session.host.allowsTapUndo = tapToUndo
        session.addsPagesAutomatically = newPages == .automatic
        session.host.margins.top = topMargin
        session.host.fitDesk = fitDesk
    }

    /// Paper and pattern changes go through the notebook's open `DocumentStore` (its only writer while the
    /// editor is up); the library entry follows from the store's manifest.
    private var paperBinding: Binding<DesignSystem.PaperTheme> {
        Binding { notebook.theme.style } set: { theme in
            notebook.theme = theme.model
            session.setPaper(theme: notebook.theme, style: notebook.paper)
        }
    }

    private var patternBinding: Binding<PaperPattern> {
        Binding { notebook.paper.pattern } set: { pattern in
            notebook.paper = pattern.model
            session.setPaper(theme: notebook.theme, style: notebook.paper)
        }
    }

    private var exactColorsBinding: Binding<Bool> {
        Binding { session.state.keepsExactColors } set: { session.state.onKeepsExactColors($0) }
    }
}

/// What a pane's bar can ask of the split (#175).
struct SplitActions {
    /// Opens a tab beside this pane (this pane's own notebook: a second view of it).
    var open: (NotebookID) -> Void = { _ in }
    /// Closes this pane; the other keeps the editor.
    var closePane: () -> Void = {}
    var swap: () -> Void = {}
}
