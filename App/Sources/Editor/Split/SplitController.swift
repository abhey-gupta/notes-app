import InkModel
import Library
import Observation
import SwiftUI

/// Split view's moves (#175): opening a pane beside another, closing one, swapping, the divider under a
/// finger. Each is one spring on ``presence`` or ``fraction`` (``SplitPaneLayout`` turns them into frames),
/// with the canvases that change size holding still under snapshots until it ends
/// (`CanvasHostView.beginLiveResize`). The tabs (``TabsModel``) change at the start; ``closing`` keeps a
/// leaving pane on screen until it's gone.
@MainActor
@Observable
final class SplitController {
    /// A pane on its way out.
    struct Closing {
        let session: NotebookSession
        let notebook: NotebookSummary
        /// The side it leaves from.
        let side: OpenTabs.Pane
    }

    /// How far the split is in, animated.
    var presence: Double
    /// The pane sliding in or out.
    var mover = OpenTabs.Pane.secondary
    /// The divider's place, animated (the tabs keep where it rests).
    var fraction: Double
    private(set) var closing: Closing?
    /// The divider is under a finger.
    private(set) var isDragging = false
    /// The stop it clings to meanwhile.
    private(set) var stop: Double?
    var reduceMotion = false
    @ObservationIgnored private let tabs: TabsModel
    @ObservationIgnored private let sessions: SessionStore

    init(tabs: TabsModel, sessions: SessionStore) {
        self.tabs = tabs
        self.sessions = sessions
        presence = tabs.isSplit ? 1 : 0
        fraction = tabs.splitFraction
    }

    /// The one spring of every split move: no bounce, a little under half a second.
    private var spring: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0)
    }

    var isBusy: Bool {
        closing != nil
    }

    // MARK: Moves

    /// Opens `id` in the other pane: a new split slides in on `side` (a tab dropped on the leading half
    /// lands there), or the other pane switches.
    func open(_ id: NotebookID, beside pane: OpenTabs.Pane, on side: OpenTabs.Pane = .secondary, showing: [NotebookSession]) {
        guard closing == nil else { return }
        if tabs.isSplit {
            return tabs.show(id, in: pane.other)
        }
        hold(showing)
        mover = side
        presence = 0
        fraction = tabs.splitFraction
        if let evicted = tabs.openSplit(id) {
            sessions.close(evicted)
        }
        if side == .primary {
            tabs.swapPanes()
            sessions.swapPanes()
        }
        // The new pane is laid out off screen first, then the spring brings it in.
        DispatchQueue.main.async { [self] in
            withAnimation(spring) {
                presence = 1
            } completion: { [self] in
                mover = .secondary
                release(showing)
            }
        }
    }

    /// `pane` slides away to its edge and the other one takes the editor; `then` runs when it's gone.
    func close(_ pane: OpenTabs.Pane, notebook: NotebookSummary, showing: [NotebookSession], then: @escaping () -> Void = {}) {
        guard tabs.isSplit, closing == nil else { return }
        hold(showing)
        tabs.closeSplit(keeping: pane.other)
        guard let leaving = sessions.closeSplit(keeping: pane.other) else {
            release(showing)
            return then()
        }
        closing = Closing(session: leaving, notebook: notebook, side: pane)
        mover = pane
        withAnimation(spring) {
            presence = 0
        } completion: { [self] in
            closing = nil
            mover = .secondary
            fraction = tabs.splitFraction
            release(showing)
            sessions.retire(leaving)
            then()
        }
    }

    /// The panes trade places, each keeping its size.
    func swap(showing: [NotebookSession]) {
        guard tabs.isSplit, closing == nil else { return }
        hold(showing)
        tabs.swapPanes()
        sessions.swapPanes()
        let flipped = 1 - tabs.splitFraction
        tabs.splitFraction = flipped
        withAnimation(spring) {
            fraction = flipped
        } completion: { [self] in
            release(showing)
        }
    }

    // MARK: Divider

    /// The divider follows a finger at `position` (along the axis of an editor of `size`).
    func drag(to position: CGFloat, in size: CGSize, showing: [NotebookSession]) {
        guard closing == nil else { return }
        if !isDragging {
            hold(showing)
            isDragging = true
        }
        let dragged = SplitGeometry(size: size).drag(to: position)
        stop = dragged.stop
        fraction = dragged.fraction
    }

    /// Let go: it springs to a stop, or the pane dragged into its edge closes (`close`).
    func release(
        at position: CGFloat, velocity: CGFloat, in size: CGSize, showing: [NotebookSession], close: (OpenTabs.Pane) -> Void
    ) {
        guard isDragging else { return }
        isDragging = false
        stop = nil
        switch SplitGeometry(size: size).release(at: position, velocity: velocity) {
        case let .rest(stop):
            settle(at: stop, showing: showing)
        case let .close(pane):
            close(pane)
        }
    }

    /// VoiceOver: a stop at a time.
    func adjust(_ step: Int, showing: [NotebookSession]) {
        let stops = SplitGeometry.stops
        let index = stops.firstIndex { abs($0 - fraction) < 0.01 } ?? 1
        hold(showing)
        settle(at: stops[min(max(index + step, 0), stops.count - 1)], showing: showing)
    }

    /// How far a dragged pane has gone into its edge: it fades as it goes.
    func opacity(of side: OpenTabs.Pane, in size: CGSize) -> Double {
        guard isDragging, let going = SplitGeometry(size: size).closing(fraction), going.pane == side else { return 1 }
        return 1 - 0.5 * going.progress
    }

    // MARK: Private

    private func settle(at stop: Double, showing: [NotebookSession]) {
        tabs.splitFraction = stop
        withAnimation(spring) {
            fraction = stop
        } completion: { [self] in
            release(showing)
        }
    }

    private func hold(_ sessions: [NotebookSession]) {
        for session in sessions {
            session.host.beginLiveResize()
        }
    }

    private func release(_ sessions: [NotebookSession]) {
        for session in sessions {
            session.host.endLiveResize()
        }
    }
}
