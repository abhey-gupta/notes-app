import DesignSystem
import SwiftUI

/// Full-screen editor (§7): desk, canvas (placeholder until #21), floating glass chrome.
struct EditorScreen: View {
    let library: any LibraryModel
    @State private var notebook: NotebookSummary
    @State private var state: EditorState
    @State private var currentPage: Int? = 0

    #if DEBUG
        @AppStorage(ToolbarDock.defaultsKey) private var dock: ToolbarDock = .top
    #else
        private let dock: ToolbarDock = .top
    #endif

    @Environment(\.dismiss) private var dismiss

    init(notebook: NotebookSummary, library: any LibraryModel, startsFocused: Bool = false) {
        self.library = library
        _notebook = State(initialValue: notebook)
        _state = State(initialValue: EditorState(startsFocused: startsFocused))
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Tokens.Colors.desk).ignoresSafeArea()
            PlaceholderCanvas(
                notebook: notebook,
                paper: notebook.theme.style,
                pattern: notebook.paper.pattern,
                state: state,
                currentPage: $currentPage
            )
            ToolbarHost(
                dock: dock,
                isCompact: state.isFocused,
                title: notebook.title,
                paper: paperBinding,
                pattern: patternBinding,
                state: state,
                page: (min((currentPage ?? 0) + 1, notebook.pageCount), notebook.pageCount),
                onBack: { dismiss() }
            )
        }
        .toolbar(.hidden, for: .navigationBar)
        .persistentSystemOverlays(state.isFocused ? .hidden : .automatic)
        .onChange(of: notebook) { _, notebook in
            library.update(notebook)
        }
        .onAppear(perform: OpenTrace.end)
    }

    private var paperBinding: Binding<PaperTheme> {
        Binding { notebook.theme.style } set: { notebook.theme = $0.model }
    }

    private var patternBinding: Binding<PaperPattern> {
        Binding { notebook.paper.pattern } set: { notebook.paper = $0.model }
    }
}

#Preview("Editor · light") {
    let library = SampleLibrary()
    EditorScreen(notebook: library.notebooks[0], library: library)
}

#Preview("Editor · focus · dark") {
    let library = SampleLibrary()
    EditorScreen(notebook: library.notebooks[3], library: library, startsFocused: true)
        .preferredColorScheme(.dark)
}
