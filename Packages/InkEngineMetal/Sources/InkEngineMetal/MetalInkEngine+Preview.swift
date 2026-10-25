import InkEngine
import InkModel
import SwiftUI
import UIKit

public extension MetalInkEngine {
    /// A self-contained engine on one page of sample ink, for visual checks (SwiftUI previews,
    /// debug screens). Draw with the Pencil (or a finger in the simulator); commits are echoed back
    /// as the document would. `nil` if Metal is unavailable.
    static func makePreviewView(
        palette: any InkPalette,
        theme: PaperTheme = .white,
        template: PageTemplate = .lined(spacing: 24),
        tool: ToolConfiguration = ToolConfiguration(tool: .pen(.fountain), color: .primary, width: 3, allowsFingerDrawing: true)
    ) -> UIView? {
        guard let engine = MetalInkEngine(palette: palette) else { return nil }
        return PreviewHostView(engine: engine, theme: theme, template: template, tool: tool)
    }
}

/// Owns a preview engine, fits one A4 page into its bounds and echoes commits.
@MainActor
private final class PreviewHostView: UIView, InkEngineDelegate {
    private let engine: MetalInkEngine
    private let page: VisiblePage
    private var snapshot: PageSnapshot

    init(engine: MetalInkEngine, theme: PaperTheme, template: PageTemplate, tool: ToolConfiguration) {
        self.engine = engine
        let size = Notebook.a4Portrait
        let page = Page(template: template, strokes: PreviewInk.strokes)
        self.page = VisiblePage(id: page.id, frame: CGRect(origin: .zero, size: size))
        snapshot = PageSnapshot(page: page, size: size)
        super.init(frame: .zero)
        backgroundColor = theme.isDark ? UIColor(white: 0.06, alpha: 1) : UIColor(white: 0.92, alpha: 1)
        engine.delegate = self
        engine.setTheme(theme)
        engine.setTool(tool)
        engine.setPages([snapshot])
        addSubview(engine.view)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        engine.view.frame = bounds
        let inset: CGFloat = 16
        let zoom = max(min((bounds.width - 2 * inset) / page.frame.width, (bounds.height - 2 * inset) / page.frame.height), 0.1)
        // Center the page: negative offsets put it inside the view.
        let offset = CGPoint(
            x: -(bounds.width - page.frame.width * zoom) / 2,
            y: -(bounds.height - page.frame.height * zoom) / 2
        )
        engine.setViewport(Viewport(contentOffset: offset, zoomScale: zoom, size: bounds.size, pages: [page]))
    }

    func engine(_: any InkEngine, didCommit stroke: Stroke, to page: PageID) {
        let edit = snapshot.page.addEdit([stroke])
        guard let next = try? snapshot.applying(edit) else { return }
        snapshot = next
        engine.apply(edit, to: page)
    }

    func engine(_: any InkEngine, didReceiveEraser _: [Sample], to _: PageID) {}
    func engine(_: any InkEngine, didReceiveLasso _: [CGPoint], to _: PageID) {}
    func engineDidBeginStroke(_: any InkEngine) {}
    func engine(_: any InkEngine, didShowSharpInkOn _: PageID) {}
}

/// Sample strokes: one per pen kind, written like real handwriting strokes (pressure ramps, speed).
enum PreviewInk {
    static var strokes: [Stroke] {
        [
            wave(origin: CGPoint(x: 60, y: 118), tool: .highlighter, color: .semantic(.accent), width: 16, amplitude: 0),
            wave(origin: CGPoint(x: 60, y: 120), tool: .fountain, color: .primary, width: 3, amplitude: 14),
            wave(origin: CGPoint(x: 60, y: 220), tool: .ballpoint, color: .semantic(.blue), width: 2, amplitude: 18),
            wave(origin: CGPoint(x: 60, y: 330), tool: .brush, color: .semantic(.red), width: 5, amplitude: 22),
        ]
    }

    static func wave(origin: CGPoint, tool: PenKind, color: InkColor, width: Float, amplitude: Float) -> Stroke {
        let samples = (0 ... 160).map { i in
            let u = Float(i) / 160
            let x = Float(origin.x) + u * 460
            return Sample(
                x: x,
                y: Float(origin.y) + amplitude * sin(u * 4 * .pi),
                force: 0.25 + 0.7 * sin(u * .pi),
                altitude: 0.7 + 0.8 * u,
                azimuth: 0.6,
                t: u * 0.8
            )
        }
        return Stroke(tool: tool, color: color, width: width, samples: samples)
    }
}

#if DEBUG
    /// Stand-in palette for previews only (the app passes `DesignSystem` tokens).
    private struct PreviewPalette: InkPalette {
        func paper(_ theme: PaperTheme) -> RGBA8 {
            theme.isDark ? RGBA8(r: 27, g: 28, b: 31) : RGBA8(r: 255, g: 255, b: 255)
        }

        func templateLine(_ theme: PaperTheme) -> RGBA8 {
            theme.isDark ? RGBA8(r: 255, g: 255, b: 255, a: 23) : RGBA8(r: 30, g: 33, b: 41, a: 41)
        }

        func ink(_ color: InkColor, on theme: PaperTheme) -> RGBA8 {
            let slot: SemanticInk
            switch color {
            case let .custom(rgba): return rgba
            case let .semantic(semantic): slot = semantic
            }
            let (light, dark): (UInt32, UInt32) = switch slot {
            case .primary: (0x1E21_29FF, 0xE9E8_E4FF)
            case .blue: (0x2C4F_D6FF, 0x5FD3_C4FF)
            case .red: (0xD240_2FFF, 0xFF8F_B1FF)
            case .accent: (0xE0A4_00FF, 0xFFC7_64FF)
            }
            return RGBA8(rgba: theme.isDark ? dark : light)
        }
    }

    private struct PreviewRepresentable: UIViewRepresentable {
        var theme: PaperTheme

        func makeUIView(context _: Context) -> UIView {
            MetalInkEngine.makePreviewView(palette: PreviewPalette(), theme: theme) ?? UIView()
        }

        func updateUIView(_: UIView, context _: Context) {}
    }

    #Preview("Ink · White") {
        PreviewRepresentable(theme: .white).ignoresSafeArea()
    }

    #Preview("Ink · Night") {
        PreviewRepresentable(theme: .night).ignoresSafeArea()
    }
#endif
