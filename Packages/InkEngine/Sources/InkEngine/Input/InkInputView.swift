import QuartzCore
import UIKit

/// Receives ``InkInputView`` output on the main actor, inside the touch event that produced it
/// (draw immediately for lowest latency).
@MainActor
public protocol InkInputViewDelegate: AnyObject {
    /// Page under `point` (view space), or `nil` to ignore a drawing touch there.
    func inkInputView(_ view: InkInputView, targetAt point: CGPoint) -> InkInputTarget?
    /// A tracker event.
    func inkInputView(_ view: InkInputView, didProduce event: InkInputTracker.Event)
}

/// UIKit glue for ``InkInputTracker``: forwards touches (with coalesced and predicted touches and
/// estimated-property updates) as ``TouchRecord``s and reports events to its delegate.
///
/// Transparent, multi-touch (so palms are seen by the policy). Finger touches that navigate still
/// reach the host scroll view's gesture recognizers.
@MainActor
public final class InkInputView: UIView {
    /// Event sink.
    public weak var delegate: (any InkInputViewDelegate)?
    /// Policy and live stroke.
    public private(set) var tracker = InkInputTracker()
    private var flushScheduled = false

    override public init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    /// "Draw with finger" setting.
    public var allowsFingerDrawing: Bool {
        get { tracker.policy.allowsFingerDrawing }
        set { tracker.policy.allowsFingerDrawing = newValue }
    }

    /// Cancels the live stroke (e.g. tool switched mid-gesture).
    public func cancelActiveStroke() {
        guard let stroke = tracker.active else { return }
        emit(tracker.cancelled(TouchRecord(id: stroke.touch, location: .zero, timestamp: CACurrentMediaTime())))
    }

    // MARK: UIResponder

    override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let record = TouchRecord(touch, in: self)
            let hit = delegate?.inkInputView(self, targetAt: record.location)
            emit(tracker.began(record, coalesced: coalesced(touch, event), predicted: predicted(touch, event)) { _ in hit })
        }
    }

    override public func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            emit(tracker.moved(TouchRecord(touch, in: self), coalesced: coalesced(touch, event), predicted: predicted(touch, event)))
        }
    }

    override public func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            emit(tracker.ended(TouchRecord(touch, in: self), coalesced: coalesced(touch, event)))
        }
        scheduleFlushIfNeeded()
    }

    override public func touchesCancelled(_ touches: Set<UITouch>, with _: UIEvent?) {
        for touch in touches {
            emit(tracker.cancelled(TouchRecord(touch, in: self)))
        }
    }

    override public func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        for touch in touches {
            emit(tracker.estimatedPropertiesUpdated(TouchRecord(touch, in: self)))
        }
    }

    // MARK: Private

    private func coalesced(_ touch: UITouch, _ event: UIEvent?) -> [TouchRecord] {
        let id = TouchID(touch)
        return (event?.coalescedTouches(for: touch) ?? []).map { TouchRecord($0, id: id, in: self) }
    }

    private func predicted(_ touch: UITouch, _ event: UIEvent?) -> [TouchRecord] {
        let id = TouchID(touch)
        return (event?.predictedTouches(for: touch) ?? []).map { TouchRecord($0, id: id, in: self) }
    }

    private func emit(_ events: [InkInputTracker.Event]) {
        for event in events {
            delegate?.inkInputView(self, didProduce: event)
        }
    }

    private func scheduleFlushIfNeeded() {
        guard tracker.hasFinishingStrokes, !flushScheduled else { return }
        flushScheduled = true
        let delay = tracker.estimateDeadline
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            flushScheduled = false
            emit(tracker.flush(now: CACurrentMediaTime()))
            scheduleFlushIfNeeded()
        }
    }
}
