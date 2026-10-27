import DesignSystem
import SwiftUI
import Tools

/// Pen / highlighter size (#168): the value in mm, a wedge slider between − and + (0.1 mm steps), and three
/// saved sizes (tap to use, touch and hold to store the current size).
struct SizeControl<Glyph: View>: View {
    @Binding var size: InkSize
    let range: ClosedRange<Float>
    /// Accessibility identifier prefix ("penSize" → "penSize", "penSizeMinus", "penSizeSaved0"…).
    let id: String
    /// A saved size's glyph for its 0...1 position in ``range``.
    @ViewBuilder let glyph: (CGFloat) -> Glyph
    @State private var stored = [Int](repeating: 0, count: InkSize.savedCount)

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Thickness")
                Spacer(minLength: 0)
                Text(InkSize.label(size.millimetres))
                    .scaledFont(size: 14, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .contentTransition(.numericText(value: Double(size.millimetres)))
                    .animation(.snappy(duration: 0.2), value: size.millimetres)
                    .padding(.horizontal, Tokens.Spacing.xs)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 10) {
                stepButton("minus", "Thinner", id: "\(id)Minus", by: -InkSize.step)
                WedgeSlider(value: $size.millimetres, range: range)
                    .accessibilityLabel("Thickness")
                    .accessibilityValue(InkSize.label(size.millimetres))
                    .accessibilityIdentifier(id)
                stepButton("plus", "Thicker", id: "\(id)Plus", by: InkSize.step)
            }
            HStack(spacing: 8) {
                ForEach(size.saved.indices, id: \.self) { index in
                    savedChip(index)
                }
            }
            .padding(.top, 12)
        }
    }

    private func stepButton(_ symbol: String, _ label: String, id: String, by step: Float) -> some View {
        let target = InkSize.snap(size.millimetres + step, to: range)
        return Button {
            size.millimetres = target
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tokens.Colors.icon)
                .frame(width: 34, height: 34)
                .background(Tokens.Colors.subtleFill, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(PressScaleStyle())
        .buttonRepeatBehavior(.enabled)
        .disabled(target == size.millimetres)
        .opacity(target == size.millimetres ? 0.4 : 1)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
        .sensoryFeedback(.selection, trigger: size.millimetres)
    }

    private func savedChip(_ index: Int) -> some View {
        let value = size.saved[index]
        let selected = value == size.millimetres
        let position = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
        return Button {
            withAnimation(Tokens.Motion.selection) { size.millimetres = value }
        } label: {
            VStack(spacing: 5) {
                glyph(position)
                    .frame(height: 9)
                Text(value.formatted(.number.precision(.fractionLength(1))))
                    .scaledFont(size: 11, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(selected ? Tokens.Colors.textPrimary : Tokens.Colors.chipText)
                    .contentTransition(.numericText(value: Double(value)))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.segmented, style: .continuous)
                    .fill(selected ? Tokens.Colors.field : Tokens.Colors.subtleFill)
                    .shadow(color: .black.opacity(selected ? 0.1 : 0), radius: 1.5, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.segmented, style: .continuous)
                    .strokeBorder(Tokens.Colors.textPrimary.opacity(selected ? 0.85 : 0), lineWidth: 1.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle())
        .keyframeAnimator(initialValue: 1.0, trigger: stored[index]) { chip, scale in
            chip.scaleEffect(scale)
        } keyframes: { _ in
            SpringKeyframe(1.08, duration: 0.14, spring: .snappy)
            SpringKeyframe(1.0, duration: 0.4, spring: .bouncy)
        }
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in store(index) })
        .sensoryFeedback(.success, trigger: stored[index])
        .accessibilityLabel("Saved size \(InkSize.label(value))")
        .accessibilityHint("Touch and hold to save the current size here.")
        .accessibilityAction(named: "Save current size here") { store(index) }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("\(id)Saved\(index)")
    }

    private func store(_ index: Int) {
        withAnimation(.snappy(duration: 0.2)) { size.saved[index] = size.millimetres }
        stored[index] += 1
    }
}

extension InkSize {
    /// "0.5 mm".
    static func label(_ millimetres: Float) -> String {
        "\(millimetres.formatted(.number.precision(.fractionLength(1)))) mm"
    }
}

/// A slider whose track widens left to right like a stroke getting bolder; drag or tap anywhere on it.
/// Snaps to ``InkSize/step``; VoiceOver adjusts one step at a time.
private struct WedgeSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>

    private static let thumb: CGFloat = 26
    private static let height: CGFloat = 34

    @GestureState private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let span = max(proxy.size.width - Self.thumb, 1)
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let x = Self.thumb / 2 + span * fraction
            ZStack(alignment: .leading) {
                Wedge(from: 1, to: 7)
                    .fill(Tokens.Colors.subtleFill)
                Wedge(from: 1, to: 7)
                    .fill(Tokens.Colors.textPrimary.opacity(0.78))
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: x)
                    }
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                    .overlay { Circle().strokeBorder(.black.opacity(0.06), lineWidth: 0.5) }
                    .frame(width: Self.thumb, height: Self.thumb)
                    .scaleEffect(dragging ? 1.12 : 1)
                    .animation(.snappy(duration: 0.18), value: dragging)
                    .offset(x: x - Self.thumb / 2)
            }
            .frame(height: Self.height)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { drag in
                        let f = Float(min(max((drag.location.x - Self.thumb / 2) / span, 0), 1))
                        value = InkSize.snap(range.lowerBound + f * (range.upperBound - range.lowerBound), to: range)
                    }
            )
        }
        .frame(height: Self.height)
        .accessibilityElement()
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = InkSize.snap(value + InkSize.step, to: range)
            case .decrement: value = InkSize.snap(value - InkSize.step, to: range)
            @unknown default: break
            }
        }
    }
}

/// The slider track: a rounded wedge `from` pt tall at the left edge to `to` pt at the right, centred.
private struct Wedge: Shape {
    let from: CGFloat
    let to: CGFloat

    func path(in rect: CGRect) -> Path {
        let (r0, r1) = (from / 2, to / 2)
        let mid = rect.midY
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r0, y: mid - r0))
        path.addLine(to: CGPoint(x: rect.maxX - r1, y: mid - r1))
        path.addArc(
            center: CGPoint(x: rect.maxX - r1, y: mid),
            radius: r1,
            startAngle: .degrees(-90),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + r0, y: mid + r0))
        path.addArc(
            center: CGPoint(x: rect.minX + r0, y: mid),
            radius: r0,
            startAngle: .degrees(90),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
