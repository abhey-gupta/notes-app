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
    static let lightTraits = UITraitCollection(userInterfaceStyle: .light)

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
            if let template = selection.flatPenStroke, !live.samples.isEmpty {
                commitPen(Self.flatStroke(template, samples: live.samples), to: live.page)
            }
            selection.flatPenStroke = nil
            showFlatPen()
        case .cancelled:
            selection.flatPenLive = nil
            selection.flatPenStroke = nil
            showFlatPen()
        }
    }

    /// `canvas` finished a render: once every canvas given a committed stroke has, the image can drop them.
    func flatPenCanvasDidRender(_ canvas: PageCanvas) {
        guard let page = canvas.page, selection.flatPenAwaiting.remove(page) != nil, selection.flatPenAwaiting.isEmpty else { return }
        settleFlatPen()
    }

    /// Reports `stroke` (a finished pressure-off stroke or a snapped shape, `+ShapeSnap`), drawn so far in
    /// `selection.flatPen`, which keeps it until the canvases of the pages it reached have drawn it (#163).
    func commitPen(_ stroke: Stroke, to page: PageID) {
        let pieces = pieces(of: stroke, from: page)
        let canvases = pieces.compactMap { piecePage, piece in
            addPending(piece, PencilKitConversion.pkStroke(from: piece, color: uiColor(piece.color)), to: piecePage)
        }
        delegate?.engine(self, didCommit: pieces)
        guard !canvases.isEmpty else { return }
        selection.flatPenSettling.append(stroke)
        selection.flatPenSettlingPage = page
        selection.flatPenAwaiting.formUnion(canvases.compactMap(\.page))
        selection.flatPenGeneration += 1
        let generation = selection.flatPenGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flatPenRenderCap) { [weak self] in
            guard let self, selection.flatPenGeneration == generation else { return }
            settleFlatPen()
        }
    }

    func settleFlatPen() {
        selection.flatPenAwaiting = []
        selection.flatPenGeneration += 1
        selection.flatPenSettling = []
        selection.flatPenSettlingPage = nil
        showFlatPen()
    }

    /// Renders the live stroke (the samples so far, predicted ones too) as the stroke it will commit to,
    /// or a pen's snapped shape (`+ShapeSnap`), plus the committed strokes still settling, into
    /// `selection.flatPen` over the visible part of their bounds on every page they reach (#163); hides it
    /// when there is nothing to show.
    func showFlatPen() {
        var strokes = selection.flatPenSettling
        var pageID = selection.flatPenLive?.page ?? selection.flatPenSettlingPage
        if let live = selection.flatPenLive, let template = selection.flatPenStroke {
            strokes.append(Self.flatStroke(template, samples: live.displaySamples))
        }
        if let shape = shapeSnap.session, shape.layer == nil {
            strokes.append(shape.stroke)
            pageID = shape.page
        }
        guard let pageID else {
            hideInkImage(selection.flatPen)
            return
        }
        showInkImage(strokes, from: pageID, in: selection.flatPen, mask: selection.flatPenMask)
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
