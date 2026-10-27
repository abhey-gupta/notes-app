#if canImport(UIKit)
    import InkEngine
    import Observation
    import UIKit

    /// Host callbacks, on the main actor.
    @MainActor
    public protocol CanvasHostViewDelegate: AnyObject {
        /// The visible pages moved to a new ``PageWindow`` (not called for scrolls within the same pages).
        func canvasHost(_ host: CanvasHostView, didChange window: PageWindow)
        /// A finger started scrolling or zooming (focus mode restores the chrome, §7).
        func canvasHostWillBeginNavigating(_ host: CanvasHostView)
        /// The add-page button under the last page was tapped.
        func canvasHostDidRequestNewPage(_ host: CanvasHostView)
        /// The last touch on the canvas lifted (end of a Pencil gesture: eraser undo grouping, focus mode).
        func canvasHostDidLiftAllTouches(_ host: CanvasHostView)
        /// A finger took hold of a page edge (#129): find how far ink reaches across the notebook and
        /// answer with ``CanvasHostView/setInkExtent(_:)``, so the edge can't be dragged over ink.
        func canvasHostDidBeginSideGrab(_ host: CanvasHostView)
        /// A side drag ended: widen (or narrow) every page by `change`, then call
        /// ``CanvasHostView/finishSideGrab(layout:extensions:)`` with the new layout and, once the pages
        /// are drawn, ``CanvasHostView/endWidening()``.
        func canvasHost(_ host: CanvasHostView, didWidenPages change: PageWidthChange)
    }

    public extension CanvasHostViewDelegate {
        func canvasHostDidBeginSideGrab(_ host: CanvasHostView) {
            host.setInkExtent(nil)
        }

        func canvasHost(_ host: CanvasHostView, didWidenPages change: PageWidthChange) {
            var extensions = host.pageExtension
            extensions[change.side] += change.added
            let width = host.layout.pageSize.width + change.added
            host.finishSideGrab(
                layout: PageLayout(
                    pageIDs: host.layout.pageIDs, pageSize: CGSize(width: width, height: host.layout.pageSize.height),
                    gap: host.layout.gap, footer: host.layout.footer
                ),
                extensions: extensions
            )
            host.endWidening()
        }
    }

    /// A view the host keeps above the ink engine (``CanvasHostView/overlay``), pinned to the visible rect
    /// (view space of ``InkEngine/Viewport``), so its chrome doesn't zoom with the pages.
    @MainActor
    public protocol CanvasOverlay: UIView {
        /// Every scroll/zoom frame, after the engine got the same viewport.
        func canvasHost(_ host: CanvasHostView, didUpdate viewport: Viewport)
    }

    extension CanvasHostView {
        func overlayDidChange(from old: (any CanvasOverlay)?) {
            guard old !== overlay else { return }
            old?.removeFromSuperview()
            guard let overlay else { return }
            canvasScrollView.insertSubview(overlay, aboveSubview: contentView)
            updateOverlay(viewport)
        }

        /// Pins the overlay to the visible rect and passes on the viewport.
        func updateOverlay(_ viewport: Viewport) {
            guard let overlay else { return }
            if overlay.frame != canvasScrollView.bounds {
                overlay.frame = canvasScrollView.bounds
            }
            overlay.canvasHost(self, didUpdate: viewport)
        }
    }

    /// What SwiftUI shows about the viewport: the page indicator's page and the zoom.
    @MainActor
    @Observable
    public final class CanvasViewportState {
        /// Page nearest the viewport center (0-based), the "3" in "3 of 11".
        public internal(set) var currentPage = 0
        /// Pages in the layout.
        public internal(set) var pageCount = 0
        /// Scroll view zoom (1 = page points).
        public internal(set) var zoomScale: CGFloat = 1

        public init() {}
    }

    extension CanvasHostView {
        /// The glass "+ Add page" capsule under the last page.
        static func makeAddPageButton() -> UIButton {
            var button = UIButton.Configuration.glass()
            button.image = UIImage(systemName: "plus")
            button.title = "Add page"
            button.imagePadding = 6
            button.cornerStyle = .capsule
            button.baseForegroundColor = .secondaryLabel
            button.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            button.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.systemFont(ofSize: 14, weight: .medium)
                return attributes
            }
            return UIButton(configuration: button)
        }
    }

    /// The library pushes the editor with a SwiftUI zoom transition whose interactive dismissal (swipe down
    /// anywhere, pinch, leading-edge pan) is installed on the editor's hosting view and would steal
    /// Pencil strokes and scrolls on the canvas; SwiftUI has no switch for it (`interactiveDismissDisabled`
    /// only covers sheets). While the canvas is in a window it disables the swipe-down and pinch
    /// recognizers and limits the edge pan to fingers (back stays one edge swipe or the back button);
    /// they're restored when it leaves. Recognizers are found by the `name` UIKit gives them
    /// (`com.apple.UIKit.ZoomInteractiveDismiss…`); if a release renames them this is a no-op and
    /// `CanvasTests.testDownwardDragAtTopDoesNotDismissEditor` fails.
    @MainActor
    final class DismissGestureClaim {
        private struct Claimed {
            let recognizer: UIGestureRecognizer
            let wasEnabled: Bool
            let touchTypes: [NSNumber]
        }

        private static let prefix = "com.apple.UIKit.ZoomInteractiveDismiss"
        private var claimed: [Claimed] = []

        /// Claims the dismiss recognizers on `view`'s ancestors (idempotent).
        func claim(above view: UIView) {
            var ancestor = view.superview
            while let current = ancestor {
                for recognizer in current.gestureRecognizers ?? [] {
                    guard let name = recognizer.name, name.hasPrefix(Self.prefix),
                          !claimed.contains(where: { $0.recognizer === recognizer }) else { continue }
                    claimed.append(Claimed(
                        recognizer: recognizer,
                        wasEnabled: recognizer.isEnabled,
                        touchTypes: recognizer.allowedTouchTypes
                    ))
                    if name.hasSuffix("LeadingEdgePan") {
                        recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                    } else {
                        recognizer.isEnabled = false
                    }
                }
                ancestor = current.superview
            }
        }

        /// Restores every claimed recognizer.
        func release() {
            for entry in claimed {
                entry.recognizer.isEnabled = entry.wasEnabled
                entry.recognizer.allowedTouchTypes = entry.touchTypes
            }
            claimed = []
        }
    }

    /// The canvas scroll view: label and value computed when asked (UI tests). VoiceOver sees its
    /// ``DrawingAccessibilityElement`` instead of the pages, then its visible buttons (add page; #45).
    @MainActor
    final class CanvasScrollView: UIScrollView {
        var pageLabel: (() -> String?)?
        var valueProvider: (() -> String?)?
        /// "Widened to 150 %" once the pages are wider than the original (#129).
        var widthLabel: (() -> String?)?
        private(set) lazy var drawingElement = DrawingAccessibilityElement(scrollView: self)

        override var accessibilityElements: [Any]? {
            get { [drawingElement] + subviews.filter { $0 is UIButton && !$0.isHidden && $0.alpha > 0 } }
            set { _ = newValue }
        }

        override var accessibilityLabel: String? {
            get { pageLabel?() ?? super.accessibilityLabel }
            set { super.accessibilityLabel = newValue }
        }

        override var accessibilityValue: String? {
            get { valueProvider?() ?? super.accessibilityValue }
            set { super.accessibilityValue = newValue }
        }

        /// Applies this scroll view's own pinch if UIKit didn't. With a `PKCanvasView` (itself a scroll
        /// view) under the fingers, `UIScrollView` can recognize the pinch and report its scale (seeded with
        /// the current zoom) yet leave `zoomScale` alone (#71: "pinch zoomed only the stroke"). Zooms about
        /// the pinch centroid, within the zoom range; a no-op when UIKit already zoomed.
        @objc func applyPinch(_ pinch: UIPinchGestureRecognizer) {
            guard pinch.state == .changed, pinch.numberOfTouches >= 2 else { return }
            let old = zoomScale
            let target = min(max(pinch.scale, minimumZoomScale), maximumZoomScale)
            guard old > 0, abs(target - old) > 0.0001 else { return }
            let location = pinch.location(in: self)
            let onScreen = CGPoint(x: location.x - contentOffset.x, y: location.y - contentOffset.y)
            let anchor = CGPoint(x: location.x / old, y: location.y / old) // content point under the fingers
            setZoomScale(target, animated: false)
            let maxX = max(contentSize.width + contentInset.right - bounds.width, -contentInset.left)
            let maxY = max(contentSize.height + contentInset.bottom - bounds.height, -contentInset.top)
            contentOffset = CGPoint(
                x: min(max(anchor.x * target - onScreen.x, -contentInset.left), maxX),
                y: min(max(anchor.y * target - onScreen.y, -contentInset.top), maxY)
            )
        }
    }

    /// Watches touches on the canvas without taking part in recognition (never recognizes, never delays or
    /// cancels touches, can't be prevented): reports Pencil contact, so the host can hand one-finger
    /// scrolling back to the scroll view, and the moment the last touch lifts.
    @MainActor
    final class TouchObserver: UIGestureRecognizer {
        var onPencil: (() -> Void)?
        var onAllLifted: (() -> Void)?
        var onBegan: (() -> Void)?
        private var active: Set<ObjectIdentifier> = []

        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        convenience init() {
            self.init(target: nil, action: nil)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with _: UIEvent) {
            onBegan?()
            if touches.contains(where: { $0.type == .pencil }) {
                onPencil?()
            }
            for touch in touches {
                active.insert(ObjectIdentifier(touch))
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with _: UIEvent) {
            lifted(touches)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with _: UIEvent) {
            lifted(touches)
        }

        override func reset() {
            super.reset()
            active = []
        }

        private func lifted(_ touches: Set<UITouch>) {
            for touch in touches {
                active.remove(ObjectIdentifier(touch))
            }
            guard active.isEmpty else { return }
            onAllLifted?()
            state = .failed
        }

        override func canPrevent(_: UIGestureRecognizer) -> Bool {
            false
        }

        override func canBePrevented(by _: UIGestureRecognizer) -> Bool {
            false
        }
    }
#endif
