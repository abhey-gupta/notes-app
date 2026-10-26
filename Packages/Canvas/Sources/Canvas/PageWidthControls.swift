#if canImport(UIKit)
    import InkModel
    import UIKit

    /// The page-width handles (#129): a quiet pill centred on each side edge of the current page, shown at
    /// fit zoom (or when a Pencil hovers near an edge). Dragging one out shows the new edge as a dashed
    /// outline on every visible page with a dark "+50%" tag, ticks once per 25 % step, and on release asks
    /// the delegate to widen every page. Dragging in stops at the original edge or the furthest ink (a bump).
    ///
    /// Lives in the scroll view in zoomed points (like the add-page button), so the pill keeps its size at
    /// any zoom while following the page.
    @MainActor
    final class PageWidthControls: NSObject, UIGestureRecognizerDelegate {
        /// Handles show at or below this multiple of the fit zoom.
        static let fitTolerance: CGFloat = 1.02
        /// A Pencil (or pointer) hovering this close to an edge (screen pt) shows the handles.
        static let hoverReach: CGFloat = 48
        /// Most finger travel (screen pt) per step: a real step (25 % of the page) is wider than the desk
        /// beside a fitted page, so the handle moves less than the edge it previews.
        static let maximumStepTravel: CGFloat = 40

        private unowned let host: CanvasHostView
        private let handles: [PageExtension.Side: PageWidthHandle]
        private let preview = PageWidthPreview()
        private var drag: PageWidthDrag?
        private var dragSteps = 0
        private var dragLimit: PageWidthDrag.Limit?
        private var inkSpanTask: Task<Void, Never>?
        /// The extension asked for on release, until the layout arrives with it.
        private var pending: PageExtension?
        private var hoverSide: PageExtension.Side?
        private let ticks = UISelectionFeedbackGenerator()
        private let bump = UIImpactFeedbackGenerator(style: .rigid)

        init(host: CanvasHostView) {
            self.host = host
            handles = Dictionary(uniqueKeysWithValues: PageExtension.Side.allCases.map { ($0, PageWidthHandle(side: $0)) })
            super.init()
            let scrollView = host.canvasScrollView
            preview.isHidden = true
            scrollView.addSubview(preview)
            for handle in handles.values {
                handle.alpha = 0
                handle.isUserInteractionEnabled = false
                let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
                pan.delegate = self
                pan.maximumNumberOfTouches = 1
                handle.addGestureRecognizer(pan)
                handle.onStep = { [weak self, weak handle] delta in
                    guard let self, let handle else { return }
                    step(handle.side, by: delta)
                }
                scrollView.addSubview(handle)
            }
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
            scrollView.addGestureRecognizer(hover)
        }

        // MARK: Placement

        /// Every scroll/zoom frame and layout change: pins the handles to the current page's edges.
        func update() {
            let layout = host.layout
            let scrollView = host.canvasScrollView
            let z = scrollView.zoomScale
            if let pending, layout.pageExtension == pending {
                self.pending = nil
                preview.isHidden = true
            }
            guard layout.pageCount > 0, z > 0, layout.frames.indices.contains(host.state.currentPage) else {
                setShown(false)
                return
            }
            let page = layout.frame(at: host.state.currentPage)
            let visible = PageLayout.contentRect(visible: scrollView.bounds, zoom: z)
            let shown = page.intersection(visible)
            let midY = shown.isNull ? page.midY : shown.midY
            UIView.performWithoutAnimation {
                for (side, handle) in handles {
                    var x = side == .left ? page.minX : page.maxX
                    if let drag, drag.side == side {
                        x += drag.edgeOffset(steps: dragSteps) * travelRatio(drag)
                    }
                    handle.center = CGPoint(x: x * z, y: midY * z)
                    handle.accessibilityValue = PageWidthDrag.label(steps: layout.pageExtension.steps(side, of: layout.basePageSize.width))
                }
                if drag != nil {
                    updatePreview()
                }
            }
            let atFit = z <= host.fitZoom * Self.fitTolerance
            setShown(drag != nil || pending != nil || atFit || hoverSide != nil)
        }

        private func setShown(_ shown: Bool) {
            for handle in handles.values where handle.isUserInteractionEnabled != shown {
                handle.isUserInteractionEnabled = shown
                UIView.animate(withDuration: 0.2) { handle.alpha = shown ? 1 : 0 }
            }
        }

        // MARK: Dragging

        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            guard let handle = pan.view as? PageWidthHandle else { return }
            switch pan.state {
            case .began:
                begin(handle.side)
            case .changed:
                guard let drag else { return }
                let z = max(host.canvasScrollView.zoomScale, 0.0001)
                move(to: pan.translation(in: host.canvasScrollView).x / z / travelRatio(drag))
            case .ended:
                end(commit: true)
            default:
                end(commit: false)
            }
        }

        private func begin(_ side: PageExtension.Side) {
            let layout = host.layout
            // Until the ink is measured the side can't shrink.
            drag = PageWidthDrag(
                side: side,
                baseWidth: layout.basePageSize.width,
                start: layout.pageExtension,
                inkSpan: -.infinity ... .infinity
            )
            let current = layout.pageExtension.steps(side, of: layout.basePageSize.width)
            dragSteps = current
            dragLimit = nil
            handles[side]?.isDragging = true
            preview.isHidden = false
            ticks.prepare()
            bump.prepare()
            inkSpanTask?.cancel()
            inkSpanTask = Task { [weak self] in
                guard let self, let delegate = host.delegate else { return }
                let span = await delegate.canvasHostInkSpan(host)
                guard !Task.isCancelled, let drag, drag.side == side else { return }
                self.drag = PageWidthDrag(side: side, baseWidth: drag.baseWidth, start: drag.start, inkSpan: span)
            }
            update()
        }

        private func move(to translation: CGFloat) {
            guard let drag else { return }
            let (steps, limit) = drag.steps(for: translation)
            if steps != dragSteps {
                ticks.selectionChanged()
                ticks.prepare()
            } else if limit != nil, dragLimit == nil {
                bump.impactOccurred()
                bump.prepare()
            }
            dragSteps = steps
            dragLimit = limit
            update()
        }

        private func end(commit: Bool) {
            guard let drag else { return }
            inkSpanTask?.cancel()
            let next = drag.pageExtension(steps: dragSteps)
            self.drag = nil
            handles[drag.side]?.isDragging = false
            if commit, next != drag.start {
                // The preview stays until the widened layout lands (`update`), so the page never flickers back.
                pending = next
                host.delegate?.canvasHost(host, didRequestPageExtension: next)
            } else {
                preview.isHidden = true
            }
            update()
        }

        /// VoiceOver increment/decrement: one step out or in, ink permitting.
        private func step(_ side: PageExtension.Side, by delta: Int) {
            let layout = host.layout
            let width = layout.basePageSize.width
            let start = layout.pageExtension
            Task { [weak self] in
                guard let self, let delegate = host.delegate else { return }
                let span = delta < 0 ? await delegate.canvasHostInkSpan(host) : nil
                let drag = PageWidthDrag(side: side, baseWidth: width, start: start, inkSpan: span)
                let outward = CGFloat(delta) * PageExtension.step * width
                let (steps, _) = drag.steps(for: side == .left ? -outward : outward)
                let next = drag.pageExtension(steps: steps)
                guard next != start else { return }
                delegate.canvasHost(host, didRequestPageExtension: next)
            }
        }

        /// Finger travel per real step: 1 when a step is at most ``maximumStepTravel`` on screen.
        private func travelRatio(_ drag: PageWidthDrag) -> CGFloat {
            let step = PageExtension.step * drag.baseWidth * host.canvasScrollView.zoomScale
            return step > 0 ? min(Self.maximumStepTravel / step, 1) : 1
        }

        // MARK: Preview

        private func updatePreview() {
            guard let drag else { return }
            let layout = host.layout
            let scrollView = host.canvasScrollView
            let z = scrollView.zoomScale
            preview.frame = CGRect(origin: .zero, size: scrollView.contentSize)
            let visible = PageLayout.contentRect(visible: scrollView.bounds, zoom: z)
            let offset = drag.edgeOffset(steps: dragSteps)
            var bands: [CGRect] = []
            for i in layout.visiblePages(in: visible) {
                let page = layout.frame(at: i)
                let edge = drag.side == .left ? page.minX : page.maxX
                let band = CGRect(x: min(edge, edge + offset), y: page.minY, width: abs(offset), height: page.height)
                bands.append(CGRect(x: band.minX * z, y: band.minY * z, width: band.width * z, height: band.height * z))
            }
            let current = layout.frame(at: min(host.state.currentPage, layout.pageCount - 1))
            let edge = (drag.side == .left ? current.minX : current.maxX) + offset * travelRatio(drag)
            let shown = current.intersection(visible)
            let handleY = (shown.isNull ? current.midY : shown.midY) * z
            preview.show(
                bands: bands, growing: offset * (drag.side == .left ? -1 : 1) > 0,
                tag: PageWidthDrag.label(steps: dragSteps),
                tagCenter: CGPoint(x: edge * z, y: handleY - PageWidthHandle.hitSize.height / 2 - 14)
            )
        }

        // MARK: Hover

        @objc private func hovered(_ hover: UIHoverGestureRecognizer) {
            let previous = hoverSide
            hoverSide = nil
            if hover.state == .began || hover.state == .changed {
                let scrollView = host.canvasScrollView
                let z = scrollView.zoomScale
                let p = hover.location(in: scrollView)
                let layout = host.layout
                if layout.frames.indices.contains(host.state.currentPage) {
                    let page = layout.frame(at: host.state.currentPage)
                    let y = p.y / z
                    if y >= page.minY, y <= page.maxY {
                        if abs(p.x - page.minX * z) < Self.hoverReach {
                            hoverSide = .left
                        } else if abs(p.x - page.maxX * z) < Self.hoverReach {
                            hoverSide = .right
                        }
                    }
                }
            }
            if hoverSide != previous {
                update()
            }
        }

        // MARK: UIGestureRecognizerDelegate

        /// The scroll view's pan waits for a handle drag, so dragging a handle never scrolls.
        func gestureRecognizer(_: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other === host.canvasScrollView.panGestureRecognizer
        }
    }

    /// One edge handle: a 6×44 pill in a larger touch target. Adjustable for VoiceOver (one step per swipe).
    @MainActor
    final class PageWidthHandle: UIButton {
        static let pillSize = CGSize(width: 6, height: 44)
        static let hitSize = CGSize(width: 36, height: 88)

        let side: PageExtension.Side
        /// VoiceOver increment (+1) / decrement (−1).
        var onStep: (Int) -> Void = { _ in }
        var isDragging = false {
            didSet { updatePill() }
        }

        private let pill = UIView()

        init(side: PageExtension.Side) {
            self.side = side
            super.init(frame: CGRect(origin: .zero, size: Self.hitSize))
            pill.isUserInteractionEnabled = false
            pill.layer.cornerRadius = Self.pillSize.width / 2
            pill.layer.cornerCurve = .continuous
            addSubview(pill)
            updatePill()
            accessibilityIdentifier = side == .left ? "pageWidth.left" : "pageWidth.right"
            accessibilityLabel = side == .left ? "Widen page to the left" : "Widen page to the right"
            accessibilityTraits = .adjustable
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) not supported")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let size = isDragging ? CGSize(width: Self.pillSize.width, height: Self.pillSize.height + 8) : Self.pillSize
            pill.bounds = CGRect(origin: .zero, size: size)
            pill.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }

        override func accessibilityIncrement() {
            onStep(1)
        }

        override func accessibilityDecrement() {
            onStep(-1)
        }

        private func updatePill() {
            // `Tokens.Color.inkPrimary` at 18 % (40 % while dragged).
            let alpha: CGFloat = isDragging ? 0.4 : 0.18
            pill.backgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0xE9 / 255, green: 0xE8 / 255, blue: 0xE4 / 255, alpha: alpha)
                    : UIColor(red: 0x1E / 255, green: 0x21 / 255, blue: 0x29 / 255, alpha: alpha)
            }
            UIView.animate(withDuration: 0.15) { self.setNeedsLayout(); self.layoutIfNeeded() }
        }
    }

    /// The drag preview: the paper being added (or taken away) on every visible page as a dashed outline,
    /// and the dark width tag over the dragged edge.
    @MainActor
    final class PageWidthPreview: UIView {
        private let bands = CAShapeLayer()
        private let label = UILabel()
        private let tagBackground = UIView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            bands.lineWidth = 1.5
            bands.lineDashPattern = [6, 5]
            layer.addSublayer(bands)
            tagBackground.backgroundColor = UIColor(red: 0x1E / 255, green: 0x21 / 255, blue: 0x29 / 255, alpha: 0.88)
            tagBackground.layer.cornerCurve = .continuous
            addSubview(tagBackground)
            label.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            label.textColor = .white
            label.accessibilityIdentifier = "pageWidth.tag"
            tagBackground.addSubview(label)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) not supported")
        }

        func show(bands rects: [CGRect], growing: Bool, tag text: String, tagCenter: CGPoint) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let path = CGMutablePath()
            for rect in rects where rect.width > 0 {
                path.addRoundedRect(in: rect.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 2, cornerHeight: 2)
            }
            bands.path = path
            let ink = UIColor(red: 0x1E / 255, green: 0x21 / 255, blue: 0x29 / 255, alpha: 1)
            bands.strokeColor = ink.withAlphaComponent(0.35).cgColor
            // Paper to come is a faint wash; paper going away a faint shade.
            bands.fillColor = (growing ? UIColor.white.withAlphaComponent(0.5) : ink.withAlphaComponent(0.06)).cgColor
            CATransaction.commit()
            label.text = text
            label.sizeToFit()
            let size = CGSize(width: label.bounds.width + 16, height: label.bounds.height + 8)
            tagBackground.bounds = CGRect(origin: .zero, size: size)
            tagBackground.center = tagCenter
            tagBackground.layer.cornerRadius = size.height / 2
            label.center = CGPoint(x: size.width / 2, y: size.height / 2)
        }
    }
#endif
