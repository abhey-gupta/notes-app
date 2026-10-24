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

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(notebook: NotebookSummary, library: any LibraryModel, tools: ToolState, startsFocused: Bool = false) {
        self.library = library
        self.tools = tools
        _notebook = State(initialValue: notebook)
        _session = State(initialValue: NotebookSession(notebook: notebook, library: library, startsFocused: startsFocused))
    }

    var body: some View {
        let viewport = session.host.state
        ZStack {
            Rectangle().fill(Tokens.Colors.desk).ignoresSafeArea()
            CanvasView(host: session.host)
                .ignoresSafeArea()
            ToolbarHost(
                tools: tools,
                state: session.state,
                title: notebook.title,
                paper: paperBinding,
                pattern: patternBinding,
                page: (min(viewport.currentPage + 1, max(viewport.pageCount, 1)), viewport.pageCount),
                onBack: { dismiss() },
                onReselectTool: { _ in } // tool options popover lands with #27
            )
        }
        .toolbar(.hidden, for: .navigationBar)
        .persistentSystemOverlays(session.state.isFocused ? .hidden : .automatic)
        .task { await session.open() }
        .onChange(of: tools.configuration(allowsFingerDrawing: LaunchOptions.allowsFingerDrawing), initial: true) { _, configuration in
            session.setTool(configuration)
        }
        .onChange(of: tools.eraser.mode, initial: true) { _, mode in
            session.eraserMode = mode
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
