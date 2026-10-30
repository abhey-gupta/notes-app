import SwiftUI
import UIKit

/// Long-press-then-drag on a page cell, in the grid's coordinate space (#197).
///
/// UIKit-backed: a SwiftUI `LongPressGesture` sequenced before a zero-distance `DragGesture` claims the
/// touch from the start, so a swipe that began on a page never scrolled the grid. A long press fails
/// once the finger travels 10 pt before 0.3 s, which leaves the swipe to the scroll view.
struct PageLift: UIGestureRecognizerRepresentable {
    enum Phase {
        case lifted
        /// Translation since the lift, finger location.
        case moved(CGSize, CGPoint)
        case dropped(CGPoint)
        case cancelled
    }

    var isEnabled = true
    var onPhase: (Phase) -> Void

    func makeCoordinator(converter _: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context _: Context) -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer()
        press.minimumPressDuration = 0.3
        return press
    }

    func updateUIGestureRecognizer(_ press: UILongPressGestureRecognizer, context _: Context) {
        press.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ press: UILongPressGestureRecognizer, context: Context) {
        let location = context.converter.location(in: .named(PagesOverview.gridSpace))
        switch press.state {
        case .began:
            context.coordinator.start = location
            onPhase(.lifted)
        case .changed:
            let start = context.coordinator.start
            onPhase(.moved(CGSize(width: location.x - start.x, height: location.y - start.y), location))
        case .ended:
            onPhase(.dropped(location))
        case .cancelled, .failed:
            onPhase(.cancelled)
        default:
            break
        }
    }

    final class Coordinator {
        var start = CGPoint.zero
    }
}
