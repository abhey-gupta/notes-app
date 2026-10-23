import InkModel
import Perf
import SwiftUI

/// Library → editor navigation (§8). The editor zooms out of the tapped cover or recent card.
struct RootView: View {
    @State private var library: any LibraryModel
    @State private var path: [EditorRoute]
    @State private var showsNewNotebook: Bool
    @Namespace private var zoom

    #if DEBUG
        @State private var showsGallery = UserDefaults.standard.bool(forKey: "DesignSystemGallery")
    #endif

    init() {
        let library = SampleLibrary(empty: LaunchOptions.emptyLibrary)
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
                    EditorScreen(notebook: notebook, library: library, startsFocused: route.startsFocused)
                        .navigationTransition(.zoom(sourceID: route.transitionID, in: zoom))
                }
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

/// `notebook.open` signpost: tap → editor's first appearance (§11; canvas.firstSharpTile lands with #21).
@MainActor
enum OpenTrace {
    private static var interval: SignpostInterval?

    static func begin() {
        interval?.end()
        interval = Signpost.notebookOpen.begin()
    }

    static func end() {
        interval?.end()
        interval = nil
    }
}

#Preview("Library · light") {
    RootView()
}

#Preview("Library · dark") {
    RootView()
        .preferredColorScheme(.dark)
}
