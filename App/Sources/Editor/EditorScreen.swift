import Canvas
import DesignSystem
import InkEngine
import InkModel
import SwiftUI
import Tools

/// Full-screen editor (§7): desk, the showing tab's canvas (`CanvasHostView` + ink engine, #21/#31), the fixed
/// ``EditorBar`` (#191) and the floating tools chrome.
///
/// Tabs (#191): the bar lists every open notebook (``TabsModel``); switching swaps the canvas for that tab's
/// session (``SessionStore``), which stays open behind the others. Leaving for the library closes every
/// session (tabs stay); coming back reopens the showing one.
///
/// Interactive dismissal: the library pushes the editor with a zoom transition whose swipe-down / pinch
/// dismissal would fight Pencil strokes and scrolling. `.interactiveDismissDisabled()` doesn't reach it, so
/// `CanvasHostView` disables those recognizers while it's on screen (edge swipe stays, fingers only);
/// leaving is the back button or the edge swipe.
struct EditorScreen: View {
    let library: any LibraryModel
    let tools: ToolState
    let tabs: TabsModel
    let sessions: SessionStore
    @State private var notebook: NotebookSummary
    @State private var session: NotebookSession
    /// The bar's height, measured: the toolbar docks below it, the canvas rests under it.
    @State private var barHeight: CGFloat = 0
    @AppStorage(SettingsView.tapToUndoKey) private var tapToUndo = true
    @AppStorage(SettingsView.newPagesKey) private var newPages = NewPages.manual

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Room the canvas keeps under the bar: the floating capsule and a gap, as before the bar (#191).
    private static let canvasTopMargin: CGFloat = 72

    init(
        notebook: NotebookSummary, library: any LibraryModel, tools: ToolState, tabs: TabsModel, sessions: SessionStore,
        startsFocused: Bool = false
    ) {
        self.library = library
        self.tools = tools
        self.tabs = tabs
        self.sessions = sessions
        _notebook = State(initialValue: notebook)
        _session = State(initialValue: sessions.session(for: notebook, startsFocused: startsFocused))
    }

    var body: some View {
        let viewport = session.host.state
        let state = session.state
        let page = (min(viewport.currentPage + 1, max(viewport.pageCount, 1)), viewport.pageCount)
        ZStack {
            Rectangle().fill(Tokens.Colors.desk).ignoresSafeArea()
            CanvasView(host: session.host)
                .id(session.notebookID)
                .ignoresSafeArea()
            let pages = state.pages
            let chromeHidden = pages.phase == .opening || pages.phase == .open
            // The chrome fades out in the first 100 ms of the pages flight and back in during its last 100 ms
            // (#124); it leaves the hierarchy meanwhile, so the overview's buttons are the only ones.
            Group {
                if !chromeHidden {
                    Group {
                        ToolbarHost(
                            tools: tools, state: state, paper: notebook.theme.style, page: page,
                            topInset: state.isFocused ? 0 : barHeight
                        )
                        SelectionBar(tools: tools, state: state, paper: notebook.theme.style)
                        if state.showsWidenHint {
                            WidenHint()
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                                .zIndex(2)
                        }
                        if !state.isFocused {
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
        .animation(reduceMotion ? Tokens.Motion.reducedMorph : Tokens.Motion.morph, value: state.isFocused)
        .toolbar(.hidden, for: .navigationBar)
        .persistentSystemOverlays(state.isFocused ? .hidden : .automatic)
        .task(id: session.notebookID) {
            tabs.prune(keeping: Set(library.notebooks.map(\.id)))
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
        .onChange(of: tabs.active) { _, id in show(id) }
        .onChange(of: tools.active) { _, tool in
            session.setTool(tool, allowsFingerDrawing: LaunchOptions.allowsFingerDrawing)
        }
        .onChange(of: tapToUndo) { _, on in session.host.allowsTapUndo = on }
        .onChange(of: newPages) { _, mode in session.addsPagesAutomatically = mode == .automatic }
        .onChange(of: barHeight) { _, height in session.host.margins.top = height + Self.canvasTopMargin }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                sessions.flushAll()
            }
        }
        .onDisappear { sessions.closeAll() }
    }

    /// The fixed bar, slid away in focus mode.
    private func bar(page: (current: Int, total: Int)) -> some View {
        EditorBar(
            tabs: tabs, library: library, tools: tools, state: session.state, notebook: notebook,
            paper: paperBinding, pattern: patternBinding, keepsExactColors: exactColorsBinding,
            page: page, onBack: { dismiss() }, onCloseTab: closeTab
        )
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { barHeight = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .transition(.move(edge: .top).combined(with: .opacity))
        .chromeGlass(for: notebook.theme.style)
    }

    /// Settings and the current tool, applied to a session when it comes on screen.
    private func configure(_ session: NotebookSession) {
        session.setTool(tools.active, allowsFingerDrawing: LaunchOptions.allowsFingerDrawing)
        session.host.allowsTapUndo = tapToUndo
        session.addsPagesAutomatically = newPages == .automatic
        session.host.margins.top = barHeight + Self.canvasTopMargin
    }

    /// The showing tab changed: swap in its session. No tab left → back to the library.
    private func show(_ id: NotebookID?) {
        guard let id else {
            dismiss()
            return
        }
        guard id != session.notebookID else { return }
        guard let next = library.notebook(id: id) else {
            tabs.close(id)
            return
        }
        if !session.isClosed {
            session.flush()
        }
        notebook = next
        session = sessions.session(for: next)
    }

    private func closeTab(_ id: NotebookID) {
        sessions.close(id)
        tabs.close(id)
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

/// Preview tabs: the sample library's notebooks, `index` showing.
@MainActor
private func previewTabs(_ library: SampleLibrary, showing index: Int) -> TabsModel {
    let tabs = TabsModel(defaults: UserDefaults(suiteName: "preview") ?? .standard)
    for notebook in library.notebooks.prefix(3) {
        tabs.open(notebook.id)
    }
    tabs.open(library.notebooks[index].id)
    return tabs
}

#Preview("Editor · light") {
    let library = SampleLibrary()
    let tools = ToolState(initial: .notespace)
    EditorScreen(
        notebook: library.notebooks[0], library: library, tools: tools, tabs: previewTabs(library, showing: 0),
        sessions: SessionStore(library: library, tools: tools)
    )
}

#Preview("Editor · focus · dark") {
    let library = SampleLibrary()
    let tools = ToolState(initial: .notespace)
    EditorScreen(
        notebook: library.notebooks[3], library: library, tools: tools, tabs: previewTabs(library, showing: 3),
        sessions: SessionStore(library: library, tools: tools), startsFocused: true
    )
    .preferredColorScheme(.dark)
}
