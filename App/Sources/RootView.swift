import InkModel
import Perf
import SwiftUI
import Tools

/// Library → editor navigation (§8). The editor zooms out of the tapped cover or recent card.
struct RootView: View {
    @State private var library: any LibraryModel
    @State private var path: [EditorRoute]
    @State private var showsNewNotebook: Bool
    /// App-wide tool choice and toolbar placement (§6); persisted, flushed when the scene backgrounds.
    @State private var tools = LaunchOptions.makeToolState()
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var zoom

    #if DEBUG
        @State private var showsGallery = UserDefaults.standard.bool(forKey: "DesignSystemGallery")
    #endif

    /// - Parameter library: Defaults to the on-disk library (or a DEBUG launch-argument one); previews pass a sample.
    init(library: (any LibraryModel)? = nil) {
        let library = library ?? LaunchOptions.makeLibrary()
        _library = State(initialValue: library)
        _path = State(initialValue: LaunchOptions.initialPath(in: library))
        _showsNewNotebook = State(initialValue: LaunchOptions.showsNewNotebook)
    }

    var body: some View {
        NavigationStack(path: $path) {
            LibraryScreen(library: library, zoom: zoom, showsNewNotebook: $showsNewNotebook, showsGallery: galleryBinding) { route in
                OpenTrace.begin()
                path.append(route)
            }
            .navigationDestination(for: EditorRoute.self) { route in
                if let notebook = library.notebook(id: route.id) {
                    EditorScreen(notebook: notebook, library: library, tools: tools, startsFocused: route.startsFocused)
                        .navigationTransition(.zoom(sourceID: route.transitionID, in: zoom))
                }
            }
        }
        // After the first frame: finish a slow/rebuilding index load, purge old trash.
        .task { await library.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                tools.flush()
            }
        }
        #if DEBUG
        .fullScreenCover(isPresented: $showsGallery) {
            DesignSystemGallery()
        }
        #endif
    }

    private var galleryBinding: Binding<Bool>? {
        #if DEBUG
            $showsGallery
        #else
            nil
        #endif
    }
}

/// Push target for the editor. `source` picks which thumbnail the zoom transition grows from.
struct EditorRoute: Hashable {
    enum Source: Hashable {
        case recent, cover
    }

    let id: NotebookID
    var source: Source = .cover
    var startsFocused = false

    var transitionID: TransitionID {
        TransitionID(id: id, source: source)
    }

    struct TransitionID: Hashable {
        let id: NotebookID
        let source: Source
    }
}

/// `notebook.open` signpost (§11): tap → the first display frame after page 1's strokes reached the engine
/// (`NotebookSession`). The engine-side `canvas.firstSharpTile` lands with the tile cache (#22).
@MainActor
enum OpenTrace {
    private static var interval: SignpostInterval?
    /// Started by Create: the push that follows keeps the running interval.
    private static var creating = false

    /// Create tapped: one interval through package write to page one's first frame (#36, < 150 ms).
    static func beginCreate() {
        begin()
        creating = true
    }

    static func begin() {
        guard !creating else {
            creating = false
            return
        }
        interval?.end()
        interval = Signpost.notebookOpen.begin()
    }

    static func end() {
        interval?.end()
        interval = nil
        creating = false
    }

    /// Create failed: drop the interval unreported.
    static func cancel() {
        interval = nil
        creating = false
    }
}

#Preview("Library · light") {
    RootView(library: SampleLibrary())
}

#Preview("Library · dark") {
    RootView(library: SampleLibrary())
        .preferredColorScheme(.dark)
}
