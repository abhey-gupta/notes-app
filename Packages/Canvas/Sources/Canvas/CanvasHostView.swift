#if canImport(UIKit)
    import InkEngine
    import InkModel
    import Observation
    import os
    import Perf
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

    /// The canvas host (ARCHITECTURE.md §5.1): a `UIScrollView` for native physics, rubber-banding and
    /// pinch zoom over a transparent content view the size of the notebook (``PageLayout``), with the
    /// engine's view **pinned to the visible rect** (a sibling of the content view, re-framed to the
    /// scroll view's bounds on every scroll), so there is never a layer the size of the notebook.
    ///
    /// Every scroll/zoom callback becomes one ``InkEngine/InkEngine/setViewport(_:)`` with the visible
    /// pages; the engine draws deceleration frames on its display link. When the visible pages change the
    /// delegate gets a new ``PageWindow`` (which pages the engine and memory should hold).
    ///
    /// Input: fingers scroll and zoom, the Pencil inks. The scroll view's pan and pinch only accept
    /// direct touches (and the pointer), so a Pencil never scrolls. With "draw with finger" on and no
    /// Pencil seen yet, one finger inks and scrolling takes two (``InkEngine/InputPolicy``).
    ///
    /// The host is first responder with its own `UndoManager`, so ⌘Z and the system three-finger
    /// undo/redo gestures reach the notebook's history (`UndoManagerBridge` attaches to ``editUndoManager``).
    @MainActor
    public final class CanvasHostView: UIView, UIScrollViewDelegate {
        /// Zoom range (scale of page points).
        public static let minimumZoom: CGFloat = 0.5
        public static let maximumZoom: CGFloat = 4
        /// Space below the last page for the add-page button (content pt).
        public static let footerHeight: CGFloat = 96

        /// The ink engine whose view is pinned over the pages.
        public let engine: any InkEngine
        /// Observable viewport facts for SwiftUI.
        public let state = CanvasViewportState()
        /// Callbacks.
        public weak var delegate: (any CanvasHostViewDelegate)?
        /// Undo manager for ⌘Z and the three-finger gestures while the canvas is first responder.
        public let editUndoManager = UndoManager()

        /// Page frames. Set it when pages are added, removed or moved; the scroll offset is kept.
        public var layout = PageLayout(pageIDs: [], footer: CanvasHostView.footerHeight) {
            didSet { layoutDidChange(from: oldValue) }
        }

        /// Breathing room inside the safe area: top clears the floating chrome, sides keep a desk margin when
        /// zoomed in, bottom clears the page pill.
        public var margins = UIEdgeInsets(top: 48, left: 16, bottom: 96, right: 16) {
            didSet { setNeedsLayout() }
        }

        /// "Draw with finger": one finger inks (until a Pencil is seen) and scrolling takes two fingers.
        public var allowsFingerDrawing = false {
            didSet { updateNavigationGestures() }
        }

        /// The add-page button can be hidden (e.g. read-only previews).
        public var showsAddPage = true {
            didSet { addPageButton.isHidden = !showsAddPage }
        }

        /// VoiceOver / UI-test description of the current page (e.g. "12 strokes"), read on demand.
        public var accessibilityPageValue: (() -> String?)? {
            get { scrollView.valueProvider }
            set { scrollView.valueProvider = newValue }
        }

        /// The current page window (visible ± margins), once laid out.
        public private(set) var pageWindow: PageWindow?

        /// The scroll view (tests, UI automation).
        public var canvasScrollView: UIScrollView {
            scrollView
        }

        private let scrollView = CanvasScrollView()
        private let contentView = UIView()
        private let addPageButton: UIButton
        private let touchObserver = TouchObserver()
        private var hasSeenPencil = false
        private var lastBoundsSize: CGSize = .zero
        private var fitZoom: CGFloat = 1
        private var isUpdatingInsets = false
        private var claimed: [(recognizer: UIGestureRecognizer, wasEnabled: Bool, touchTypes: [NSNumber])] = []

        /// Creates a host around `engine`.
        public init(engine: any InkEngine) {
            self.engine = engine
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
            addPageButton = UIButton(configuration: button)
            super.init(frame: .zero)
            backgroundColor = .clear
            isOpaque = false

            scrollView.delegate = self
            scrollView.backgroundColor = .clear
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.minimumZoomScale = Self.minimumZoom
            scrollView.maximumZoomScale = Self.maximumZoom
            scrollView.alwaysBounceVertical = true
            scrollView.bouncesZoom = true
            scrollView.delaysContentTouches = false
            scrollView.decelerationRate = .normal
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.accessibilityIdentifier = "canvas"
            scrollView.frame = bounds
            scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(scrollView)

            contentView.backgroundColor = .clear
            contentView.isUserInteractionEnabled = false
            scrollView.addSubview(contentView)
            scrollView.addSubview(engine.view)

            addPageButton.accessibilityIdentifier = "addPage"
            addPageButton.addAction(UIAction { [weak self] _ in self?.requestNewPage() }, for: .primaryActionTriggered)
            addPageButton.sizeToFit()
            scrollView.addSubview(addPageButton)

            scrollView.pageLabel = { [weak self] in
                guard let self, layout.pageCount > 0 else { return nil }
                return "Page \(state.currentPage + 1) of \(layout.pageCount)"
            }
            touchObserver.onPencil = { [weak self] in self?.pencilSeen() }
            touchObserver.onBegan = { [weak self] in self?.claimDismissGestures() }
            touchObserver.onAllLifted = { [weak self] in
                guard let self else { return }
                delegate?.canvasHostDidLiftAllTouches(self)
            }
            scrollView.addGestureRecognizer(touchObserver)
            updateNavigationGestures()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) not supported")
        }

        // MARK: Public

        /// Scrolls so page `index`'s top sits under the top margin.
        public func scrollToPage(_ index: Int, animated: Bool) {
            guard layout.frames.indices.contains(index) else { return }
            let z = scrollView.zoomScale
            let inset = scrollView.contentInset
            let maxY = max(scrollView.contentSize.height + inset.bottom - scrollView.bounds.height, -inset.top)
            let y = min(layout.frame(at: index).minY * z - inset.top, maxY)
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: animated)
        }

        /// Scroll offset and zoom in content terms (tests, state restoration).
        public var viewport: Viewport {
            makeViewport()
        }

        // MARK: UIView

        override public var canBecomeFirstResponder: Bool {
            true
        }

        override public var undoManager: UndoManager? {
            editUndoManager
        }

        override public func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            claimDismissGestures()
            // After SwiftUI finishes the transition (which installs its dismiss gestures and shuffles responders).
            Task { @MainActor [weak self] in
                self?.becomeFirstResponder()
                try? await Task.sleep(for: .milliseconds(600))
                self?.claimDismissGestures()
            }
        }

        override public func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            if newWindow == nil {
                releaseDismissGestures()
            }
        }

        override public func layoutSubviews() {
            super.layoutSubviews()
            let size = bounds.size
            guard size.width > 0, size.height > 0 else { return }
            if size != lastBoundsSize {
                resize(from: lastBoundsSize, to: size)
                lastBoundsSize = size
            } else {
                updateInsets()
                viewportDidChange()
            }
        }

        override public func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            setNeedsLayout()
        }

        // MARK: UIScrollViewDelegate

        public func viewForZooming(in _: UIScrollView) -> UIView? {
            contentView
        }

        public func scrollViewDidScroll(_: UIScrollView) {
            viewportDidChange()
        }

        public func scrollViewDidZoom(_ scrollView: UIScrollView) {
            updateInsets()
            state.zoomScale = scrollView.zoomScale
            viewportDidChange()
        }

        public func scrollViewWillBeginDragging(_: UIScrollView) {
            delegate?.canvasHostWillBeginNavigating(self)
        }

        public func scrollViewWillBeginZooming(_: UIScrollView, with _: UIView?) {
            delegate?.canvasHostWillBeginNavigating(self)
        }

        // MARK: Layout

        /// First layout and rotation/resizes: fit the page width (unless the user zoomed), keep the content
        /// point at the top of the viewport in place.
        private func resize(from old: CGSize, to new: CGSize) {
            let oldFit = fitZoom
            fitZoom = Self.fitZoom(pageWidth: layout.pageSize.width, viewWidth: new.width)
            let z = scrollView.zoomScale
            let anchorY = (scrollView.contentOffset.y + scrollView.contentInset.top) / z
            let isFirst = old == .zero
            if isFirst || abs(z - oldFit) < 0.001 {
                setZoom(fitZoom)
            }
            updateInsets()
            let inset = scrollView.contentInset
            let y = isFirst ? -inset.top : anchorY * scrollView.zoomScale - inset.top
            scrollView.contentOffset = CGPoint(x: centeredOffsetX(), y: y)
            viewportDidChange()
        }

        /// Fitted zoom: the page as wide as the mock's (760 of 1194 landscape): the view less 96 pt of
        /// desk each side, at most 880 pt, at least 320 pt.
        static func fitZoom(pageWidth: CGFloat, viewWidth: CGFloat) -> CGFloat {
            guard pageWidth > 0 else { return 1 }
            let width = max(320, min(viewWidth - 192, 880)).rounded()
            return min(max(width / pageWidth, minimumZoom), maximumZoom)
        }

        private func setZoom(_ zoom: CGFloat) {
            scrollView.zoomScale = zoom
            sizeContent()
            state.zoomScale = scrollView.zoomScale
        }

        private func layoutDidChange(from old: PageLayout) {
            state.pageCount = layout.pageCount
            guard layout != old else { return }
            sizeContent()
            updateInsets()
            viewportDidChange()
        }

        /// Content view bounds = layout size (unzoomed); its frame and the content size scale with zoom.
        private func sizeContent() {
            let size = layout.contentSize
            let z = scrollView.zoomScale
            contentView.bounds = CGRect(origin: .zero, size: size)
            contentView.center = CGPoint(x: size.width * z / 2, y: size.height * z / 2)
            scrollView.contentSize = CGSize(width: size.width * z, height: size.height * z)
        }

        /// Centers narrow content horizontally; top/bottom clear the chrome.
        private func updateInsets() {
            guard !isUpdatingInsets else { return }
            isUpdatingInsets = true
            defer { isUpdatingInsets = false }
            let width = layout.contentSize.width * scrollView.zoomScale
            let side = max((bounds.width - width) / 2, margins.left)
            let insets = UIEdgeInsets(
                top: safeAreaInsets.top + margins.top,
                left: side,
                bottom: safeAreaInsets.bottom + margins.bottom,
                right: max((bounds.width - width) / 2, margins.right)
            )
            if scrollView.contentInset != insets {
                scrollView.contentInset = insets
            }
        }

        private func centeredOffsetX() -> CGFloat {
            let width = layout.contentSize.width * scrollView.zoomScale
            return (width - bounds.width) / 2
        }

        // MARK: Viewport

        private func makeViewport() -> Viewport {
            let bounds = scrollView.bounds
            let z = scrollView.zoomScale
            let visible = layout.visiblePages(in: contentRect(bounds, zoom: z))
            return Viewport(
                contentOffset: bounds.origin,
                zoomScale: z,
                size: bounds.size,
                pages: visible.map { VisiblePage(id: layout.pageIDs[$0], frame: layout.frames[$0]) }
            )
        }

        private func contentRect(_ bounds: CGRect, zoom z: CGFloat) -> CGRect {
            CGRect(x: bounds.minX / z, y: bounds.minY / z, width: bounds.width / z, height: bounds.height / z)
        }

        /// One per scroll/zoom frame: pin the engine view, move the add-page button, tell the engine, then
        /// update the indicator and (if the visible pages changed) the page window.
        private func viewportDidChange() {
            let interval = Signpost.canvasFrame.begin()
            defer { interval.end() }
            let bounds = scrollView.bounds
            let z = scrollView.zoomScale
            guard bounds.width > 0, bounds.height > 0, z > 0 else { return }
            if engine.view.frame != bounds {
                engine.view.frame = bounds
            }
            placeAddPageButton(zoom: z)

            let viewport = makeViewport()
            engine.setViewport(viewport)

            let content = contentRect(bounds, zoom: z)
            if let current = layout.nearestPage(toY: content.midY), current != state.currentPage {
                state.currentPage = current
            }
            let visible = layout.visiblePages(in: content)
            let next = PageWindow(visible: visible, pageCount: layout.pageCount)
            if next != pageWindow {
                pageWindow = next
                delegate?.canvasHost(self, didChange: next)
            }
        }

        private func placeAddPageButton(zoom z: CGFloat) {
            let footer = layout.footerFrame
            let size = addPageButton.intrinsicContentSize
            let center = CGPoint(x: footer.midX * z, y: footer.minY * z + 28 + size.height / 2)
            addPageButton.bounds = CGRect(origin: .zero, size: size)
            addPageButton.center = center
            addPageButton.isHidden = !showsAddPage || layout.pageCount == 0
        }

        private func requestNewPage() {
            delegate?.canvasHostDidRequestNewPage(self)
        }

        // MARK: Interactive dismissal

        /// The library pushes the editor with a SwiftUI zoom transition whose interactive dismissal (swipe down
        /// anywhere, pinch, leading-edge pan) is installed on the editor's hosting view and would steal
        /// Pencil strokes and scrolls on the canvas; SwiftUI has no switch for it (`interactiveDismissDisabled`
        /// only covers sheets). While the canvas is in a window it disables the swipe-down and pinch
        /// recognizers and limits the edge pan to fingers (back stays one edge swipe or the back button);
        /// they're restored when it leaves. Recognizers are found by the `name` UIKit gives them
        /// (`com.apple.UIKit.ZoomInteractiveDismiss…`); if a release renames them this is a no-op and
        /// `CanvasTests.testDownwardDragAtTopDoesNotDismissEditor` fails.
        private func claimDismissGestures() {
            var view = superview
            while let current = view {
                for recognizer in current.gestureRecognizers ?? [] {
                    guard let name = recognizer.name, name.hasPrefix(Self.zoomDismissPrefix),
                          !claimed.contains(where: { $0.recognizer === recognizer }) else { continue }
                    claimed.append((recognizer, recognizer.isEnabled, recognizer.allowedTouchTypes))
                    if name.hasSuffix("LeadingEdgePan") {
                        recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                    } else {
                        recognizer.isEnabled = false
                    }
                }
                view = current.superview
            }
        }

        private func releaseDismissGestures() {
            for entry in claimed {
                entry.recognizer.isEnabled = entry.wasEnabled
                entry.recognizer.allowedTouchTypes = entry.touchTypes
            }
            claimed = []
        }

        private static let zoomDismissPrefix = "com.apple.UIKit.ZoomInteractiveDismiss"

        // MARK: Input

        private func updateNavigationGestures() {
            let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
            let pointer = NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
            scrollView.panGestureRecognizer.allowedTouchTypes = [direct, pointer]
            scrollView.pinchGestureRecognizer?.allowedTouchTypes = [direct, pointer]
            // Matches InputPolicy: fingers ink only while no Pencil has been seen.
            scrollView.panGestureRecognizer.minimumNumberOfTouches = allowsFingerDrawing && !hasSeenPencil ? 2 : 1
        }

        private func pencilSeen() {
            guard !hasSeenPencil else { return }
            hasSeenPencil = true
            updateNavigationGestures()
        }
    }

    /// The canvas scroll view: an accessibility element whose label and value are computed when asked.
    @MainActor
    private final class CanvasScrollView: UIScrollView {
        var pageLabel: (() -> String?)?
        var valueProvider: (() -> String?)?

        override var accessibilityLabel: String? {
            get { pageLabel?() ?? super.accessibilityLabel }
            set { super.accessibilityLabel = newValue }
        }

        override var accessibilityValue: String? {
            get { valueProvider?() ?? super.accessibilityValue }
            set { super.accessibilityValue = newValue }
        }
    }

    /// Watches touches on the canvas without taking part in recognition (never recognizes, never delays or
    /// cancels touches, can't be prevented): reports Pencil contact, so the host can hand one-finger
    /// scrolling back to the scroll view, and the moment the last touch lifts.
    @MainActor
    private final class TouchObserver: UIGestureRecognizer {
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
            for t in touches {
                os.Logger(subsystem: "com.abhey.notespace", category: "debug").error("DBG touch type \(t.type.rawValue) radius \(t.majorRadius) view \(String(describing: t.view), privacy: .public)")
            }
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
