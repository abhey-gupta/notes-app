import DesignSystem
import Library
import SwiftUI

/// The line between split panes (#175) and its grabber. A finger drags it: the panes follow live,
/// clinging to ⅓ · ½ · ⅔ with a selection tick; on release it springs to the stop the drag was heading
/// for, or, dragged into an edge, the pane there closes. Double-tap swaps the panes. VoiceOver adjusts it
/// stop by stop.
struct SplitDivider: View {
    let axis: SplitGeometry.Axis
    /// The stop the divider clings to while dragged, if any (the grabber firms up on it).
    let stop: Double?
    let isDragging: Bool
    /// Where it rests, for VoiceOver.
    let fraction: Double
    /// Finger position along the split axis, in the editor's ``EditorScreen/space``.
    let onChanged: (CGFloat) -> Void
    let onEnded: (_ position: CGFloat, _ velocity: CGFloat) -> Void
    let onSwap: () -> Void
    let onAdjust: (_ step: Int) -> Void

    /// Touch area across the line.
    static let touchWidth: CGFloat = 20

    var body: some View {
        let horizontal = axis == .horizontal
        ZStack {
            Rectangle()
                .fill(Tokens.Colors.separator.color)
                .frame(width: horizontal ? SplitGeometry.dividerThickness : nil, height: horizontal ? nil : SplitGeometry.dividerThickness)
            Capsule()
                .fill(isDragging ? Tokens.Colors.textPrimary.color : Tokens.Colors.textTertiary.color.opacity(0.6))
                .frame(width: horizontal ? grabber.thickness : grabber.length, height: horizontal ? grabber.length : grabber.thickness)
                .animation(.snappy(duration: 0.18), value: isDragging)
                .animation(.snappy(duration: 0.18), value: stop)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .gesture(drag)
        .onTapGesture(count: 2, perform: onSwap)
        .sensoryFeedback(.selection, trigger: stop) { _, new in new != nil && isDragging }
        .accessibilityElement()
        .accessibilityLabel("Split divider")
        .accessibilityValue(Self.describe(fraction))
        .accessibilityHint("Double-tap to swap sides")
        .accessibilityAdjustableAction { direction in
            onAdjust(direction == .increment ? 1 : -1)
        }
        .accessibilityAction(named: "Swap sides", onSwap)
        .accessibilityIdentifier("splitDivider")
    }

    private var grabber: (length: CGFloat, thickness: CGFloat) {
        isDragging ? (64, 8) : (46, 6)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(EditorScreen.space))
            .onChanged { value in
                onChanged(axis == .horizontal ? value.location.x : value.location.y)
            }
            .onEnded { value in
                let horizontal = axis == .horizontal
                onEnded(horizontal ? value.location.x : value.location.y, horizontal ? value.velocity.width : value.velocity.height)
            }
    }

    static func describe(_ fraction: Double) -> String {
        switch fraction {
        case ..<0.4: "One third"
        case 0.6...: "Two thirds"
        default: "Half"
        }
    }
}
