import CoreGraphics
import Foundation
import InkEngine
import InkModel
import UIKit

/// `InkEngine` that draws nothing and keeps every command it was given, for testing what feeds the engine
/// (the canvas host, page residency, the session) without PencilKit or Metal.
@MainActor
public final class RecordingInkEngine: InkEngine {
    public let view = UIView()
    public weak var delegate: (any InkEngineDelegate)?
    public var selectionColor: UIColor = .systemBlue
    public var thumbnailURL: ((PageID) -> URL?)?
    public var imageURL: ((ImageAssetID) -> URL?)?
    public var pageArtwork: ((PageID) -> (any PageArtwork)?)?

    public private(set) var viewports: [Viewport] = []
    public private(set) var pageSets: [[PageSnapshot]] = []
    public private(set) var tools: [ToolConfiguration] = []
    public private(set) var themes: [PaperTheme] = []
    public private(set) var palettes: [any InkPalette] = []
    public private(set) var applied: [(edit: PageEdit, page: PageID)] = []
    public private(set) var previews: [SelectionPreview?] = []
    public private(set) var prepared: [(strokes: Set<StrokeID>, page: PageID)] = []
    /// Pages handed to ``prepare(_:)``.
    public private(set) var preparedPages: [PageID] = []
    /// What ``render(page:size:scale:)`` returns.
    public var renderResult: CGImage?

    /// The pages last handed over.
    public var pages: [PageSnapshot] {
        pageSets.last ?? []
    }

    public init() {}

    public func setViewport(_ viewport: Viewport) {
        viewports.append(viewport)
    }

    public func setPages(_ pages: [PageSnapshot]) {
        pageSets.append(pages)
    }

    public func prepare(_ page: PageSnapshot) async {
        preparedPages.append(page.id)
    }

    public func setTool(_ tool: ToolConfiguration) {
        tools.append(tool)
    }

    public func setTheme(_ theme: PaperTheme) {
        themes.append(theme)
    }

    public func setPalette(_ palette: any InkPalette) {
        palettes.append(palette)
    }

    public func apply(_ edit: PageEdit, to page: PageID) {
        applied.append((edit, page))
    }

    public func setSelectionPreview(_ preview: SelectionPreview?) {
        previews.append(preview)
    }

    public func prepareSelectionPreview(_ strokes: Set<StrokeID>, on page: PageID) {
        prepared.append((strokes, page))
    }

    public func render(page _: PageSnapshot, size _: CGSize, scale _: CGFloat) async -> CGImage? {
        renderResult
    }
}
