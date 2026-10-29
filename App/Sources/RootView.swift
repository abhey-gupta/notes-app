import DesignSystem
import InkModel
import os
import Perf
import SwiftUI
import Tools

/// Library → editor navigation (§8). The editor zooms out of the tapped cover or recent card; the notebook
/// becomes (or already is) a tab (#191).
struct RootView: View {
    @State private var library: any LibraryModel
    @State private var path: [EditorRoute]
    @State private var showsNewNotebook: Bool
    /// A PDF in the import sheet (#119): from the library's + menu, or opened in Notespace from elsewhere.
    @State private var pdfImport: PDFImportRequest?
    /// App-wide tool choice and toolbar placement (§6); persisted, flushed when the scene backgrounds.
    @State private var tools: ToolState
    /// Open editor tabs (#191), persisted; their sessions live only while the editor is up.
    @State private var tabs: TabsModel
    @State private var sessions: SessionStore
    /// Settings → "Hide status bar" (#191): the bar sits flush at the top edge.
    @AppStorage(SettingsView.hidesStatusBarKey) private var hidesStatusBar = false
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var zoom

    #if DEBUG
        @State private var showsGallery = UserDefaults.standard.bool(forKey: "DesignSystemGallery")
    #endif

    /// - Parameter library: Defaults to the on-disk library (or a DEBUG launch-argument one); previews pass a sample.
    init(library: (any LibraryModel)? = nil) {
        let library = library ?? LaunchOptions.makeLibrary()
        let tools = LaunchOptions.makeToolState()
        let tabs = LaunchOptions.makeTabs()
        let path = LaunchOptions.initialPath(in: library)
        for route in path {
            tabs.open(route.id)
        }
        _library = State(initialValue: library)
        _tools = State(initialValue: tools)
        _tabs = State(initialValue: tabs)
        _sessions = State(initialValue: SessionStore(library: library, tools: tools))
        _path = State(initialValue: path)
        _showsNewNotebook = State(initialValue: LaunchOptions.showsNewNotebook)
        _pdfImport = State(initialValue: LaunchOptions.pdfImport)
    }

    var body: some View {
        NavigationStack(path: $path) {
            LibraryScreen(
                library: library, zoom: zoom, tabs: tabs, showsNewNotebook: $showsNewNotebook, pdfImport: $pdfImport,
                showsGallery: galleryBinding
            ) { route in
                OpenTrace.begin()
                open(route)
            }
            .navigationDestination(for: EditorRoute.self) { route in
                if let notebook = library.notebook(id: route.id) {
                    EditorScreen(
                        notebook: notebook, library: library, tools: tools, tabs: tabs, sessions: sessions,
                        startsFocused: route.startsFocused
                    )
                    .navigationTransition(.zoom(sourceID: route.transitionID, in: zoom))
                }
            }
        }
        .statusBarHidden(hidesStatusBar)
        // Compact chrome and room for the window controls (#118).
        .readsChromeLayout()
        // Library and editor chrome follow Dynamic Type up to AX1; capsules grow with it (#45).
        .dynamicTypeSize(...DynamicTypeSize.chromeLimit)
        // After the first frame: finish a slow/rebuilding index load, purge old trash, warm up the canvas.
        .task {
            await library.start()
            EditorWarmUp.run()
        }
        // Files / share sheet "Open in Notespace" (PDF document type): back to the library, import sheet up.
        .onOpenURL { url in
            guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else { return }
            do {
                let request = try PDFInbox.stage(url)
                path = []
                showsNewNotebook = false
                pdfImport = request
            } catch {
                Logger(subsystem: "com.abhey.notespace", category: "library")
                    .error("open PDF: \(error.localizedDescription, privacy: .public)")
            }
        }
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

    /// The notebook becomes the showing tab (closing the coldest one past the limit) and the editor opens on it.
    private func open(_ route: EditorRoute) {
        if let evicted = tabs.open(route.id) {
            sessions.close(evicted)
        }
        path.append(route)
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
        /// A notebook row in the library sidebar (#117).
        case recent, cover, sidebar
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
/// (`NotebookSession`); `canvas.firstSharpTile`: the same tap → the first frame after page 1 showed sharp
/// ink (its raster landed or its canvas drew; until then the page's thumbnail stands in, #43).
@MainActor
enum OpenTrace {
    private static var interval: SignpostInterval?
    private static var sharpInterval: SignpostInterval?
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
        sharpInterval?.end()
        sharpInterval = Signpost.canvasFirstSharpTile.begin()
    }

    static func end() {
        interval?.end()
        interval = nil
        creating = false
    }

    /// Page 1 shows sharp ink.
    static func sharp() {
        sharpInterval?.end()
        sharpInterval = nil
    }

    /// Create failed: drop the intervals unreported.
    static func cancel() {
        interval = nil
        sharpInterval = nil
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
