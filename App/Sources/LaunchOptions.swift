import Foundation
import Tools

/// DEBUG launch arguments for screenshots and UI tests. Release builds always get the defaults.
///
/// - `-sampleLibrary YES`: in-memory mock notebooks (`SampleLibrary`) instead of the on-disk library.
/// - `-emptyLibrary YES`: in-memory library with no notebooks.
/// - `-resetLibrary YES`: erase the on-disk library (index, packages, trash) before launch.
/// - `-seedNotebooks <n>`: if the on-disk library is empty, fill it with n mock-shaped notebooks.
/// - `-openNotebook <title>`: start in the editor for that notebook (`first` = most recent).
/// - `-focusMode YES`: with `-openNotebook`, start with the chrome collapsed.
/// - `-newNotebook YES`: start with the new-notebook sheet up.
/// - `-toolbarDock top|bottom|left|right`: start with the toolbar at that dock.
/// - `-toolbarCompact YES|NO`: start with the toolbar pinched to the compact pill (or expanded).
/// - `-resetToolState YES`: forget persisted tool settings and toolbar placement (UI tests).
/// - `-DesignSystemGallery YES`: DesignSystem gallery (#12).
@MainActor
enum LaunchOptions {
    static var showsNewNotebook: Bool {
        flag("newNotebook")
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
        return StoreLibrary()
    }

    static func initialPath(in library: any LibraryModel) -> [EditorRoute] {
        #if DEBUG
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
            return tools
        #else
            return ToolState(initial: .notespace)
        #endif
    }

    private static func flag(_ key: String) -> Bool {
        #if DEBUG
            UserDefaults.standard.bool(forKey: key)
        #else
            false
        #endif
    }
}
