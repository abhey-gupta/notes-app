import InkEngine
import InkModel
import UIKit

/// Eraser, lasso and laser input: the shared `InkInputView` (content-sized, above the canvases) reports samples in
/// page space; the engine forwards them and draws nothing (`Tools` resolves erasing, ARCHITECTURE.md §6).
/// The highlighter (`+Highlighter`, #120) and pens with pressure off (`+FlatPen`, #123) take the same route
/// and are drawn and committed by the engine.
extension PencilKitInkEngine: InkInputViewDelegate {
    public func inkInputView(_: InkInputView, targetAt point: CGPoint) -> InkInputTarget? {
        // The input view is content-sized: `point` is in content space, page space is a translation away.
        guard let page = viewport.pages.first(where: { $0.frame.contains(point) }) else { return nil }
        return InkInputTarget(page: page.id, viewToPage: CGAffineTransform(translationX: -page.frame.minX, y: -page.frame.minY))
    }

    public func inkInputView(_: InkInputView, didProduce event: InkInputTracker.Event) {
        draw(event)
        switch event {
        case let .began(stroke):
            if stroke.device == .pencil {
                pencilSeen()
            }
            eraserProgress = EraserProgress(touch: stroke.touch, emitted: 0, page: stroke.page)
            delegate?.engineDidBeginStroke(self)
            emitEraser(stroke)
        case let .updated(stroke):
            emitEraser(stroke)
        case let .ended(stroke):
            emitEraser(stroke)
            if tool.tool == .lasso {
                delegate?.engine(self, didReceiveLasso: stroke.samples.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }, to: stroke.page)
            }
        case .cancelled:
            break
        }
    }

    /// What the tool shows while the Pencil moves.
    private func draw(_ event: InkInputTracker.Event) {
        switch tool.tool {
        case .lasso: drawLasso(event)
        case .eraser: trackEraserCursor(event)
        case .laser: drawLaser(event)
        case .pen where usesHighlighter: drawHighlighter(event)
        case .pen where usesFlatPen: drawFlatPen(event)
        case .pen: break
        }
    }

    /// Reports the eraser's new samples to the page each lies on: an eraser dragged onto the next page
    /// erases there too (#163). The segment across the seam goes to both pages.
    private func emitEraser(_ stroke: LiveStroke) {
        guard tool.tool == .eraser, let progress = eraserProgress, progress.touch == stroke.touch,
              stroke.samples.count > progress.emitted else { return }
        guard let start = viewport.page(stroke.page) else {
            eraserProgress?.emitted = stroke.samples.count
            delegate?.engine(self, didReceiveEraser: Array(stroke.samples[progress.emitted...]), to: progress.page)
            return
        }
        // Samples are in the start page's space; each run is moved into its own page's.
        func moved(_ s: Sample, to page: VisiblePage) -> Sample {
            var s = s
            s.x += Float(start.frame.minX - page.frame.minX)
            s.y += Float(start.frame.minY - page.frame.minY)
            return s
        }
        var page = viewport.page(progress.page) ?? start
        var runs: [(page: VisiblePage, samples: [Sample])] = [(page, [])]
        var previous = progress.emitted > 0 ? stroke.samples[progress.emitted - 1] : nil
        for sample in stroke.samples[progress.emitted...] {
            let point = CGPoint(x: start.frame.minX + CGFloat(sample.x), y: start.frame.minY + CGFloat(sample.y))
            if !page.frame.contains(point), let next = viewport.pages.first(where: { $0.id != page.id && $0.frame.contains(point) }) {
                runs[runs.count - 1].samples.append(moved(sample, to: page))
                page = next
                runs.append((page, previous.map { [moved($0, to: page)] } ?? []))
            }
            runs[runs.count - 1].samples.append(moved(sample, to: page))
            previous = sample
        }
        eraserProgress = EraserProgress(touch: stroke.touch, emitted: stroke.samples.count, page: page.id)
        for run in runs where !run.samples.isEmpty {
            delegate?.engine(self, didReceiveEraser: run.samples, to: run.page.id)
        }
    }
}

/// The eraser touch, how many of its samples were reported and the page they last went to.
struct EraserProgress {
    let touch: TouchID
    var emitted: Int
    var page: PageID
}
