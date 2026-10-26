import SwiftUI
import UIKit

/// Compact chrome (#118): iPhone, and iPad windows narrower than ~600 pt (Split View, Slide Over, narrow
/// Stage Manager). The library's folders become a full-screen sheet; the editor's tools sit in a bottom bar.
enum CompactLayout {
    static let maxWidth: CGFloat = 600
    /// Library page margin and covers grid in compact chrome.
    static let libraryMargin: CGFloat = 20
    static let coverColumns = 3
    static let coverSpacing: CGFloat = 14

    /// `width` is `nil` before the window has been measured.
    @MainActor
    static func isCompact(width: CGFloat?, sizeClass: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .phone || sizeClass == .compact || (width ?? .infinity) < maxWidth
    }
}

extension EnvironmentValues {
    /// Set once by `RootView` from the window width.
    @Entry var isCompactLayout = false
}
