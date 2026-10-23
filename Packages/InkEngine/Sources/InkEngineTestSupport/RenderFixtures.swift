import CoreGraphics
import Foundation
import InkEngine
import InkModel

/// Deterministic pages for renderer tests, shared by every engine (ARCHITECTURE.md §13: same fixtures
/// through both engines keep the PencilKit adapter honest).
public enum RenderFixtures {
    /// A4 portrait.
    public static let pageSize = Notebook.a4Portrait

    /// Fixed IDs so goldens are stable.
    public static func pageID(_ n: UInt8) -> PageID {
        PageID(uuid: UUID(uuid: (0, 0, 0, 0, 0, 0, 0x70, 0, 0x80, 0, 0, 0, 0, 0, 0, n)))
    }

    /// Fixed stroke ID.
    public static func strokeID(_ n: UInt8) -> StrokeID {
        StrokeID(uuid: UUID(uuid: (0, 0, 0, 0, 0, 1, 0x70, 0, 0x80, 0, 0, 0, 0, 0, 0, n)))
    }

    /// Straight line from `a` to `b`, one sample per `step` pt at 240 Hz.
    public static func line(
        _ id: UInt8,
        from a: CGPoint,
        to b: CGPoint,
        tool: PenKind = .ballpoint,
        color: InkColor = .primary,
        width: Float = 3,
        step: CGFloat = 2,
        force: Float = 0.5
    ) -> Stroke {
        let n = max(Int((hypot(b.x - a.x, b.y - a.y) / step).rounded(.up)), 1)
        let samples = (0 ... n).map { i in
            let u = CGFloat(i) / CGFloat(n)
            return Sample(
                x: Float(a.x + (b.x - a.x) * u),
                y: Float(a.y + (b.y - a.y) * u),
                force: force,
                altitude: 1.1,
                azimuth: 0.4,
                t: Float(i) / 240
            )
        }
        return Stroke(id: strokeID(id), tool: tool, color: color, width: width, samples: samples)
    }

    /// A sine scribble with varying pressure.
    public static func wave(_ id: UInt8, origin: CGPoint, tool: PenKind = .fountain, color: InkColor = .semantic(.blue)) -> Stroke {
        let samples = (0 ... 120).map { i in
            let x = Float(i) * 3
            return Sample(
                x: Float(origin.x) + x,
                y: Float(origin.y) + 30 * sin(x / 40),
                force: 0.2 + 0.7 * Float(i) / 120,
                altitude: 0.9,
                azimuth: 1,
                t: Float(i) / 240
            )
        }
        return Stroke(id: strokeID(id), tool: tool, color: color, width: 4, samples: samples)
    }

    /// One stroke per pen kind plus a custom color, on a lined page.
    public static var allPens: PageSnapshot {
        let strokes = [
            line(1, from: CGPoint(x: 60, y: 100), to: CGPoint(x: 520, y: 100), tool: .highlighter, color: .semantic(.accent), width: 18),
            line(2, from: CGPoint(x: 60, y: 160), to: CGPoint(x: 520, y: 160), tool: .ballpoint),
            wave(3, origin: CGPoint(x: 60, y: 260), tool: .fountain),
            wave(4, origin: CGPoint(x: 60, y: 380), tool: .brush, color: .semantic(.red)),
            line(5, from: CGPoint(x: 60, y: 480), to: CGPoint(x: 520, y: 700), color: .custom(RGBA8(rgba: 0x1E8E_6EFF)), width: 6),
        ]
        return PageSnapshot(page: Page(id: pageID(1), template: .lined(spacing: 24), strokes: strokes), size: pageSize)
    }

    /// An empty blank page.
    public static var blank: PageSnapshot {
        PageSnapshot(page: Page(id: pageID(2), template: .blank), size: pageSize)
    }

    /// `count` pages stacked vertically with a 24 pt gap (`PageLayout` defaults), for viewport tests.
    public static func stackedPages(_ count: Int) -> [VisiblePage] {
        (0 ..< count).map { i in
            VisiblePage(
                id: pageID(UInt8(10 + i)),
                frame: CGRect(x: 0, y: CGFloat(i) * (pageSize.height + 24), width: pageSize.width, height: pageSize.height)
            )
        }
    }
}

/// Palette with the §10 token values, for tests only (the app adapts `DesignSystem` tokens).
public struct FixturePalette: InkPalette {
    /// Creates the palette.
    public init() {}

    public func paper(_ theme: PaperTheme) -> RGBA8 {
        switch theme {
        case .white: RGBA8(rgba: 0xFFFF_FFFF)
        case .cream: RGBA8(rgba: 0xF6F0_E1FF)
        case .night: RGBA8(rgba: 0x1B1C_1FFF)
        }
    }

    public func templateLine(_ theme: PaperTheme) -> RGBA8 {
        theme.isDark ? RGBA8(r: 255, g: 255, b: 255, a: 23) : RGBA8(r: 30, g: 33, b: 41, a: 41)
    }

    public func ink(_ color: InkColor, on theme: PaperTheme) -> RGBA8 {
        switch color {
        case let .custom(rgba): rgba
        case let .semantic(slot):
            switch (slot, theme.isDark) {
            case (.primary, false): RGBA8(rgba: 0x1E21_29FF)
            case (.primary, true): RGBA8(rgba: 0xE9E8_E4FF)
            case (.blue, false): RGBA8(rgba: 0x2C4F_D6FF)
            case (.blue, true): RGBA8(rgba: 0x5FD3_C4FF)
            case (.red, false): RGBA8(rgba: 0xD240_2FFF)
            case (.red, true): RGBA8(rgba: 0xFF8F_B1FF)
            case (.accent, false): RGBA8(rgba: 0xE0A4_00FF)
            case (.accent, true): RGBA8(rgba: 0xFFC7_64FF)
            }
        }
    }
}
