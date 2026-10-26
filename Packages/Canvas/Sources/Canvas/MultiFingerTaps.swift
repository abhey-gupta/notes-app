#if canImport(UIKit)
    import InkEngine
    import QuartzCore
    import UIKit

    /// Two- and three-finger taps on the canvas (#121; the editor maps them to undo and redo). Fingers only;
    /// the recognizers run alongside the scroll view's pan and pinch and never delay or cancel touches, so
    /// scrolling, zooming, finger ink and the Pencil are untouched. ``MultiFingerTapRule`` drops taps that
    /// were slow, scrolled or zoomed, or came with a Pencil (palm).
    ///
    /// They replace the system's three-finger editing gestures on the canvas (``CanvasHostView``
    /// opts out of them), whose three-finger tap would otherwise open the shortcut bar too.
    @MainActor
    public final class MultiFingerTaps: NSObject, UIGestureRecognizerDelegate {
        /// A tap counted; the argument is the number of fingers (2 or 3).
        public var onTap: ((Int) -> Void)?

        private let two = UITapGestureRecognizer()
        private let three = UITapGestureRecognizer()
        private let observer = TapTouchObserver()
        private weak var scrollView: UIScrollView?
        private var began: TimeInterval = 0
        private var navigated = false

        override public init() {
            super.init()
            for (recognizer, fingers) in [(two, 2), (three, 3)] {
                recognizer.numberOfTouchesRequired = fingers
                recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                recognizer.cancelsTouchesInView = false
                recognizer.delaysTouchesEnded = false
                recognizer.delegate = self
                recognizer.addTarget(self, action: #selector(tapped(_:)))
            }
            // Fails as soon as the fingers lift with fewer than three touches: no wait.
            two.require(toFail: three)
            observer.onSequenceBegan = { [weak self] time in self?.sequenceBegan(at: time) }
        }

        /// Adds the recognizers to `host`'s scroll view once.
        public func install(on host: CanvasHostView) {
            let scrollView = host.canvasScrollView
            guard self.scrollView !== scrollView else { return }
            self.scrollView = scrollView
            scrollView.addGestureRecognizer(observer)
            scrollView.addGestureRecognizer(three)
            scrollView.addGestureRecognizer(two)
            scrollView.panGestureRecognizer.addTarget(self, action: #selector(navigating(_:)))
            scrollView.pinchGestureRecognizer?.addTarget(self, action: #selector(navigating(_:)))
        }

        private func sequenceBegan(at time: TimeInterval) {
            began = time
            navigated = scrollView.map { $0.isDecelerating || $0.isZoomBouncing } ?? false
        }

        @objc private func navigating(_ recognizer: UIGestureRecognizer) {
            if recognizer.state == .began {
                navigated = true
            }
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onTap?(recognizer.numberOfTouchesRequired)
        }

        // MARK: UIGestureRecognizerDelegate

        public func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touch.majorRadius <= InputPolicy.defaultPalmMajorRadius
        }

        public func gestureRecognizerShouldBegin(_: UIGestureRecognizer) -> Bool {
            MultiFingerTapRule(pencilsDown: observer.pencilsDown, lastPencilUp: observer.lastPencilUp)
                .accepts(began: began, ended: CACurrentMediaTime(), navigated: navigated)
        }

        public func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
            true
        }
    }

    public extension CanvasHostView {
        /// No system three-finger editing gestures (swipe/double-tap undo, tap for the shortcut bar): they'd
        /// fire alongside ``MultiFingerTaps``.
        override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
            .none
        }
    }

    /// Watches every touch on the canvas without taking part in recognition (like `TouchObserver`):
    /// the start of each touch sequence and Pencil contact, for ``MultiFingerTaps``.
    @MainActor
    final class TapTouchObserver: UIGestureRecognizer {
        var onSequenceBegan: ((TimeInterval) -> Void)?
        private(set) var lastPencilUp: TimeInterval = -.infinity
        private var active: Set<ObjectIdentifier> = []
        private var pencils: Set<ObjectIdentifier> = []

        var pencilsDown: Int {
            pencils.count
        }

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
            if active.isEmpty, let first = touches.map(\.timestamp).min() {
                onSequenceBegan?(first)
            }
            for touch in touches {
                active.insert(ObjectIdentifier(touch))
                if touch.type == .pencil {
                    pencils.insert(ObjectIdentifier(touch))
                }
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
            pencils = []
        }

        private func lifted(_ touches: Set<UITouch>) {
            for touch in touches {
                active.remove(ObjectIdentifier(touch))
                if pencils.remove(ObjectIdentifier(touch)) != nil {
                    lastPencilUp = max(lastPencilUp, touch.timestamp)
                }
            }
            if active.isEmpty {
                state = .failed
            }
        }

        override func canPrevent(_: UIGestureRecognizer) -> Bool {
            false
        }

        override func canBePrevented(by _: UIGestureRecognizer) -> Bool {
            false
        }
    }
#endif
