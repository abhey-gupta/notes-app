import Canvas
import DesignSystem
import Observation
import SwiftUI
import UIKit

/// Runs the overview's flight (#124): the page between the canvas and its cell (`PageFlightView`),
/// and the stage the overlay's SwiftUI parts animate in step with (`FlightTiming` segments of the
/// same 350 ms). Opening: `.arriving` on the first frame → (`.scrolled`, bringing the current cell on
/// screen) → `.flying` → `.open`. Closing: `.leaving(index)` of the cell the page flies back from.
/// With Reduce Motion, or when a flight end is unavailable, everything crossfades instead.
@MainActor
@Observable
final class PagesFlight {
    enum Stage: Equatable {
        case arriving, scrolled, flying, open, leaving(Int)
    }

    /// Frames read on every layout and scroll without invalidating the view; consulted when a flight
    /// starts and by the reorder drag.
    @MainActor
    final class Geometry {
        /// The scroll view, in window coordinates.
        var scroll = CGRect.zero
        /// Visible cells' frames in the scroll view's space.
        var cells: [Int: CGRect] = [:]
        /// The grid's thumb size and spacing (smaller in compact, #209).
        var layout = PagesGridLayout(isCompact: false, width: 0, margin: Tokens.Spacing.libraryMargin)

        /// Where cell `index`'s thumbnail is on screen (window coordinates), if the cell is laid out.
        func thumbFrame(_ index: Int) -> CGRect? {
            guard let cell = cells[index] else { return nil }
            return CGRect(origin: CGPoint(x: scroll.minX + cell.minX, y: scroll.minY + cell.minY), size: layout.thumb)
        }

        /// Whole thumb inside the scroll view and clear of the template capsule.
        func isOnScreen(_ thumb: CGRect) -> Bool {
            var area = scroll
            area.size.height -= Tokens.Size.templateCapsuleHeight + 2 * Tokens.Spacing.xxl
            return area.contains(thumb)
        }
    }

    private(set) var stage: Stage = .arriving
    /// The SwiftUI parts (scrim, cells, header, capsule) are "in" once the page takes off, "out" once
    /// it flies back; each animates on its own segment of the flight.
    private(set) var isOpen = false
    /// A flyer is up over the anchor cell, which hides its own content meanwhile.
    private(set) var isFlying = false
    @ObservationIgnored let view = PageFlightView()
    @ObservationIgnored let geometry = Geometry()
    @ObservationIgnored private let model: PagesModel
    @ObservationIgnored private let paper: UIColor

    init(model: PagesModel, paper: UIColor) {
        self.model = model
        self.paper = paper
    }

    /// The cell the page flies from or to: the current one, or the tapped one while leaving.
    func anchorIndex(current: Int) -> Int {
        if case let .leaving(index) = stage {
            return index
        }
        return current
    }

    /// The anchor cell's own thumb is out while the flyer stands in for it: before the page has landed,
    /// and while it flies back. (A crossfade close leaves it in.)
    var hidesAnchorContent: Bool {
        switch stage {
        case .arriving, .scrolled, .flying: true
        case .open: false
        case .leaving: isFlying
        }
    }

    var isLeaving: Bool {
        if case .leaving = stage {
            return true
        }
        return false
    }

    /// Cells fade in from the anchor outwards, 25 ms per cell of distance.
    func rippleDelay(index: Int, anchor: Int) -> Double {
        let layout = geometry.layout
        let width = geometry.scroll.width - 2 * layout.margin + layout.gap
        let columns = max(1, Int(width / (layout.thumb.width + layout.gap)))
        let distance = max(abs(index % columns - anchor % columns), abs(index / columns - anchor / columns))
        return FlightTiming.rippleDelay(distance: distance)
    }

    // MARK: Opening

    /// First frame: the page takes off into its cell, after scrolling the grid there if it isn't on screen.
    func arrive(_ proxy: ScrollViewProxy, current: Int, reduceMotion: Bool) {
        model.didRenderFirstFrame()
        guard !reduceMotion else { return open() }
        if let thumb = geometry.thumbFrame(current), geometry.isOnScreen(thumb) {
            return takeOff(current)
        }
        guard model.entries.indices.contains(current) else { return open() }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(model.entries[current].id, anchor: .center)
        }
        stage = .scrolled
        settle(current, attempt: 1)
    }

    /// The lazy grid may need a frame or two after the scroll before the cell is where it will stay.
    private func settle(_ current: Int, attempt: Int) {
        FrameAfter.next { [self] in
            guard stage == .scrolled else { return }
            if let thumb = geometry.thumbFrame(current), geometry.isOnScreen(thumb) {
                takeOff(current)
            } else if attempt < 3 {
                settle(current, attempt: attempt + 1)
            } else {
                open()
            }
        }
    }

    private func takeOff(_ index: Int) {
        guard let cell = geometry.thumbFrame(index), let capture = model.capturePage(index, false) else { return open() }
        stage = .flying
        isFlying = true
        let plan = PageFlightView.Plan(
            from: view.pagePose(capture, thumb: cell.size), to: view.cellPose(capture, cell: cell), opening: true,
            paper: paper, snapshot: capture.snapshot, thumb: nil
        )
        view.fly(plan) { [self] in land() }
        isOpen = true
        loadThumb(index) { [self] image in
            if let image {
                view.setThumb(image)
            }
        }
    }

    /// The page is in its cell: the cell shows itself, the flyer leaves a frame later (same pixels).
    private func land() {
        guard stage == .flying else { return }
        isFlying = false
        open()
        FrameAfter.next { [self] in view.clear() }
    }

    /// Open without a flight (Reduce Motion, or no flight end): everything crossfades.
    private func open() {
        stage = .open
        isOpen = true
        model.didOpen()
    }

    // MARK: Closing

    /// Flies the page at `index` (the current one for Done / escape) back to the canvas, then dismisses.
    func close(to index: Int?, current: Int, reduceMotion: Bool) {
        guard stage == .open else { return }
        let target = min(index ?? current, model.entries.count - 1)
        guard target >= 0 else { return model.dismiss() }
        if index != nil {
            model.onShow(target)
        }
        model.willDismiss()
        stage = .leaving(target)
        guard !reduceMotion, let cell = geometry.thumbFrame(target), geometry.isOnScreen(cell),
              let capture = model.capturePage(target, true)
        else {
            isOpen = false
            let duration = reduceMotion ? FlightTiming.reduced : FlightTiming.duration
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [model] in model.dismiss() }
            return
        }
        // The thumbnail covers what the canvas snapshot doesn't (the page below the fold) from the first frame.
        loadThumb(target, orNil: true) { [self] thumb in
            guard stage == .leaving(target) else { return }
            isFlying = true
            let plan = PageFlightView.Plan(
                from: view.cellPose(capture, cell: cell), to: view.pagePose(capture, thumb: cell.size), opening: false,
                paper: paper, snapshot: capture.snapshot, thumb: thumb
            )
            view.fly(plan) { [model] in model.dismiss() }
            isOpen = false
        }
    }

    /// The cell's thumbnail from the cache (decoded off main). `orNil` calls back with `nil` when there is none.
    private func loadThumb(_ index: Int, orNil: Bool = false, _ apply: @escaping @MainActor (UIImage?) -> Void) {
        guard model.entries.indices.contains(index), let url = model.entries[index].thumbnail else {
            if orNil {
                apply(nil)
            }
            return
        }
        let key = ThumbnailCache.Key(url: url, version: model.thumbnailVersion(model.entries[index].id))
        Task {
            let image = await ThumbnailCache.shared.image(for: key)
            if image != nil || orNil {
                apply(image)
            }
        }
    }
}

/// The overview grid's thumb size and spacing: full size, or (compact, #209) two columns across the
/// grid, at most full size.
struct PagesGridLayout: Equatable {
    var thumb = Tokens.Size.pageThumb
    var gap = Tokens.Size.pageThumbGap
    var margin: CGFloat
    var isCompact: Bool

    init(isCompact: Bool, width: CGFloat, margin: CGFloat) {
        self.isCompact = isCompact
        self.margin = margin
        guard isCompact else { return }
        gap = 20
        guard width > 0 else { return }
        let full = Tokens.Size.pageThumb
        let side = min(full.width, ((width - 2 * margin - gap) / 2).rounded(.down))
        thumb = CGSize(width: side, height: (side * full.height / full.width).rounded())
    }

    var columns: [GridItem] {
        guard isCompact else {
            return [GridItem(.adaptive(minimum: thumb.width, maximum: thumb.width), spacing: gap, alignment: .top)]
        }
        return Array(repeating: GridItem(.fixed(thumb.width), spacing: gap, alignment: .top), count: 2)
    }
}
