import Foundation
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
/// - `-seedNotebooks <n>`: if the on-disk library is empty, fill it with n mock-shaped notebooks.
/// - `-openNotebook <title>`: start in the editor for that notebook (`first` = most recent).
/// - `-focusMode YES`: with `-openNotebook`, start with the chrome collapsed.
/// - `-pagesOverview YES`: with `-openNotebook`, open the pages overview a few seconds after the notebook.
/// - `-newNotebook YES`: start with the new-notebook sheet up.
/// - `-toolbarDock top|bottom|left|right`: start with the toolbar at that dock.
/// - `-toolbarCompact YES|NO`: start with the toolbar pinched to the compact pill (or expanded).
/// - `-resetToolState YES`: forget persisted tool settings and toolbar placement (UI tests); also silences
///   one-time hints (the "hold a page edge to widen" caption, #129) so screenshots stay deterministic.
/// - `-penKind fountain|ballpoint|brush`, `-penWidth <0...4>`: pen family and width step (UI tests).
/// - `-eraserMode stroke|partial`: eraser mode (no eraser options popover yet).
/// - `-allowFingerDrawing YES`: fingers ink (one finger draws, two scroll) — the simulator has no Pencil.
/// - `-fixtureNotebook <pages>`: add a FixtureGen notebook ("Fixture <pages>p · seed 1") to the on-disk
///   library after launch (generated once; the package ID is deterministic).
/// - `-DesignSystemGallery YES`: DesignSystem gallery (#12).
@MainActor
enum LaunchOptions {
    static var showsNewNotebook: Bool {
        flag("newNotebook")
    }

    /// With `-openNotebook`: open the pages overview once the notebook is up (screenshots, timing).
    static var showsPagesOverview: Bool {
        flag("pagesOverview")
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

    /// Persisted `ToolState` with app defaults; DEBUG launch arguments override dock and compact.
    static func makeToolState() -> ToolState {
        #if DEBUG
            let defaults = UserDefaults.standard
            if flag("resetToolState") {
                defaults.removeObject(forKey: ToolState.defaultsKey)
            }
            let tools = ToolState(initial: .notespace)
            let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            if let raw = arguments["toolbarDock"] as? String, let dock = ToolbarDock(rawValue: raw) {
                tools.dock = dock
            }
            if arguments["toolbarCompact"] != nil {
                tools.isCompact = flag("toolbarCompact")
            }
            // No pen-family or width picker yet (#26): UI tests choose them here.
            if let raw = arguments["penKind"] as? String, let kind = PenSettings.kinds.first(where: { raw == "\($0)" }) {
                tools.pen.kind = kind
            }
            if arguments["penWidth"] != nil {
                tools.pen.widthIndex = defaults.integer(forKey: "penWidth")
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
