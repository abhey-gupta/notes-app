import Canvas
import DesignSystem
import InkEngine
import SwiftUI
import Tools

/// Full-screen editor (§7): desk, the canvas (`CanvasHostView` + ink engine, #21/#31), floating glass chrome.
///
/// Interactive dismissal: the library pushes the editor with a zoom transition whose swipe-down / pinch
/// dismissal would fight Pencil strokes and scrolling. `.interactiveDismissDisabled()` doesn't reach it, so
/// `CanvasHostView` disables those recognizers while it's on screen (edge swipe stays, fingers only);
/// leaving is the back button or the edge swipe.
struct EditorScreen: View {
    let library: any LibraryModel
    let tools: ToolState
    @State private var notebook: NotebookSummary
    @State private var session: NotebookSession
    @State private var pencil: PencilGestures
    @AppStorage(SettingsView.tapToUndoKey) private var tapToUndo = true
    @AppStorage(SettingsView.newPagesKey) private var newPages = NewPages.manual

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(notebook: NotebookSummary, library: any LibraryModel, tools: ToolState, startsFocused: Bool = false) {
        self.library = library
        self.tools = tools
        _notebook = State(initialValue: notebook)
        let session = NotebookSession(notebook: notebook, library: library, startsFocused: startsFocused)
        session.onErased = { [tools] in tools.finishedErasing() }
        _session = State(initialValue: session)
        _pencil = State(initialValue: PencilGestures(tools: tools, state: session.state))
    }

    var body: some View {
        let viewport = session.host.state
        ZStack {
            Rectangle().fill(Tokens.Colors.desk).ignoresSafeArea()
            CanvasView(host: session.host)
                .ignoresSafeArea()
            if session.state.pages.isPresented {
                PagesOverview(
                    model: session.state.pages, state: session.state, viewport: viewport, title: notebook.title, paper: notebook.theme.style
                )
                .transition(.opacity)
                .zIndex(1)
            } else {
                ToolbarHost(
                    tools: tools,
                    state: session.state,
                    title: notebook.title,
                    paper: paperBinding,
                    pattern: patternBinding,
                    page: (min(viewport.currentPage + 1, max(viewport.pageCount, 1)), viewport.pageCount),
                    onBack: { dismiss() }
                )
                SelectionBar(tools: tools, state: session.state, paper: notebook.theme.style)
                if session.state.showsWidenHint {
                    WidenHint()
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .zIndex(2)
                }
            }
        }
        .animation(Tokens.Motion.morph, value: session.state.showsWidenHint)
        .animation(Tokens.Motion.reducedMorph, value: session.state.pages.isPresented)
        .toolbar(.hidden, for: .navigationBar)
        .persistentSystemOverlays(session.state.isFocused ? .hidden : .automatic)
        .task {
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
        .onAppear { pencil.install(on: session.host) }
        .onChange(of: tools.active, initial: true) { _, tool in
            session.setTool(tool, allowsFingerDrawing: LaunchOptions.allowsFingerDrawing)
        }
        .onChange(of: tapToUndo, initial: true) { _, on in
            session.host.allowsTapUndo = on
        }
        .onChange(of: newPages, initial: true) { _, mode in
            session.addsPagesAutomatically = mode == .automatic
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                session.flush()
            }
        }
        .onDisappear { session.close() }
    }

    /// Paper and pattern changes go through the notebook's open `DocumentStore` (its only writer while the
    /// editor is up); the library entry follows from the store's manifest.
    private var paperBinding: Binding<PaperTheme> {
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
}

#Preview("Editor · light") {
    let library = SampleLibrary()
    EditorScreen(notebook: library.notebooks[0], library: library, tools: ToolState(initial: .notespace))
}

#Preview("Editor · focus · dark") {
    let library = SampleLibrary()
    EditorScreen(notebook: library.notebooks[3], library: library, tools: ToolState(initial: .notespace), startsFocused: true)
        .preferredColorScheme(.dark)
}
