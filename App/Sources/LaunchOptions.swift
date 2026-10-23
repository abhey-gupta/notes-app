import Foundation

/// DEBUG launch arguments for screenshots and UI tests. Release builds always get the defaults.
///
/// - `-openNotebook <title>`: start in the editor for that notebook (`first` = most recent).
/// - `-focusMode YES`: with `-openNotebook`, start with the chrome collapsed.
/// - `-newNotebook YES`: start with the new-notebook sheet up.
/// - `-emptyLibrary YES`: no fixture notebooks.
/// - `-toolbarDock top|bottom|left|right`: editor toolbar dock, rendered statically (#26 adds drag/snap).
/// - `-DesignSystemGallery YES`: DesignSystem gallery (#12).
@MainActor
enum LaunchOptions {
    static var emptyLibrary: Bool {
        flag("emptyLibrary")
    }

    static var showsNewNotebook: Bool {
        flag("newNotebook")
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

    private static func flag(_ key: String) -> Bool {
        #if DEBUG
            UserDefaults.standard.bool(forKey: key)
        #else
            false
        #endif
    }
}
