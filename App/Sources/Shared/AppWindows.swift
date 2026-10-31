import InkModel
import SwiftUI
import Tools
import UIKit

/// What the app's windows share (#175): one library and one tool state (a single writer of the index and
/// the settings), and which window has each notebook open, so a notebook is never open in two windows
/// at once (two writers to one package). Opening one that another window has brings that window forward
/// on it instead.
@MainActor
enum AppWindows {
    static let library: any LibraryModel = LaunchOptions.makeLibrary()
    static let tools: ToolState = LaunchOptions.makeToolState()
    /// Sync through a Files folder (#225); `nil` for in-memory libraries.
    static let sync: SyncModel? = LaunchOptions.makeSync(for: library)

    private struct Window {
        weak var sessions: SessionStore?
    }

    private static var windows: [Window] = []

    /// A window's editor sessions (its `RootView`).
    static func register(_ sessions: SessionStore) {
        windows.removeAll { $0.sessions == nil }
        windows.append(Window(sessions: sessions))
    }

    /// Another window is up already (a new one starts without tabs).
    static var hasWindow: Bool {
        windows.contains { $0.sessions != nil }
    }

    /// The other window that has `id` open, if any.
    static func window(holding id: NotebookID, besides sessions: SessionStore) -> SessionStore? {
        windows.lazy.compactMap(\.sessions).first { $0 !== sessions && $0.holds(id) }
    }
}

/// Reports the window scene a view is in (to bring that window forward).
struct SceneProbe: UIViewRepresentable {
    let onChange: (UIWindowScene?) -> Void

    func makeUIView(context _: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ProbeView, context _: Context) {
        view.onChange = onChange
    }

    final class ProbeView: UIView {
        var onChange: ((UIWindowScene?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onChange?(window?.windowScene)
        }
    }
}
