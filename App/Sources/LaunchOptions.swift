import Foundation
import InkModel
import Library
import Tools

/// DEBUG launch arguments for screenshots and UI tests. Release builds always get the defaults, except
/// `-libraryRoot`, which simulator Release builds also honor (perf tests run Release), and flags,
/// `-fixtureNotebook` and `-openNotebook` in `PERF_FIXTURES` Release builds (device stress runs, #44).
///
/// - `-sampleLibrary YES`: in-memory mock notebooks (`SampleLibrary`) instead of the on-disk library.
/// - `-emptyLibrary YES`: in-memory library with no notebooks.
/// - `-resetLibrary YES`: erase the on-disk library (index, packages, trash) before launch.
/// - `-libraryRoot <path>`: use the library under path (`Documents/Notebooks`, `Application Support/Library`)
///   instead of the container's. Perf tests point it at fixture libraries the test runner builds (#15).
/// - `-syncRoot <path>`: sync through this folder (created if missing) instead of a bookmarked one; no Files
///   picker (#225 UI tests). Simulator Release builds honor it too.
/// - `-syncHoldSeconds <s>`: the cards' "From ‹device›" tag and the adopt card stay this long (UI tests poll
///   slower than their 2 s / 1.5 s).
/// - `-seedNotebooks <n>`: if the on-disk library is empty, fill it with n mock-shaped notebooks.
/// - `-openNotebook <title>`: start in the editor for that notebook (`first` = most recent).
/// - `-focusMode YES`: with `-openNotebook`, start in focus mode (compact pill, other chrome hidden).
/// - `-pagesOverview YES`: with `-openNotebook`, open the pages overview a few seconds after the notebook.
/// - `-insertSamplePhoto YES`: with `-openNotebook`, place a generated photo on the page once the notebook is
///   up, as the toolbar flyout would (#157; the system picker can't be driven by UI tests).
/// - `-newNotebook YES`: start with the new-notebook sheet up.
/// - `-settings YES`: start with Settings up (#228 screenshots).
/// - `-importSamplePDF YES`: start with the import sheet up on a generated 24-page PDF (#119).
/// - `-toolbarDock top|bottom|left|right`: start with the toolbar at that dock.
/// - `-resetToolState YES`: forget persisted tool settings, toolbar placement, open tabs and the library
///   sidebar's state (UI tests); also silences one-time hints (the "hold a page edge to widen" caption, #129)
///   so screenshots stay deterministic.
/// - `-penKind fountain|ballpoint|brush`, `-penSize <mm>`: pen family and size (UI tests).
/// - `-eraserMode stroke|partial`: eraser mode (no eraser options popover yet).
/// - `-allowFingerDrawing YES`: fingers ink (one finger draws, two scroll) — the simulator has no Pencil.
/// - `-fixtureNotebook <pages>`: add a FixtureGen notebook ("Fixture <pages>p · seed 1") to the on-disk
///   library after launch (generated once; the package ID is deterministic).
/// - `-compactChrome YES`: compact (iPhone / narrow window) chrome at any width (#118 UI tests).
/// - `-DesignSystemGallery YES`: DesignSystem gallery (#12).
@MainActor
enum LaunchOptions {
    static var showsNewNotebook: Bool {
        flag("newNotebook")
    }

    static var showsSettings: Bool {
        flag("settings")
    }

    /// `-importSamplePDF YES`: a generated PDF in the import sheet (the system Files picker can't be scripted).
    static var pdfImport: PDFImportRequest? {
        #if DEBUG
            flag("importSamplePDF") ? PDFInbox.sample() : nil
        #else
            nil
        #endif
    }

    /// With `-openNotebook`: open the pages overview once the notebook is up (screenshots, timing).
    static var showsPagesOverview: Bool {
        flag("pagesOverview")
    }

    /// With `-openNotebook`: insert a generated photo once the notebook is up (#157 UI tests).
    static var insertsSamplePhoto: Bool {
        flag("insertSamplePhoto")
    }

    /// Compact chrome whatever the window width (#118; the UI tests run on an iPad simulator).
    static var forcesCompactChrome: Bool {
        flag("compactChrome")
    }

    /// One-time hints may show (off under `-resetToolState`, i.e. in UI tests).
    static var showsHints: Bool {
        !flag("resetToolState")
    }

    /// "Draw with finger" (no user setting yet; ARCHITECTURE.md §15.4 default off).
    static var allowsFingerDrawing: Bool {
        flag("allowFingerDrawing")
    }

    /// Pages of the FixtureGen notebook to add, or 0.
    static var fixtureNotebookPages: Int {
        #if DEBUG || PERF_FIXTURES
            max(UserDefaults.standard.integer(forKey: "fixtureNotebook"), 0)
        #else
            0
        #endif
    }

    static var seedNotebooks: Int {
        #if DEBUG
            UserDefaults.standard.integer(forKey: "seedNotebooks")
        #else
            0
        #endif
    }

    /// The on-disk library, or a DEBUG in-memory one.
    static func makeLibrary() -> any LibraryModel {
        #if DEBUG
            if flag("sampleLibrary") || flag("emptyLibrary") {
                return SampleLibrary(empty: flag("emptyLibrary"))
            }
            if flag("resetLibrary") {
                StoreLibrary.erase()
            }
        #endif
        #if DEBUG || targetEnvironment(simulator)
            if let root = UserDefaults.standard.string(forKey: "libraryRoot") {
                return StoreLibrary(locations: LibraryLocations(root: URL(filePath: root, directoryHint: .isDirectory)))
            }
        #endif
        return StoreLibrary()
    }

    /// `-syncHoldSeconds`: how long sync's transient card tag and adopt card stay; `nil` for the defaults.
    static var syncHold: Duration? {
        #if DEBUG
            let seconds = UserDefaults.standard.double(forKey: "syncHoldSeconds")
            return seconds > 0 ? .seconds(seconds) : nil
        #else
            nil
        #endif
    }

    /// Sync for the on-disk library (none for in-memory ones); `-syncRoot` fixes its folder.
    static func makeSync(for library: any LibraryModel) -> SyncModel? {
        guard let library = library as? StoreLibrary else { return nil }
        #if DEBUG || targetEnvironment(simulator)
            if let root = UserDefaults.standard.string(forKey: "syncRoot") {
                let url = URL(filePath: root, directoryHint: .isDirectory)
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return SyncModel(library: library, fixedRoot: url)
            }
        #endif
        return SyncModel(library: library)
    }

    static func initialPath(in library: any LibraryModel) -> [EditorRoute] {
        #if DEBUG || PERF_FIXTURES
            guard let title = UserDefaults.standard.string(forKey: "openNotebook") else { return [] }
            let notebook = title == "first"
                ? library.notebooks.first
                : library.notebooks.first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }
            guard let notebook else { return [] }
            return [EditorRoute(id: notebook.id, startsFocused: flag("focusMode"))]
        #else
            return []
        #endif
    }

    /// Persisted open tabs (#191); `-resetToolState` forgets them.
    /// `-splitNotebook <title>` (DEBUG): the editor opens split, this notebook beside `-openNotebook`'s (#175).
    static func splitRoute(in library: any LibraryModel) -> NotebookID? {
        #if DEBUG
            guard let title = UserDefaults.standard.string(forKey: "splitNotebook") else { return nil }
            return library.notebooks.first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }?.id
        #else
            nil
        #endif
    }

    static func makeTabs() -> TabsModel {
        #if DEBUG
            if flag("resetToolState") {
                TabsModel.reset()
            }
        #endif
        return TabsModel(restores: !AppWindows.hasWindow)
    }

    /// Persisted `ToolState` with app defaults; DEBUG launch arguments override dock and tools.
    static func makeToolState() -> ToolState {
        #if DEBUG
            let defaults = UserDefaults.standard
            if flag("resetToolState") {
                defaults.removeObject(forKey: ToolState.defaultsKey)
                defaults.removeObject(forKey: LibraryScreen.sidebarHiddenKey)
                defaults.removeObject(forKey: LibraryScreen.openFoldersKey)
            }
            let tools = ToolState(initial: .notespace)
            let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            if let raw = arguments["toolbarDock"] as? String, let dock = ToolbarDock(rawValue: raw) {
                tools.dock = dock
            }
            // No pen-family or width picker yet (#26): UI tests choose them here.
            if let raw = arguments["penKind"] as? String, let kind = PenSettings.kinds.first(where: { raw == "\($0)" }) {
                tools.pen.kind = kind
            }
            if arguments["penSize"] != nil {
                tools.pen.size.millimetres = defaults.float(forKey: "penSize")
            }
            if let raw = arguments["eraserMode"] as? String, let mode = EraserSettings.Mode(rawValue: raw) {
                tools.eraser.mode = mode
            }
            return tools
        #else
            return ToolState(initial: .notespace)
        #endif
    }

    private static func flag(_ key: String) -> Bool {
        #if DEBUG || PERF_FIXTURES
            UserDefaults.standard.bool(forKey: key)
        #else
            false
        #endif
    }
}
