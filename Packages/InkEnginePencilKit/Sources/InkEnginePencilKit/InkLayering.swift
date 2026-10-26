import InkModel
import PencilKit

/// Highlighter strokes draw beneath all other ink, so a highlight laid over writing never hides it
/// (#120). Within each layer strokes keep their order. Every PencilKit drawing of a page (canvas,
/// rasters, thumbnails, lift image) layers this way; PDF export paints highlights first too.
enum InkLayering {
    static func isHighlight(_ stroke: PKStroke) -> Bool {
        stroke.ink.inkType == .marker
    }

    /// Same answer as for the stroke's PencilKit conversion, without converting it.
    static func isHighlight(_ stroke: Stroke) -> Bool {
        PencilKitConversion.inkType(stroke.rendering?.ink ?? "", fallback: stroke.tool) == .marker
    }

    /// `items` with highlights first, each layer in its original order.
    static func layered<T>(_ items: [T], isHighlight: (T) -> Bool) -> [T] {
        var highlights: [T] = []
        var ink: [T] = []
        for item in items {
            if isHighlight(item) {
                highlights.append(item)
            } else {
                ink.append(item)
            }
        }
        return highlights + ink
    }

    static func layered(_ strokes: [PKStroke]) -> [PKStroke] {
        layered(strokes, isHighlight: isHighlight)
    }

    /// Whether some highlight in `strokes` (drawing order) is covered by ink drawn before it, i.e.
    /// layering would change what shows. Cheap check to skip a canvas rebuild after a highlight commits.
    static func highlightCoversInk(_ strokes: [PKStroke]) -> Bool {
        var inkBounds: [CGRect] = []
        for stroke in strokes {
            if isHighlight(stroke) {
                let bounds = stroke.renderBounds
                if inkBounds.contains(where: { $0.intersects(bounds) }) {
                    return true
                }
            } else {
                inkBounds.append(stroke.renderBounds)
            }
        }
        return false
    }
}
