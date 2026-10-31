import DesignSystem
import SwiftUI

/// A setting's small looping demo (#228 mock 03): what it does, drawn on dotted paper. Loops while on screen;
/// with Reduce Motion it holds one telling frame. Drawn in a 240 × 140 space, fitted and centred.
struct SettingDemo: View {
    enum Kind {
        case tapToUndo, snapShapes, holdToErase, newPages, hideStatusBar, sync

        /// Seconds per loop.
        var duration: Double {
            switch self {
            case .tapToUndo, .newPages: 6
            default: 5
            }
        }

        /// The frame shown with Reduce Motion.
        var stillPhase: Double {
            switch self {
            case .tapToUndo: 0.29
            case .snapShapes: 0.75
            case .holdToErase: 0.5
            case .newPages: 0.6
            case .hideStatusBar: 0.5
            case .sync: 0.25
            }
        }
    }

    let kind: Kind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            Canvas { ctx, size in
                let phase = reduceMotion
                    ? kind.stillPhase
                    : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: kind.duration) / kind.duration
                dots(ctx, size)
                let scale = min(size.width / 240, size.height / 140)
                var demo = ctx
                demo.translateBy(x: (size.width - 240 * scale) / 2, y: (size.height - 140 * scale) / 2)
                demo.scaleBy(x: scale, y: scale)
                Painter(ctx: demo, scheme: scheme).draw(kind, phase)
            }
        }
        .background(Tokens.Colors.libraryBackground)
        .clipShape(.rect(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Tokens.Colors.separator, lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private func dots(_ ctx: GraphicsContext, _ size: CGSize) {
        let color = scheme == .dark ? Tokens.Colors.templateLine.dark.color : Tokens.Colors.templateLine.light.color
        var path = Path()
        for x in stride(from: 4.0, to: size.width, by: 8) {
            for y in stride(from: 4.0, to: size.height, by: 8) {
                path.addEllipse(in: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2))
            }
        }
        ctx.fill(path, with: .color(color))
    }
}

/// 0 before `a`, 1 after `b`, eased between.
private func ramp(_ p: Double, _ a: Double, _ b: Double) -> Double {
    let x = min(max((p - a) / (b - a), 0), 1)
    return x * x * (3 - 2 * x)
}

/// Rises over `a…b`, falls over `c…d`.
private func pulse(_ p: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
    ramp(p, a, b) * (1 - ramp(p, c, d))
}

/// Handwriting-like line: `humps` arcs of `width` from `start`, alternating up and down by `rise`.
private func wave(_ start: CGPoint, humps: Int, width: CGFloat, rise: CGFloat) -> Path {
    var path = Path()
    path.move(to: start)
    for i in 0 ..< humps {
        let x = start.x + CGFloat(i) * width
        let up: CGFloat = i.isMultiple(of: 2) ? -rise : rise
        path.addQuadCurve(to: CGPoint(x: x + width, y: start.y), control: CGPoint(x: x + width / 2, y: start.y + up * 2))
    }
    return path
}

private func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
}

private struct Painter {
    let ctx: GraphicsContext
    let scheme: ColorScheme

    private func color(_ dynamic: DynamicColor) -> Color {
        scheme == .dark ? dynamic.dark.color : dynamic.light.color
    }

    private var ink: Color {
        color(Tokens.Colors.inkPrimary)
    }

    private var accent: Color {
        color(Tokens.Colors.selection)
    }

    private var faint: Color {
        color(Tokens.Colors.textTertiary)
    }

    private var page: Color {
        color(Tokens.Colors.field)
    }

    private var edge: Color {
        color(Tokens.Colors.separator)
    }

    func draw(_ kind: SettingDemo.Kind, _ p: Double) {
        switch kind {
        case .tapToUndo: tapToUndo(p)
        case .snapShapes: snapShapes(p)
        case .holdToErase: holdToErase(p)
        case .newPages: newPages(p)
        case .hideStatusBar: hideStatusBar(p)
        case .sync: sync(p)
        }
    }

    private func stroke(_ path: Path, _ color: Color, width: CGFloat = 2.8, opacity: Double = 1) {
        guard opacity > 0 else { return }
        var c = ctx
        c.opacity = opacity
        c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private func fill(_ path: Path, _ color: Color, opacity: Double = 1) {
        guard opacity > 0 else { return }
        var c = ctx
        c.opacity = opacity
        c.fill(path, with: .color(color))
    }

    private func label(_ text: String, at point: CGPoint, color: Color, opacity: Double = 1) {
        guard opacity > 0 else { return }
        var c = ctx
        c.opacity = opacity
        c.draw(Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(color), at: point)
    }

    /// Fingertips: a soft blue disc with a ring, popping in and pressing.
    private func taps(_ centers: [CGPoint], _ p: Double, from a: Double) {
        let opacity = pulse(p, a, a + 0.04, a + 0.10, a + 0.14)
        let radius = 8 * (0.7 + 0.3 * ramp(p, a, a + 0.04) - 0.12 * ramp(p, a + 0.04, a + 0.08))
        for center in centers {
            fill(circle(center, radius), accent.opacity(0.16), opacity: opacity)
            stroke(circle(center, radius), accent, width: 1.4, opacity: opacity)
        }
    }

    private func chip(_ text: String, opacity: Double) {
        fill(Path(roundedRect: CGRect(x: 186, y: 16, width: 40, height: 18), cornerRadius: 9), accent, opacity: opacity)
        label(text, at: CGPoint(x: 206, y: 25), color: page, opacity: opacity)
    }

    /// Two fingers tap: the last stroke goes. Three: it comes back.
    private func tapToUndo(_ p: Double) {
        stroke(wave(CGPoint(x: 44, y: 52), humps: 8, width: 11, rise: 5), ink)
        stroke(wave(CGPoint(x: 150, y: 50), humps: 3, width: 11, rise: 4), ink)
        let last = wave(CGPoint(x: 44, y: 86), humps: 6, width: 26, rise: 4).trimmedPath(from: 0, to: ramp(p, 0, 0.16))
        stroke(last, ink, opacity: 1 - ramp(p, 0.30, 0.36) + ramp(p, 0.62, 0.68) - ramp(p, 0.90, 0.97))
        taps([CGPoint(x: 148, y: 114), CGPoint(x: 170, y: 108)], p, from: 0.22)
        taps([CGPoint(x: 138, y: 116), CGPoint(x: 158, y: 108), CGPoint(x: 178, y: 112)], p, from: 0.52)
        chip("Undo", opacity: pulse(p, 0.26, 0.30, 0.44, 0.50))
        chip("Redo", opacity: pulse(p, 0.56, 0.60, 0.76, 0.82))
    }

    /// A wobbly circle, a still Pencil (rings), then the perfect circle.
    private func snapShapes(_ p: Double) {
        var wobbly = Path()
        wobbly.move(to: CGPoint(x: 124, y: 37))
        wobbly.addCurve(to: CGPoint(x: 160, y: 79), control1: CGPoint(x: 152, y: 40), control2: CGPoint(x: 163, y: 60))
        wobbly.addCurve(to: CGPoint(x: 117, y: 110), control1: CGPoint(x: 157, y: 100), control2: CGPoint(x: 139, y: 112))
        wobbly.addCurve(to: CGPoint(x: 82, y: 73), control1: CGPoint(x: 95, y: 108), control2: CGPoint(x: 80, y: 93))
        wobbly.addCurve(to: CGPoint(x: 120, y: 37), control1: CGPoint(x: 84, y: 53), control2: CGPoint(x: 100, y: 39))
        stroke(wobbly.trimmedPath(from: 0, to: ramp(p, 0, 0.35)), ink, opacity: 1 - ramp(p, 0.55, 0.60))
        let tip = CGPoint(x: 120, y: 37)
        stroke(circle(tip, 6 * (0.6 + 1.8 * ramp(p, 0.36, 0.54))), accent, width: 1.5, opacity: pulse(p, 0.36, 0.40, 0.47, 0.54))
        fill(circle(tip, 3), accent, opacity: pulse(p, 0.30, 0.34, 0.54, 0.58))
        let grow = ramp(p, 0.55, 0.62)
        stroke(circle(CGPoint(x: 121, y: 74), 36 * (0.93 + 0.07 * grow)), ink, opacity: grow * (1 - ramp(p, 0.90, 0.97)))
    }

    /// The Pencil holds (a ring fills), then sweeps down, taking each stroke it crosses.
    private func holdToErase(_ p: Double) {
        let lines = [
            (wave(CGPoint(x: 58, y: 55), humps: 8, width: 16, rise: 4), 0.39),
            (wave(CGPoint(x: 52, y: 85), humps: 9, width: 16, rise: 4), 0.51),
            (wave(CGPoint(x: 62, y: 115), humps: 7, width: 16, rise: 4), 0.63),
        ]
        for (line, gone) in lines {
            stroke(line, ink, opacity: 1 - ramp(p, gone, gone + 0.03) + ramp(p, 0.92, 1))
        }
        let start = CGPoint(x: 120, y: 27)
        let hold = min(max((p - 0.06) / 0.22, 0), 1)
        let ring = Path { $0.addArc(
            center: start,
            radius: 10,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * hold),
            clockwise: false
        ) }
        stroke(ring, accent, width: 1.8, opacity: hold > 0 ? 1 - ramp(p, 0.28, 0.33) : 0)
        let tip = CGPoint(x: start.x, y: start.y + 100 * ramp(p, 0.30, 0.70))
        fill(circle(tip, 10), accent.opacity(0.14), opacity: pulse(p, 0.28, 0.32, 0.70, 0.76))
        fill(circle(tip, 3.5), accent, opacity: ramp(p, 0, 0.06) * (1 - ramp(p, 0.70, 0.78)))
    }

    private func sheet(_ rect: CGRect, opacity: Double = 1) {
        let path = Path(roundedRect: rect, cornerRadius: 3)
        fill(path, page, opacity: opacity)
        stroke(path, edge, width: 1, opacity: opacity)
    }

    private func rule(_ x: CGFloat, _ y: CGFloat, _ length: CGFloat) {
        stroke(Path { $0.move(to: CGPoint(x: x, y: y)); $0.addLine(to: CGPoint(x: x + length, y: y)) }, ink, width: 1.6, opacity: 0.5)
    }

    /// Manual: tap + under the last page. Automatic: write on the last page and a blank one appears.
    private func newPages(_ p: Double) {
        stroke(Path { $0.move(to: CGPoint(x: 120, y: 14)); $0.addLine(to: CGPoint(x: 120, y: 128)) }, edge, width: 1)
        label("MANUAL", at: CGPoint(x: 60, y: 13), color: faint)
        label("AUTOMATIC", at: CGPoint(x: 180, y: 13), color: faint)

        sheet(CGRect(x: 30, y: 26, width: 60, height: 44))
        rule(38, 38, 40)
        rule(38, 46, 34)
        rule(38, 54, 42)
        let plus = 1 - ramp(p, 0.32, 0.36) + ramp(p, 0.94, 1)
        let button = CGPoint(x: 60, y: 90)
        fill(circle(button, 9), page, opacity: plus)
        stroke(circle(button, 9), edge, width: 1, opacity: plus)
        stroke(Path {
            $0.move(to: CGPoint(x: 60, y: 85.5)); $0.addLine(to: CGPoint(x: 60, y: 94.5))
            $0.move(to: CGPoint(x: 55.5, y: 90)); $0.addLine(to: CGPoint(x: 64.5, y: 90))
        }, faint, width: 1.5, opacity: plus)
        taps([button], p, from: 0.22)
        let manual = ramp(p, 0.33, 0.44)
        sheet(CGRect(x: 30, y: 78 + 10 * (1 - manual), width: 60, height: 44), opacity: manual * (1 - ramp(p, 0.90, 0.96)))

        sheet(CGRect(x: 150, y: 26, width: 60, height: 44))
        rule(158, 38, 40)
        rule(158, 46, 30)
        let writing = wave(CGPoint(x: 158, y: 55), humps: 4, width: 11, rise: 2).trimmedPath(from: 0, to: ramp(p, 0.10, 0.32))
        stroke(writing, ink, width: 1.6, opacity: 1 - ramp(p, 0.90, 0.96))
        let automatic = ramp(p, 0.36, 0.47)
        sheet(CGRect(x: 150, y: 78 + 10 * (1 - automatic), width: 60, height: 44), opacity: automatic * (1 - ramp(p, 0.90, 0.96)))
    }

    /// The time and battery fade and the bar slides up into their place.
    private func hideStatusBar(_ p: Double) {
        let screen = Path(roundedRect: CGRect(x: 22, y: 14, width: 196, height: 140), cornerRadius: 12)
        fill(screen, color(Tokens.Colors.sheetPanel))
        stroke(screen, edge, width: 1)
        var clipped = ctx
        clipped.clip(to: screen)
        let hidden = ramp(p, 0.25, 0.36) - ramp(p, 0.74, 0.86)

        var status = clipped
        status.opacity = 1 - hidden
        status.translateBy(x: 0, y: -5 * hidden)
        status.draw(
            Text("9:41").font(.system(size: 8, weight: .semibold)).foregroundStyle(ink),
            at: CGPoint(x: 36, y: 24),
            anchor: .leading
        )
        status.stroke(Path(roundedRect: CGRect(x: 190, y: 21, width: 14, height: 7), cornerRadius: 2), with: .color(ink), lineWidth: 0.9)
        status.fill(Path(roundedRect: CGRect(x: 191.5, y: 22.5, width: 9, height: 4), cornerRadius: 1), with: .color(ink))

        var shifted = clipped
        shifted.translateBy(x: 0, y: -15 * hidden)
        let bar = Painter(ctx: shifted, scheme: scheme)
        bar.fill(Path(CGRect(x: 22, y: 34, width: 196, height: 22)), page)
        bar.stroke(Path { $0.move(to: CGPoint(x: 22, y: 56)); $0.addLine(to: CGPoint(x: 218, y: 56)) }, edge, width: 1)
        bar.stroke(
            Path { $0.move(to: CGPoint(x: 36, y: 41)); $0.addLine(to: CGPoint(x: 32, y: 45)); $0.addLine(to: CGPoint(x: 36, y: 49)) },
            faint,
            width: 1.4
        )
        bar.fill(Path(roundedRect: CGRect(x: 46, y: 40, width: 54, height: 10), cornerRadius: 5), color(Tokens.Colors.subtleFill))
        for x in [186.0, 192, 198] {
            bar.fill(circle(CGPoint(x: x, y: 45), 1.3), faint)
        }
        bar.fill(Path(CGRect(x: 42, y: 66, width: 156, height: 90)), color(Tokens.Colors.libraryBackground))
        bar.rule(54, 80, 80)
        bar.rule(54, 90, 64)
        bar.rule(54, 100, 90)
    }

    /// Changes travel from this iPad to the folder, and from the folder to the iPhone.
    private func sync(_ p: Double) {
        let device = color(Tokens.Colors.icon)
        let tablet = Path(roundedRect: CGRect(x: 26, y: 40, width: 52, height: 70), cornerRadius: 7)
        fill(tablet, page)
        stroke(tablet, device, width: 1.6)
        for (y, length) in [(56.0, 28.0), (64, 36), (72, 22)] {
            stroke(Path { $0.move(to: CGPoint(x: 34, y: y)); $0.addLine(to: CGPoint(x: 34 + length, y: y)) }, edge, width: 1.4)
        }
        let phone = Path(roundedRect: CGRect(x: 174, y: 48, width: 34, height: 58), cornerRadius: 6)
        fill(phone, page)
        stroke(phone, device, width: 1.6)
        stroke(Path { $0.move(to: CGPoint(x: 186, y: 100)); $0.addLine(to: CGPoint(x: 196, y: 100)) }, device, width: 1.4)

        let bump = 1 + 0.06 * pulse(p, 0.38, 0.42, 0.42, 0.48)
        var folder = Path()
        folder.move(to: CGPoint(x: 104, y: 62))
        for point in [(114.0, 62.0), (118, 66), (136, 66), (136, 90), (104, 90)] {
            folder.addLine(to: CGPoint(x: point.0, y: point.1))
        }
        folder.closeSubpath()
        folder = folder.applying(
            CGAffineTransform(translationX: 120, y: 76).scaledBy(x: bump, y: bump).translatedBy(x: -120, y: -76)
        )
        fill(folder, color(Tokens.Colors.dropTarget))
        stroke(folder, accent, width: 1.6)
        label("FOLDER", at: CGPoint(x: 120, y: 102), color: faint)

        fill(circle(CGPoint(x: 83 + 18 * ramp(p, 0.06, 0.38), y: 77), 3), accent, opacity: pulse(p, 0.06, 0.12, 0.38, 0.44))
        fill(circle(CGPoint(x: 143 + 18 * ramp(p, 0.46, 0.78), y: 77), 3), accent, opacity: pulse(p, 0.46, 0.52, 0.78, 0.84))
    }
}
