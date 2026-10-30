#if canImport(UIKit)
    import UIKit

    /// Sizing: the fitted zoom on first layout and resizes, the content view and scroll content behind the
    /// zoom, and the insets that center narrow content (`CanvasHostView.swift` holds the class).
    extension CanvasHostView {
        /// Space below the last page (content pt) for pages of `pageSize`: room for the add-page button,
        /// or 5 % of a page without it (#172).
        public func footer(for pageSize: CGSize) -> CGFloat {
            showsAddPage ? Self.footerHeight : (pageSize.height * 0.05).rounded()
        }

        /// The add-page button came or went: the footer follows.
        func addPageButtonDidToggle(from oldValue: Bool) {
            guard showsAddPage != oldValue else { return }
            layout = PageLayout(pageIDs: layout.pageIDs, pageSize: layout.pageSize, gap: layout.gap, footer: footer(for: layout.pageSize))
            setNeedsLayout()
        }

        // MARK: Layout

        /// First layout and rotation/resizes: fit the page width (unless the user zoomed), keep the content
        /// point at the top of the viewport in place.
        func resize(from old: CGSize, to new: CGSize, refit: Bool = false) {
            let oldFit = refit ? scrollView.zoomScale : fitZoom
            fitZoom = Self.fitZoom(pageWidth: layout.pageSize.width, viewWidth: new.width, desk: fitDesk)
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

        /// Fitted zoom: the page as wide as the mock's (760 of 1194 landscape): the view less `desk` (96 pt,
        /// less in a split pane, ``fitDesk``) each side, at most 880 pt, at least 320 pt.
        static func fitZoom(pageWidth: CGFloat, viewWidth: CGFloat, desk: CGFloat = defaultFitDesk) -> CGFloat {
            guard pageWidth > 0 else { return 1 }
            let width = max(320, min(viewWidth - 2 * desk, 880)).rounded()
            return min(max(width / pageWidth, minimumZoom), maximumZoom)
        }

        public static let defaultFitDesk: CGFloat = 96

        /// A new ``fitDesk``: a fitted page refits (unless a live resize holds the canvas; its end does).
        func fitDeskDidChange(from old: CGFloat) {
            guard fitDesk != old, lastBoundsSize != .zero, liveResize == nil else { return }
            let size = lastBoundsSize
            resize(from: size, to: size, refit: abs(scrollView.zoomScale - fitZoom) < 0.001)
        }

        func setZoom(_ zoom: CGFloat) {
            scrollView.zoomScale = zoom
            sizeContent()
            state.zoomScale = scrollView.zoomScale
        }

        func layoutDidChange(from old: PageLayout) {
            state.pageCount = layout.pageCount
            guard layout != old else { return }
            sizeContent()
            updateInsets()
            viewportDidChange()
        }

        /// Content view bounds = layout size (unzoomed); its frame and the content size scale with zoom.
        /// During a side grab (#129) the content is as wide as the preview and shifted right by the paper
        /// a left grab added, so page x = 0 keeps its place on screen while the paper grows leftwards.
        func sizeContent() {
            let size = layout.contentSize
            let z = scrollView.zoomScale
            contentView.bounds = CGRect(origin: .zero, size: size)
            contentView.center = CGPoint(x: (grabLeftShift + size.width / 2) * z, y: size.height * z / 2)
            scrollView.contentSize = CGSize(width: max(size.width + grabWidthDelta, 1) * z, height: size.height * z)
        }

        /// Centers narrow content horizontally (none at fit width: edge to edge, #130); top/bottom clear
        /// the chrome (bottom only with the add-page button: without it the last page's footer is all, #172). Not while a side grab holds
        /// its own insets (`applyGrabGeometry`), the document is
        /// widening behind a frozen frame (``endWidening()`` settles them), or a live resize holds its own.
        func updateInsets() {
            guard !isUpdatingInsets, sideGrab == nil, !isSettling, liveResize == nil else { return }
            isUpdatingInsets = true
            defer { isUpdatingInsets = false }
            let width = layout.contentSize.width * scrollView.zoomScale
            let insets = UIEdgeInsets(
                top: safeAreaInsets.top + margins.top,
                left: PageLayout.sideInset(contentWidth: width, viewWidth: bounds.width, margin: margins.left),
                bottom: showsAddPage ? safeAreaInsets.bottom + margins.bottom : 0,
                right: PageLayout.sideInset(contentWidth: width, viewWidth: bounds.width, margin: margins.right)
            )
            if scrollView.contentInset != insets {
                scrollView.contentInset = insets
            }
        }

        /// New margins: the insets follow, and a viewport above the new top (the toolbar left the top edge)
        /// glides onto it; setting the smaller inset alone would clamp it in one jump. A bigger top margin
        /// leaves the viewport where it is. Not under a finger: the bounce settles it on release.
        func marginsDidChange(from old: UIEdgeInsets) {
            guard margins != old else { return }
            setNeedsLayout()
            guard !scrollView.isTracking else { return updateInsets() }
            let settle = {
                self.updateInsets()
                let top = -self.scrollView.contentInset.top
                if self.scrollView.contentOffset.y < top {
                    self.scrollView.contentOffset.y = top
                }
            }
            guard window != nil else { return settle() }
            UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut, .allowUserInteraction], animations: settle)
        }

        func centeredOffsetX() -> CGFloat {
            let width = layout.contentSize.width * scrollView.zoomScale
            return (width - bounds.width) / 2
        }
    }
#endif
