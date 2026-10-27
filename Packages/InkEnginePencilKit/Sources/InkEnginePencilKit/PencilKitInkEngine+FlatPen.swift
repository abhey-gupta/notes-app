import InkEngine
import InkGeometry
import InkModel
import PencilKit
import UIKit

/// Pens with pressure off (#123). PencilKit sizes live points from the Pencil's force itself and can't be
/// told not to (its one force-blind ink, monoline, stops at 4 pt), so these strokes bypass the canvases:
/// the shared `InkInputView` records them at neutral force, and on lift the stroke is committed with one
/// point size throughout (the size the pen's ink draws at neutral force, as the popover preview shows it)
/// and appended to the canvas as that PencilKit stroke, so re-rendering it never shapes it by pressure.
///
/// While the Pencil is down, the very same stroke (same ID, so same seed and ink texture) is rendered by
/// PencilKit after every touch into `selection.flatPen`, at screen × zoom resolution: the live image and
/// the committed stroke are the same pixels from the same renderer, so the handoff at lift shows nothing
/// (a line drawn by a shape layer never matched PencilKit's ink, most visibly zoomed in).
extension PencilKitInkEngine {
    /// How long the live image stays after lift if the canvas never reports a render.
    static let flatPenRenderCap: TimeInterval = 0.5

    /// PencilKit adapts ink for dark appearance; the canvas is pinned to light (`RenderJob.traits`).
    private static let lightTraits = UITraitCollection(userInterfaceStyle: .light)

    /// The current tool is a pen with pressure off: input and drawing go through this path (the
    /// highlighter has its own, `+Highlighter`).
    var usesFlatPen: Bool {
        tool.penKind != nil && !usesHighlighter && !tool.pressure
    }

    func setUpFlatPen() {
        selection.flatPen.anchorPoint = .zero
        selection.flatPen.contentsGravity = .resize
        selection.flatPen.isHidden = true
        selection.view.layer.insertSublayer(selection.flatPen, at: 0)
    }

    /// Draws the live stroke; commits it on lift.
    ///
    /// A committed stroke stays in the image until its canvas reports a render (`settling`), through the
    /// next stroke too: fast writing re-touches before PencilKit has drawn the last stroke, and the image
    /// must not drop it meanwhile (a blink at every quick lift).
    func drawFlatPen(_ event: InkInputTracker.Event) {
        guard let kind = tool.penKind else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch event {
        case let .began(live):
            if selection.flatPenSettlingPage != live.page {
                settleFlatPen() // one image, one page: strokes settling on another page go now
            }
            selection.flatPenStroke = Self.flatStroke(kind, color: tool.color, width: tool.width, samples: [])
            selection.flatPenLive = live
            showFlatPen()
        case let .updated(live):
            selection.flatPenLive = live
            showFlatPen()
        case let .ended(live):
            selection.flatPenLive = nil
            if let (stroke, canvas) = commitFlatPen(live) {
                selection.flatPenSettling.append(stroke)
                selection.flatPenSettlingPage = live.page
                selection.flatPenCanvas = canvas
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.flatPenRenderCap) { [weak self, weak canvas] in
                    guard let self, let canvas, selection.flatPenCanvas === canvas else { return }
                    settleFlatPen()
                }
            }
            selection.flatPenStroke = nil
            showFlatPen()
        case .cancelled:
            selection.flatPenLive = nil
            selection.flatPenStroke = nil
            showFlatPen()
        }
    }

    /// `canvas` finished a render: the committed strokes are on screen, so the image can drop them.
    func flatPenCanvasDidRender(_ canvas: PageCanvas) {
        guard selection.flatPenCanvas === canvas else { return }
        settleFlatPen()
    }

    private func settleFlatPen() {
        selection.flatPenCanvas = nil
        selection.flatPenSettling = []
        selection.flatPenSettlingPage = nil
        showFlatPen()
    }

    /// Renders the live stroke (the samples so far, predicted ones too) as the stroke it will commit to,
    /// plus the committed strokes still settling, into `selection.flatPen` over the visible part of their
    /// bounds; hides it when there is nothing to show.
    private func showFlatPen() {
        var strokes = selection.flatPenSettling
        if let live = selection.flatPenLive, let template = selection.flatPenStroke {
            strokes.append(Self.flatStroke(template, samples: live.displaySamples))
        }
        guard let pageID = selection.flatPenLive?.page ?? selection.flatPenSettlingPage, let page = viewport.page(pageID),
              !strokes.isEmpty
        else {
            hideFlatPen()
            return
        }
        let onPage = CGRect(origin: .zero, size: page.frame.size)
        let visible = visibleRect.offsetBy(dx: -page.frame.minX, dy: -page.frame.minY).insetBy(dx: -8, dy: -8)
        let bounds = strokes.reduce(CGRect.null) { $0.union($1.bounds) }
        let rect = bounds.intersection(onPage).intersection(visible).integral
        guard !rect.isNull, !rect.isEmpty else {
            selection.flatPen.isHidden = true
            return
        }
        let screenScale = host.window?.screen.scale ?? host.traitCollection.displayScale
        let scale = min(max(screenScale, 1) * max(viewport.zoomScale, 0.25), maximumRasterDimension / max(rect.width, rect.height))
        let drawing = PKDrawing(strokes: strokes.map { PencilKitConversion.pkStroke(from: $0, color: uiColor($0.color)) })
        var image: CGImage?
        Self.lightTraits.performAsCurrent {
            image = drawing.image(from: rect, scale: scale).cgImage
        }
        selection.flatPen.contents = image
        selection.flatPen.frame = rect.offsetBy(dx: page.frame.minX, dy: page.frame.minY)
        selection.flatPen.isHidden = false
    }

    private func hideFlatPen() {
        selection.flatPen.isHidden = true
        selection.flatPen.contents = nil
    }

    /// Reports the finished stroke and shows it on its page's canvas (if it has one) as pending, like a
    /// stroke PencilKit drew, until the document echoes it back.
    /// - Returns: The stroke and the canvas now drawing it; `nil` if nothing was committed or no canvas has it.
    private func commitFlatPen(_ live: LiveStroke) -> (Stroke, PageCanvas)? {
        guard !live.samples.isEmpty, let template = selection.flatPenStroke else { return nil }
        let stroke = Self.flatStroke(template, samples: live.samples)
        let pk = PencilKitConversion.pkStroke(from: stroke, color: uiColor(stroke.color))
        pending[live.page, default: []].append(PendingStroke(stroke: stroke, pk: pk))
        var drawnBy: PageCanvas?
        if let canvas = canvas(for: live.page), !canvas.isUsingTool {
            isSettingDrawing = true
            canvas.view.drawing.strokes.append(pk)
            isSettingDrawing = false
            canvas.ids.append(stroke.id)
            drawnBy = canvas
        }
        delegate?.engine(self, didCommit: stroke, to: live.page)
        return drawnBy.map { (stroke, $0) }
    }

    /// The point every sample of a pressure-off stroke renders with: the pen's PencilKit width for the
    /// toolbar width (``PencilKitConversion/pencilKitWidth(for:width:)``, what a live stroke gets at neutral
    /// force and the popover preview draws), with the wash live watercolor strokes carry.
    static func flatPoint(_ kind: PenKind, width: Float) -> PointRendering {
        let size = Float(PencilKitConversion.pencilKitWidth(for: kind, width: width))
        return PointRendering(width: size, height: size, secondaryScale: kind == .brush ? Double(InkPreview.watercolorSecondaryScale) : 1)
    }

    /// A stroke of `samples` (already at neutral force) whose stored rendering is ``flatPoint(_:width:)``
    /// throughout, so PencilKit draws it one width whatever the samples' tilt.
    static func flatStroke(_ kind: PenKind, color: InkColor, width: Float, samples: [Sample]) -> Stroke {
        let stroke = Stroke(tool: kind, color: color, width: width, samples: samples)
        var rendering = stroke.derivedRendering
        rendering.points = Array(repeating: flatPoint(kind, width: width), count: samples.count)
        if #available(iOS 27, *), kind == .brush {
            rendering.renderGroupID = UUID()
        }
        return Stroke(id: stroke.id, tool: kind, color: color, width: width, samples: samples, rendering: rendering)
    }

    /// `template` (``flatStroke(_:color:width:samples:)``) over `samples`: same ID, seed and render group,
    /// so every render of the stroke, live or committed, looks the same.
    static func flatStroke(_ template: Stroke, samples: [Sample]) -> Stroke {
        var rendering = template.resolvedRendering
        rendering.points = Array(repeating: flatPoint(template.tool, width: template.width), count: samples.count)
        return Stroke(
            id: template.id, tool: template.tool, color: template.color, width: template.width, samples: samples, rendering: rendering
        )
    }
}
