#if canImport(UIKit)
    import CoreGraphics
    import UIKit

    /// Where the reader left a notebook: the content point under the top-left of the chrome-free area and
    /// the zoom, so reopening lands on the same spot. A fitted or edge-to-edge zoom is kept as such, so a
    /// notebook left in portrait reopens fitted in landscape.
    public struct ReadingPosition: Codable, Hashable, Sendable {
        public enum Width: String, Codable, Sendable {
            /// Free zoom (``ReadingPosition/zoom``).
            case zoomed
            /// ``CanvasHostView/fitZoom(pageWidth:viewWidth:)``.
            case fitted
            /// ``CanvasHostView/fillZoom``: edge to edge (#130).
            case filled
        }

        /// Unzoomed content point at the top-left of the viewport, below the top inset.
        public var origin: CGPoint
        public var zoom: CGFloat
        public var width: Width

        public init(origin: CGPoint, zoom: CGFloat, width: Width = .zoomed) {
            self.origin = origin
            self.zoom = zoom
            self.width = width
        }
    }

    public extension CanvasHostView {
        /// The current position; `nil` before the first layout.
        var readingPosition: ReadingPosition? {
            let z = scrollView.zoomScale
            guard lastBoundsSize != .zero, z > 0 else { return nil }
            let offset = scrollView.contentOffset
            let width: ReadingPosition.Width = abs(z - fitZoom) < 0.001 ? .fitted : abs(z - fillZoom) < 0.001 ? .filled : .zoomed
            return ReadingPosition(origin: CGPoint(x: offset.x / z, y: (offset.y + scrollView.contentInset.top) / z), zoom: z, width: width)
        }

        /// Moves to `position` (clamped to the content); before the first layout, on it. Set ``layout`` first.
        func restore(_ position: ReadingPosition) {
            guard lastBoundsSize != .zero else {
                pendingPosition = position
                return
            }
            pendingPosition = nil
            let zoom = switch position.width {
            case .zoomed: position.zoom
            case .fitted: fitZoom
            case .filled: fillZoom
            }
            setZoom(min(max(zoom, Self.minimumZoom), Self.maximumZoom))
            updateInsets()
            let z = scrollView.zoomScale
            let inset = scrollView.contentInset
            let size = scrollView.bounds.size
            let maxX = scrollView.contentSize.width + inset.right - size.width
            let x = maxX <= -inset.left || position.width != .zoomed
                ? centeredOffsetX()
                : min(max(position.origin.x * z, -inset.left), maxX)
            let maxY = max(scrollView.contentSize.height + inset.bottom - size.height, -inset.top)
            let y = min(max(position.origin.y * z - inset.top, -inset.top), maxY)
            scrollView.contentOffset = CGPoint(x: x, y: y)
            viewportDidChange()
        }
    }
#endif
