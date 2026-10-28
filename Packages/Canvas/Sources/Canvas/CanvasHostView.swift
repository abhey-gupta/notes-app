#if canImport(UIKit)
    import InkEngine
    import InkModel
    import Perf
    import UIKit

    /// The canvas host (ARCHITECTURE.md §5.1): a `UIScrollView` for native physics, rubber-banding and
    /// pinch zoom over a transparent content view the size of the notebook (``PageLayout``), with the
    /// engine's view **inside the content view** (content-sized, in unzoomed points), so UIKit's one zoom
    /// transform moves paper and ink together on every frame of a pinch, bounce or fling. The engine
    /// draws only the visible pages, so the big views cost nothing.
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
    /// With ``allowsTapUndo`` a two-finger tap undoes and a three-finger tap redoes instead of the system
    /// gestures (#121): `TouchObserver` spots them without joining gesture recognition, so scrolling and
    /// pinching are untouched; fingers touching down during or just after Pencil contact don't count,
    /// nor do taps while fingers ink. No feedback: the ink changing is the feedback.
    @MainActor
    public final class CanvasHostView: UIView {
        /// Zoom range (scale of page points).
        public static let minimumZoom: CGFloat = 0.5
        public static let maximumZoom: CGFloat = 4
        /// Space below the last page for the add-page button (content pt).
        public static let footerHeight: CGFloat = 96

        /// The ink engine; its view fills the content view (content space, zoomed by the scroll view).
        public let engine: any InkEngine
        /// Observable viewport facts for SwiftUI.
        public let state = CanvasViewportState()
        /// Callbacks.
        public weak var delegate: (any CanvasHostViewDelegate)?
        /// Undo manager for ⌘Z and the system's three-finger gestures while the canvas is first responder.
        public let editUndoManager = UndoManager()

        /// Page frames. Set it when pages are added, removed or moved; the scroll offset is kept.
        public var layout = PageLayout(pageIDs: [], footer: CanvasHostView.footerHeight) {
            didSet { layoutDidChange(from: oldValue) }
        }

        /// Paper the notebook added each side of its original width (#129); set with ``layout``. Bounds
        /// the side grabs (+200 % per side) and phases the preview's template marks.
        public var pageExtension = PageExtension.none

        /// Colors of the live widen preview (#129): the notebook's paper, template marks and desk.
        public var paperAppearance = PaperAppearance(paper: .white, line: UIColor(white: 0.12, alpha: 0.16), desk: .systemGray6)

        /// Template of a page, for the preview to continue its marks (`nil`: blank).
        public var templateProvider: ((PageID) -> PageTemplate?)?

        /// Breathing room inside the safe area: top clears the floating chrome (6 pt + 52 pt capsule) with a
        /// 14 pt gap, sides keep a desk margin when zoomed in, bottom clears the page pill.
        public var margins = UIEdgeInsets(top: 72, left: 16, bottom: 96, right: 16) {
            didSet { setNeedsLayout() }
        }

        /// "Draw with finger": one finger inks (until a Pencil is seen) and scrolling takes two fingers.
        public var allowsFingerDrawing = false {
            didSet { updateNavigationGestures() }
        }

        /// Two-finger tap undoes, three-finger tap redoes (#121; Settings → "Tap to undo").
        public var allowsTapUndo = true

        /// The add-page button can be hidden (automatic new pages, #172; read-only previews). Without it the
        /// space below the last page shrinks to ``footer(for:)`` and no bottom margin.
        public var showsAddPage = true {
            didSet {
                addPageButton.isHidden = !showsAddPage
                addPageButtonDidToggle(from: oldValue)
            }
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

        let scrollView = CanvasScrollView()
        let contentView = UIView()
        private let addPageButton: UIButton
        private let touchObserver = TouchObserver()
        private var hasSeenPencil = false
        var lastBoundsSize: CGSize = .zero
        var fitZoom: CGFloat = 1
        var isUpdatingInsets = false
        /// A ``restore(_:)`` before the first layout, applied by it.
        var pendingPosition: ReadingPosition?
        /// `addPageButton`'s size: `intrinsicContentSize` re-resolves its configuration (≈30 % of a scroll
        /// frame, #44), so measure once per text size.
        private var addPageButtonSize: CGSize?
        /// Zoom gesture tracking (`CanvasHostView+Zoom.swift`): a pinch, the engine's last word, the snap
        /// to fit width after a pinch (#130).
        var isPinching = false, engineIsZooming = false, isSnapping = false
        let snapHaptic = UIImpactFeedbackGenerator(style: .light)
        /// Side grab (`CanvasHostView+SideGrab.swift`, #129): the grab under way, its recognizer, the
        /// haptic at its stops, the width tag, the frame held while the document widens, and whether the
        /// insets are on hold until ``endWidening()``.
        var sideGrab: SideGrabSession?
        let sideGrabGesture = UILongPressGestureRecognizer()
        let grabHaptic = UIImpactFeedbackGenerator(style: .rigid)
        var widthTag: UILabel?
        var freezeFrame: UIView?
        var isSettling = false
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
            scrollView.addSubview(contentView)
            engine.view.frame = contentView.bounds
            engine.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentView.addSubview(engine.view)

            addPageButton.accessibilityIdentifier = "addPage"
            addPageButton.addAction(UIAction { [weak self] _ in self?.requestNewPage() }, for: .primaryActionTriggered)
            addPageButton.sizeToFit()
            scrollView.addSubview(addPageButton)
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
                self.addPageButtonSize = nil
                self.viewportDidChange()
            }

            installAccessibilityLabels()
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
            touchObserver.onFingerTap = { [weak self] fingers in self?.fingersTapped(fingers) }
            updateNavigationGestures()
            installSideGrab()
        }

        /// VoiceOver / UI-test labels computed on demand: "Page 3 of 11", "Widened to 150 %" (#129).
        private func installAccessibilityLabels() {
            scrollView.pageLabel = { [weak self] in
                guard let self, layout.pageCount > 0 else { return nil }
                return "Page \(state.currentPage + 1) of \(layout.pageCount)"
            }
            scrollView.widthLabel = { [weak self] in
                guard let self, layout.pageCount > 0 else { return nil }
                let base = layout.pageSize.width - pageExtension.left - pageExtension.right
                guard base > 0, pageExtension != .none else { return nil }
                return "Widened to \(Int((layout.pageSize.width / base * 100).rounded())) %"
            }
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

        /// While tap undo is on, the system's three-finger editing gestures are off for the canvas: their tap
        /// pops the undo bar, which would land on every redo. ⌘Z keeps working.
        override public var editingInteractionConfiguration: UIEditingInteractionConfiguration {
            allowsTapUndo ? .none : .default
        }

        override public func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            dismissGestures.claim(above: self)
            // After SwiftUI finishes the transition (which installs its dismiss gestures and shuffles responders).
            // Becoming first responder waits too: the first time in a launch it takes ~50 ms on main, a dropped
            // frame mid-zoom.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard let self, window != nil else { return }
                dismissGestures.claim(above: self)
                if !isFirstResponder {
                    becomeFirstResponder()
                }
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
                cancelSideGrabForResize()
                resize(from: lastBoundsSize, to: size)
                lastBoundsSize = size
                if let pendingPosition {
                    restore(pendingPosition)
                }
            } else {
                updateInsets()
                viewportDidChange()
            }
        }

        override public func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            setNeedsLayout()
        }

        // MARK: Viewport

        /// The scroll view's bounds in content terms: during a side grab the content sits `grabLeftShift`
        /// page points further right in the scroll view than its coordinates say (`sizeContent()`).
        private var contentBounds: CGRect {
            scrollView.bounds.offsetBy(dx: -grabLeftShift * scrollView.zoomScale, dy: 0)
        }

        private func makeViewport() -> Viewport {
            let bounds = contentBounds
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
            PageLayout.contentRect(visible: bounds, zoom: z)
        }

        /// One per scroll/zoom frame: move the add-page button, tell the engine, then update the indicator
        /// and (if the visible pages changed) the page window.
        ///
        /// Without animation: `UIScrollView` runs some of its callbacks inside `UIView` animation blocks
        /// (the offset correction at the end of a zoom), and views placed from here must land where the
        /// viewport says this frame, not glide there.
        func viewportDidChange() {
            let interval = Signpost.canvasFrame.begin()
            defer { interval.end() }
            let bounds = contentBounds
            let z = scrollView.zoomScale
            guard bounds.width > 0, bounds.height > 0, z > 0 else { return }
            let viewport = makeViewport()
            UIView.performWithoutAnimation {
                placeAddPageButton(zoom: z)
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

        private func requestNewPage() {
            delegate?.canvasHostDidRequestNewPage(self)
        }
    }

    // MARK: Add page

    extension CanvasHostView {
        private func placeAddPageButton(zoom z: CGFloat) {
            let footer = layout.footerFrame
            let size = addPageButtonSize ?? addPageButton.intrinsicContentSize
            addPageButtonSize = size
            let center = CGPoint(x: footer.midX * z, y: footer.minY * z + 28 + size.height / 2)
            if addPageButton.bounds.size != size {
                addPageButton.bounds = CGRect(origin: .zero, size: size)
            }
            if addPageButton.center != center {
                addPageButton.center = center
            }
            let hidden = !showsAddPage || layout.pageCount == 0
            if addPageButton.isHidden != hidden {
                addPageButton.isHidden = hidden
            }
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
            scrollView.panGestureRecognizer.minimumNumberOfTouches = fingersInk ? 2 : 1
        }

        /// Fingers ink while "draw with finger" is on and no Pencil has been seen (InputPolicy).
        var fingersInk: Bool {
            allowsFingerDrawing && !hasSeenPencil
        }

        /// Two fingers undo, three redo (#121).
        func fingersTapped(_ fingers: Int) {
            guard allowsTapUndo, !fingersInk else { return }
            switch fingers {
            case 2: delegate?.canvasHostDidRequestUndo(self)
            case 3: delegate?.canvasHostDidRequestRedo(self)
            default: break
            }
        }

        private func pencilSeen() {
            guard !hasSeenPencil else { return }
            hasSeenPencil = true
            updateNavigationGestures()
        }
    }
#endif
