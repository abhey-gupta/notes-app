#if canImport(UIKit)
    import InkEngine
    import InkModel
    import Perf
    import UIKit

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
    public final class CanvasHostView: UIView {
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

        /// Kept above the engine view, pinned and updated like it (lasso chrome, see ``CanvasOverlay``).
        public var overlay: (any CanvasOverlay)? {
            didSet { overlayDidChange(from: oldValue) }
        }

        /// The current page window (visible ± margins), once laid out.
        public private(set) var pageWindow: PageWindow?

        /// The scroll view (tests, UI automation).
        public var canvasScrollView: UIScrollView {
            scrollView
        }

        private let scrollView = CanvasScrollView()
        let contentView = UIView()
        private let addPageButton: UIButton
        private let touchObserver = TouchObserver()
        private var hasSeenPencil = false
        private var lastBoundsSize: CGSize = .zero
        private var fitZoom: CGFloat = 1
        private var isUpdatingInsets = false
        /// Zoom gesture tracking (`CanvasHostView+Zoom.swift`).
        var isPinching = false, engineIsZooming = false
        private let dismissGestures = DismissGestureClaim()

        /// Creates a host around `engine`.
        public init(engine: any InkEngine) {
            self.engine = engine
            addPageButton = Self.makeAddPageButton()
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
            touchObserver.onBegan = { [weak self] in
                guard let self else { return }
                dismissGestures.claim(above: self)
            }
            touchObserver.onAllLifted = { [weak self] in
                guard let self else { return }
                delegate?.canvasHostDidLiftAllTouches(self)
            }
            scrollView.addGestureRecognizer(touchObserver)
            scrollView.pinchGestureRecognizer?.addTarget(scrollView, action: #selector(CanvasScrollView.applyPinch(_:)))
            scrollView.pinchGestureRecognizer?.addTarget(self, action: #selector(pinchChanged(_:)))
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
            dismissGestures.claim(above: self)
            // After SwiftUI finishes the transition (which installs its dismiss gestures and shuffles responders).
            Task { @MainActor [weak self] in
                self?.becomeFirstResponder()
                try? await Task.sleep(for: .milliseconds(600))
                guard let self else { return }
                dismissGestures.claim(above: self)
            }
        }

        override public func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            if newWindow == nil {
                dismissGestures.release()
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
        func updateInsets() {
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
                pages: visible.map { VisiblePage(id: layout.pageIDs[$0], frame: layout.frames[$0]) },
                isZooming: isZooming
            )
        }

        private func contentRect(_ bounds: CGRect, zoom z: CGFloat) -> CGRect {
            CGRect(x: bounds.minX / z, y: bounds.minY / z, width: bounds.width / z, height: bounds.height / z)
        }

        /// One per scroll/zoom frame: pin the engine view, move the add-page button, tell the engine, then
        /// update the indicator and (if the visible pages changed) the page window.
        ///
        /// Without animation: `UIScrollView` runs some of its callbacks inside `UIView` animation blocks
        /// (the offset correction at the end of a zoom), and views placed from here must land where the
        /// viewport says this frame, not glide there.
        func viewportDidChange() {
            let interval = Signpost.canvasFrame.begin()
            defer { interval.end() }
            let bounds = scrollView.bounds
            let z = scrollView.zoomScale
            guard bounds.width > 0, bounds.height > 0, z > 0 else { return }
            UIView.performWithoutAnimation {
                if engine.view.frame != bounds {
                    engine.view.frame = bounds
                }
                placeAddPageButton(zoom: z)

                let viewport = makeViewport()
                engineIsZooming = viewport.isZooming
                engine.setViewport(viewport)
                updateOverlay(viewport)
            }

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
    }

    // MARK: Add page

    fileprivate extension CanvasHostView {
        func placeAddPageButton(zoom z: CGFloat) {
            let footer = layout.footerFrame
            let size = addPageButton.intrinsicContentSize
            let center = CGPoint(x: footer.midX * z, y: footer.minY * z + 28 + size.height / 2)
            addPageButton.bounds = CGRect(origin: .zero, size: size)
            addPageButton.center = center
            addPageButton.isHidden = !showsAddPage || layout.pageCount == 0
        }

        func requestNewPage() {
            delegate?.canvasHostDidRequestNewPage(self)
        }
    }

    // MARK: Input

    extension CanvasHostView {
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
#endif
