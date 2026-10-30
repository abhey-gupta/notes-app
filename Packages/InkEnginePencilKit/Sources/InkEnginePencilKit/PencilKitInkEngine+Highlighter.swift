import InkEngine
import InkGeometry
import InkModel
import UIKit

/// The highlighter (#120) draws through the shared `InkInputView`, like pens with pressure off (`+FlatPen`),
/// and never touches a PencilKit canvas: the live band is a shape layer in its page's ``PageLayerView``,
/// beneath the ink raster and the canvas, so the writing under it shows through from the first frame. On
/// lift the same layer becomes the committed stroke's (no handoff), the stroke is reported and kept as
/// pending until the document echoes it back (``refreshHighlights(_:snapshot:)``).
extension PencilKitInkEngine {
    /// The current tool is the highlighter.
    var usesHighlighter: Bool {
        tool.penKind == .highlighter
    }

    /// Draws the live band; commits it on lift.
    func drawHighlighter(_ event: InkInputTracker.Event) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch event {
        case let .began(live):
            cancelLiveHighlight()
            let layer = Highlight.makeLayer()
            pageViews[live.page]?.addLiveHighlight(layer)
            selection.liveHighlight = LiveHighlight(
                page: live.page, template: Highlight.stroke(color: tool.color, width: tool.width, nib: tool.highlighterNib, samples: []),
                layer: layer
            )
            showLiveHighlight(live)
        case let .updated(live):
            showLiveHighlight(live)
        case let .ended(live):
            commitHighlight(live)
        case .cancelled:
            cancelLiveHighlight()
        }
    }

    private func showLiveHighlight(_ live: LiveStroke) {
        guard let current = selection.liveHighlight else { return }
        let stroke = Highlight.stroke(current.template, samples: live.displaySamples)
        Highlight.configure(current.layer, stroke: stroke, color: highlightColor(stroke))
        showHighlightSpill(stroke, from: current.page)
    }

    func cancelLiveHighlight() {
        if let live = selection.liveHighlight {
            removeLiveBand(live.layer, on: live.page)
        }
        selection.liveHighlight = nil
        clearHighlightSpill()
    }

    /// Reports the finished stroke; its page view keeps the live layer as the stroke's own.
    private func commitHighlight(_ live: LiveStroke) {
        guard let current = selection.liveHighlight else { return }
        selection.liveHighlight = nil
        guard !live.samples.isEmpty else {
            removeLiveBand(current.layer, on: current.page)
            clearHighlightSpill()
            return
        }
        commitHighlight(Highlight.stroke(current.template, samples: live.samples), layer: current.layer, to: live.page)
    }

    /// Reports `stroke` (a finished highlight or a snapped shape, `+ShapeSnap`) as the piece each page it
    /// reached keeps (#163); `layer`, its live band, and its bands on other pages become the pieces' own.
    func commitHighlight(_ stroke: Stroke, layer: CAShapeLayer, to page: PageID) {
        let pieces = pieces(of: stroke, from: page)
        var bands = crossPage.bands
        crossPage.bands = [:]
        bands[page] = layer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (piecePage, piece) in pieces {
            if let band = bands.removeValue(forKey: piecePage) {
                Highlight.configure(band, stroke: piece, color: highlightColor(piece))
                if let view = pageViews[piecePage] {
                    view.adoptLiveHighlight(band, as: piece)
                } else {
                    band.removeFromSuperlayer()
                }
            }
            pending[piecePage, default: []].append(PendingStroke(stroke: piece, pk: nil))
        }
        for (bandPage, band) in bands {
            removeLiveBand(band, on: bandPage)
        }
        CATransaction.commit()
        layoutPages()
        delegate?.engine(self, didCommit: pieces)
    }

    /// Brings a page view's highlight layers up to date: the snapshot's highlights plus pending ones, in
    /// order, without any the selection has lifted. Cheap when nothing changed (``PageLayerView/HighlightKey``).
    func refreshHighlights(_ view: PageLayerView, snapshot: PageSnapshot) {
        let hidden = selection.strokes.union(selection.liftedHighlights)
        let pendingHighlights = (pending[snapshot.id] ?? []).filter(\.isHighlight).map(\.stroke)
        let key = PageLayerView.HighlightKey(
            rev: snapshot.rev, theme: theme, colors: strokeCache.generation, pendingCount: pendingHighlights.count, hidden: hidden
        )
        guard view.highlightKey != key else { return }
        let strokes = snapshot.strokes.filter { Highlight.isHighlight($0) && !hidden.contains($0.id) } + pendingHighlights
        view.setHighlights(strokes, key: key) { highlightColor($0) }
    }

    func highlightColor(_ stroke: Stroke) -> CGColor {
        Highlight.color(uiColor(stroke.color))
    }
}

/// The highlight being drawn: its page, the stroke it commits to (ID, color, width) and its layer.
struct LiveHighlight {
    let page: PageID
    let template: Stroke
    let layer: CAShapeLayer
}
