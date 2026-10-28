#if canImport(UIKit)
    import InkGeometry
    import InkModel
    import UIKit

    /// What the live widen preview paints with (#129): the engine's palette isn't visible to the host.
    public struct PaperAppearance: Equatable {
        /// Paper fill.
        public var paper: UIColor
        /// Template marks and the hairline at the original edge.
        public var line: UIColor
        /// The desk behind the pages (paper taken away shows it).
        public var desk: UIColor

        public init(paper: UIColor, line: UIColor, desk: UIColor) {
            self.paper = paper
            self.line = line
            self.desk = desk
        }
    }

    /// Side grab (#129): press and hold within ``SideGrab/grabBand`` of a page's left or right edge, then
    /// drag. There is no handle at rest. The paper grows (or shrinks) live under the finger on every
    /// visible page: paper-colored strips with the template's marks continued on their grid, a hairline
    /// where the edge was, a width tag beside the finger. The pages themselves don't move: for a left grab
    /// the content is shifted inside the scroll view by the paper added (``sizeContent()``,
    /// ``makeViewport()``), so the ink stays put on screen. Release hands the delegate a
    /// ``PageWidthChange``; it widens the document and lays the host out again
    /// (``finishSideGrab(layout:extensions:)``) under a frozen frame, lifted by ``endWidening()`` once the
    /// engine has drawn the wider pages, so nothing flickers at the hand-off.
    extension CanvasHostView {
        /// Live state of a grab.
        final class SideGrabSession {
            var grab: SideGrab
            let startTouch: CGPoint
            let startOffset: CGPoint
            let startInsets: UIEdgeInsets
            var strips: [PageID: PreviewStrip] = [:]
            var hitStop = false

            init(grab: SideGrab, touch: CGPoint, offset: CGPoint, insets: UIEdgeInsets) {
                self.grab = grab
                startTouch = touch
                startOffset = offset
                startInsets = insets
            }
        }

        func installSideGrab() {
            sideGrabGesture.minimumPressDuration = 0.4
            sideGrabGesture.allowableMovement = 8
            sideGrabGesture.numberOfTouchesRequired = 1
            sideGrabGesture.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            ]
            sideGrabGesture.addTarget(self, action: #selector(handleSideGrab(_:)))
            canvasScrollView.addGestureRecognizer(sideGrabGesture)
        }

        /// Paper added each side of the original width while a grab is on (content points, signed).
        var grabLeftShift: CGFloat {
            sideGrab?.grab.leftShift ?? 0
        }

        var grabWidthDelta: CGFloat {
            sideGrab?.grab.widthDelta ?? 0
        }

        @objc func handleSideGrab(_ gesture: UILongPressGestureRecognizer) {
            let touch = gesture.location(in: self)
            switch gesture.state {
            case .began:
                if !beginSideGrab(at: touch) {
                    gesture.isEnabled = false // fails this recognition; a later press starts afresh
                    gesture.isEnabled = true
                }
            case .changed:
                updateSideGrab(touch: touch)
            case .ended:
                endSideGrab(commit: true)
            default:
                endSideGrab(commit: false)
            }
        }

        // MARK: Lifecycle

        /// Starts a grab if `touch` (host coordinates) is near a page edge. `false`: not near one.
        @discardableResult
        func beginSideGrab(at touch: CGPoint) -> Bool {
            guard sideGrab == nil, freezeFrame == nil, layout.pageCount > 0, !isZooming else { return false }
            let scroll = canvasScrollView
            let z = scroll.zoomScale
            let leftEdge = -scroll.contentOffset.x
            let rightEdge = layout.pageSize.width * z - scroll.contentOffset.x
            guard let side = SideGrab.side(at: touch.x, leftEdge: leftEdge, rightEdge: rightEdge) else { return false }
            let grab = SideGrab(side: side, pageWidth: layout.pageSize.width, extensions: pageExtension)
            sideGrab = SideGrabSession(grab: grab, touch: touch, offset: scroll.contentOffset, insets: scroll.contentInset)
            scroll.isScrollEnabled = false
            scroll.pinchGestureRecognizer?.isEnabled = false
            snapHaptic.impactOccurred()
            grabHaptic.prepare()
            layoutPreview()
            delegate?.canvasHostDidBeginSideGrab(self)
            return true
        }

        /// The finger moved to `touch` (host coordinates).
        func updateSideGrab(touch: CGPoint) {
            guard let session = sideGrab else { return }
            let z = canvasScrollView.zoomScale
            let travel = touch.x - session.startTouch.x
            let outward = (session.grab.side == .right ? travel : -travel) / max(z, 0.0001)
            if session.grab.move(outward: outward) {
                grabHaptic.impactOccurred()
            }
            applyGrabGeometry()
            placeWidthTag(near: touch)
        }

        /// The x range ink covers across the notebook (page points; `nil`: no ink), asked for at
        /// ``CanvasHostViewDelegate/canvasHostDidBeginSideGrab(_:)``. Sets how far the edge may come in.
        public func setInkExtent(_ extent: ClosedRange<CGFloat>?) {
            guard let session = sideGrab else { return }
            session.grab.setInkExtent(extent)
            applyGrabGeometry()
        }

        /// The finger lifted (`commit`) or the gesture was cancelled.
        func endSideGrab(commit: Bool) {
            guard let session = sideGrab else { return }
            let scroll = canvasScrollView
            scroll.isScrollEnabled = true
            scroll.pinchGestureRecognizer?.isEnabled = true
            widthTag?.isHidden = true
            if commit, let change = session.grab.change {
                // Hold this frame while the document widens and the engine draws the wider pages.
                if let frozen = scroll.snapshotView(afterScreenUpdates: false) {
                    frozen.frame = scroll.frame
                    frozen.isUserInteractionEnabled = false
                    addSubview(frozen)
                    freezeFrame = frozen
                }
                isSettling = true
                delegate?.canvasHost(self, didWidenPages: change)
                return
            }
            // Nothing to commit: back to where the grab started.
            removePreview()
            sideGrab = nil
            sizeContent()
            scroll.contentInset = session.startInsets
            scroll.contentOffset = session.startOffset
            updateInsets()
            viewportDidChange()
        }

        /// The document widened: the layout matches the preview (`extension` included), so the pages
        /// take over from the strips without anything on screen moving.
        public func finishSideGrab(layout: PageLayout, extensions: PageExtension) {
            removePreview()
            sideGrab = nil
            pageExtension = extensions
            isSettling = true
            self.layout = layout
        }

        /// The engine has drawn the wider pages: lifts the frozen frame and eases the content onto its
        /// regular insets (a page that stopped being narrower than the view, or the other way round).
        public func endWidening() {
            guard isSettling else { return }
            isSettling = false
            freezeFrame?.removeFromSuperview()
            freezeFrame = nil
            let scroll = canvasScrollView
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                self.updateInsets()
                let inset = scroll.contentInset
                let x = PageLayout.pinnedOffsetX(
                    scroll.contentOffset.x, contentWidth: scroll.contentSize.width,
                    viewWidth: self.bounds.width, leftInset: inset.left, rightInset: inset.right
                )
                let maxY = max(scroll.contentSize.height + inset.bottom - scroll.bounds.height, -inset.top)
                let y = min(max(scroll.contentOffset.y, -inset.top), maxY)
                scroll.contentOffset = CGPoint(x: x, y: y)
                self.viewportDidChange()
            }
        }

        /// A grab can't survive a resize (rotation): the finger's travel means nothing afterwards.
        func cancelSideGrabForResize() {
            if sideGrab != nil {
                sideGrabGesture.isEnabled = false
                sideGrabGesture.isEnabled = true
                endSideGrab(commit: false)
            }
        }

        // MARK: Geometry

        /// Content size, offset and insets for the current `delta`: the page edge follows the finger, the
        /// ink stays where it is. Insets shrink as the paper takes the room they made, so UIKit's offset
        /// range never clamps the offset mid-drag.
        func applyGrabGeometry() {
            guard let session = sideGrab else { return }
            let scroll = canvasScrollView
            let z = scroll.zoomScale
            let delta = session.grab.delta * z
            sizeContent()
            var insets = session.startInsets
            var offset = session.startOffset
            switch session.grab.side {
            case .left:
                insets.left = max(session.startInsets.left - delta, 0)
                offset.x += delta
            case .right:
                insets.right = max(session.startInsets.right - delta, 0)
            }
            if scroll.contentInset != insets {
                scroll.contentInset = insets
            }
            if scroll.contentOffset != offset {
                scroll.contentOffset = offset
            }
            layoutPreview()
            viewportDidChange()
        }

        /// Strips for the visible pages at the current `delta`.
        func layoutPreview() {
            guard let session = sideGrab else { return }
            let z = canvasScrollView.zoomScale
            let visible = layout.visiblePages(in: PageLayout.contentRect(visible: canvasScrollView.bounds, zoom: z))
            let wanted = Set(visible.map { layout.pageIDs[$0] })
            for (id, strip) in session.strips where !wanted.contains(id) {
                strip.removeFromSuperview()
                session.strips[id] = nil
            }
            let pixelScale = min(max((window?.screen.scale ?? traitCollection.displayScale), 1) * max(z, 0.5), 8)
            for index in visible {
                let id = layout.pageIDs[index]
                let strip = session.strips[id] ?? {
                    let strip = PreviewStrip()
                    contentView.addSubview(strip)
                    session.strips[id] = strip
                    return strip
                }()
                strip.configure(
                    PreviewStrip.Marks(
                        template: templateProvider?(id) ?? .blank, page: layout.frame(at: index), baseWidth: session.grab.baseWidth,
                        leftExtension: pageExtension.left, pixelScale: pixelScale
                    ),
                    appearance: paperAppearance
                )
                strip.place(side: session.grab.side, extent: session.grab.delta, hairline: 1 / pixelScale)
            }
        }

        private func removePreview() {
            guard let session = sideGrab else { return }
            for strip in session.strips.values {
                strip.removeFromSuperview()
            }
            session.strips = [:]
        }

        /// The dark width tag above the finger ("+50 %"), clear of the hand.
        private func placeWidthTag(near touch: CGPoint) {
            guard let session = sideGrab else { return }
            let tag = widthTag ?? {
                let tag = PaddedLabel()
                tag.font = .systemFont(ofSize: 13, weight: .semibold)
                tag.textColor = .white
                tag.backgroundColor = UIColor(white: 0.12, alpha: 0.86)
                tag.layer.cornerRadius = 10
                tag.layer.cornerCurve = .continuous
                tag.clipsToBounds = true
                tag.isUserInteractionEnabled = false
                tag.accessibilityIdentifier = "widthTag"
                addSubview(tag)
                widthTag = tag
                return tag
            }()
            tag.isHidden = false
            tag.text = session.grab.label
            let size = tag.intrinsicContentSize
            let gap: CGFloat = 56
            let x = min(max(touch.x - size.width / 2, 8), bounds.width - size.width - 8)
            let y = min(max(touch.y - gap - size.height, safeAreaInsets.top + 8), bounds.height - size.height - 8)
            UIView.performWithoutAnimation {
                tag.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            }
        }
    }
#endif
