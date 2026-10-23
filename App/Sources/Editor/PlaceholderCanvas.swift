import DesignSystem
import enum InkModel.InkColor
import SwiftUI
import Tools

/// SwiftUI stand-in for `CanvasHostView` (#21): vertical stack of A4 pages on the desk, template + sample ink,
/// and finger "inking" so focus mode and undo can be exercised. Drag on a page draws; drag on the desk scrolls.
struct PlaceholderCanvas: View {
    let notebook: NotebookSummary
    let paper: PaperTheme
    let pattern: PaperPattern
    let state: EditorState
    let tools: ToolState
    @Binding var currentPage: Int?

    /// Page top sits just under the capsules (mock: page 74 pt from the top, capsules end at 82).
    static let topInset: CGFloat = 48
    static let pageGap: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let width = Self.pageWidth(for: proxy.size.width)
            let height = (width * Tokens.Size.pageA4.height / Tokens.Size.pageA4.width).rounded()
            ScrollView(.vertical) {
                LazyVStack(spacing: Self.pageGap) {
                    ForEach(0 ..< notebook.pageCount, id: \.self) { index in
                        PageView(index: index, ink: notebook.sampleInk, paper: paper, pattern: pattern, state: state, tools: tools)
                            .frame(width: width, height: height)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
                .frame(maxWidth: .infinity)
                .padding(.top, Self.topInset)
                .padding(.bottom, 96)
            }
            .scrollPosition(id: $currentPage, anchor: .center)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting {
                    state.exitFocus()
                }
            }
            .accessibilityIdentifier("canvas")
        }
    }

    /// Mock: 760 of 1194 in landscape. Keep generous margins for finger scrolling either side.
    static func pageWidth(for available: CGFloat) -> CGFloat {
        max(320, min(available - 192, 880)).rounded()
    }
}

private struct PageView: View {
    let index: Int
    let ink: SampleInk.Kind?
    let paper: PaperTheme
    let pattern: PaperPattern
    let state: EditorState
    let tools: ToolState

    @State private var live: [CGPoint] = []

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / Tokens.Size.pageA4.width
            ZStack {
                PaperSurface(paper, pattern: pattern, spacing: Tokens.Size.templateSpacing * scale)
                if let ink {
                    Canvas { context, _ in
                        context.scaleBy(x: scale, y: scale)
                        SampleInk.draw(ink, page: index, paper: paper, in: context)
                    }
                    .allowsHitTesting(false)
                }
                Canvas { context, size in
                    for stroke in state.strokes where stroke.page == index {
                        draw(
                            stroke.points,
                            ink: InkStyle(tool: stroke.tool, color: stroke.color, width: stroke.width),
                            in: context,
                            size: size
                        )
                    }
                    if !live.isEmpty {
                        draw(live, ink: InkStyle(tool: tools.tool, color: tools.currentColor, width: liveWidth), in: context, size: size)
                    }
                }
            }
            .contentShape(.rect)
            .gesture(inking(width: proxy.size.width))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(index + 1)")
    }

    private func inking(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let point = CGPoint(x: value.location.x / width, y: value.location.y / width)
                if live.isEmpty {
                    state.strokeBegan()
                }
                live.append(point)
                if tools.tool == .eraser {
                    state.erase(page: index, at: point, radius: eraserRadius / width)
                }
            }
            .onEnded { _ in
                state.commit(page: index, points: live, tools: tools)
                live = []
                state.strokeEnded()
            }
    }

    private var liveWidth: Float {
        tools.tool == .highlighter ? tools.highlighter.width : tools.pen.width
    }

    private var eraserRadius: CGFloat {
        max(CGFloat(tools.eraser.width) / 2, 8)
    }

    private struct InkStyle {
        let tool: Tool
        let color: InkColor
        let width: Float
    }

    private func draw(_ points: [CGPoint], ink: InkStyle, in context: GraphicsContext, size: CGSize) {
        let tool = ink.tool, color = ink.color, width = ink.width
        guard let first = points.first else { return }
        var path = Path()
        path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.width))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.width))
        }
        if points.count == 1 {
            path.addLine(to: CGPoint(x: first.x * size.width + 0.1, y: first.y * size.width))
        }
        let scale = size.width / Tokens.Size.pageA4.width
        switch tool {
        case .pen:
            context.stroke(
                path,
                with: .color(color.color(on: paper)),
                style: StrokeStyle(lineWidth: CGFloat(width) * scale, lineCap: .round, lineJoin: .round)
            )
        case .highlighter:
            var layer = context
            layer.blendMode = paper.isDark ? .screen : .multiply
            layer.stroke(
                path,
                with: .color(color.color(on: paper).opacity(Tokens.highlighter.alpha * (paper.isDark ? 0.5 : 1))),
                style: StrokeStyle(lineWidth: CGFloat(width) * scale, lineCap: .butt, lineJoin: .round)
            )
        case .lasso:
            context.stroke(
                path,
                with: .color(Tokens.Colors.selection.color),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 5])
            )
        case .eraser:
            if let last = points.last {
                let r = eraserRadius
                let circle = CGRect(x: last.x * size.width - r, y: last.y * size.width - r, width: 2 * r, height: 2 * r)
                context.stroke(Path(ellipseIn: circle), with: .color(paper.ink(.primary).color.opacity(0.35)), lineWidth: 1)
            }
        }
    }
}
