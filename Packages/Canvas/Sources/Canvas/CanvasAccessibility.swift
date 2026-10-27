#if canImport(UIKit)
    import UIKit

    /// VoiceOver's view of the canvas (#45): one "Drawing area" element over the visible rect instead of the
    /// pages, canvases and rasters under it, plus the add-page button. Its value is the current page ("Page 3
    /// of 11, 12 strokes"); a three-finger swipe turns the page; the host's custom actions (undo, redo, …)
    /// hang off it.
    @MainActor
    final class DrawingAccessibilityElement: UIAccessibilityElement {
        private weak var scrollView: CanvasScrollView?

        init(scrollView: CanvasScrollView) {
            self.scrollView = scrollView
            super.init(accessibilityContainer: scrollView)
            accessibilityIdentifier = "drawingArea"
        }

        override var accessibilityLabel: String? {
            get { "Drawing area" }
            set { _ = newValue }
        }

        override var accessibilityHint: String? {
            get { "Draw with Apple Pencil. Swipe up or down with three fingers to turn pages." }
            set { _ = newValue }
        }

        override var accessibilityValue: String? {
            get {
                guard let scrollView else { return nil }
                let parts = [scrollView.pageLabel?(), scrollView.valueProvider?(), scrollView.widthLabel?()].compactMap(\.self)
                return parts.isEmpty ? nil : parts.joined(separator: ", ")
            }
            set { _ = newValue }
        }

        override var accessibilityFrame: CGRect {
            get {
                guard let scrollView else { return .zero }
                return UIAccessibility.convertToScreenCoordinates(scrollView.bounds, in: scrollView)
            }
            set { _ = newValue }
        }

        /// A screenful per swipe; announces the page it lands on.
        override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
            guard let scrollView else { return false }
            let step = scrollView.bounds.height * 0.9
            let delta: CGFloat = switch direction {
            case .up, .next: step
            case .down, .previous: -step
            default: 0
            }
            guard delta != 0 else { return false }
            let inset = scrollView.adjustedContentInset
            let maxY = max(scrollView.contentSize.height + inset.bottom - scrollView.bounds.height, -inset.top)
            let y = min(max(scrollView.contentOffset.y + delta, -inset.top), maxY)
            guard abs(y - scrollView.contentOffset.y) > 0.5 else { return false }
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: false)
            UIAccessibility.post(notification: .pageScrolled, argument: scrollView.pageLabel?())
            return true
        }
    }

    public extension CanvasHostView {
        /// VoiceOver custom actions on the drawing area (undo, redo, …; #45).
        var drawingAccessibilityActions: [UIAccessibilityCustomAction] {
            get { (canvasScrollView as? CanvasScrollView)?.drawingElement.accessibilityCustomActions ?? [] }
            set { (canvasScrollView as? CanvasScrollView)?.drawingElement.accessibilityCustomActions = newValue }
        }
    }
#endif
