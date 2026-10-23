#if canImport(UIKit)
    import SwiftUI

    /// SwiftUI wrapper for a ``CanvasHostView``. The host is created and owned by the caller (the editor's
    /// session keeps it for the notebook's lifetime); read ``CanvasHostView/state`` for the current page
    /// and zoom.
    public struct CanvasView: UIViewRepresentable {
        private let host: CanvasHostView

        /// Shows `host`.
        public init(host: CanvasHostView) {
            self.host = host
        }

        public func makeUIView(context _: Context) -> CanvasHostView {
            host
        }

        public func updateUIView(_: CanvasHostView, context _: Context) {}
    }
#endif
