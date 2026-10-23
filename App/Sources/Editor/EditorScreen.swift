import DesignSystem
import SwiftUI
import Tools

/// Full-screen editor (§7): desk, canvas (placeholder until #21), floating glass chrome.
struct EditorScreen: View {
    let library: any LibraryModel
    let tools: ToolState
    @State private var notebook: NotebookSummary
    @State private var state: EditorState
    @State private var currentPage: Int? = 0

    @Environment(\.dismiss) private var dismiss

    init(notebook: NotebookSummary, library: any LibraryModel, tools: ToolState, startsFocused: Bool = false) {
        self.library = library
        self.tools = tools
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
                tools: tools,
                currentPage: $currentPage
            )
            ToolbarHost(
                tools: tools,
                state: state,
                title: notebook.title,
                paper: paperBinding,
                pattern: patternBinding,
                page: (min((currentPage ?? 0) + 1, notebook.pageCount), notebook.pageCount),
                onBack: { dismiss() },
                onReselectTool: { _ in } // tool options popover lands with #27
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
    EditorScreen(notebook: library.notebooks[0], library: library, tools: ToolState(initial: .notespace))
}

#Preview("Editor · focus · dark") {
    let library = SampleLibrary()
    EditorScreen(notebook: library.notebooks[3], library: library, tools: ToolState(initial: .notespace), startsFocused: true)
        .preferredColorScheme(.dark)
}
