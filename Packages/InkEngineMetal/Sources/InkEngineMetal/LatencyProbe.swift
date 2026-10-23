import Foundation
import Metal
import Perf
import QuartzCore

/// Pen-to-pixel latency: newest coalesced `UITouch.timestamp` in a frame → that frame's
/// `MTLDrawable.presentedTime` (ARCHITECTURE.md §3.3). Both are `CACurrentMediaTime` seconds.
///
/// Excludes digitizer time before the timestamp and scan-out after presentation; the spike's video
/// method (#16) measures end to end. Frames never presented (`presentedTime == 0`, e.g. dropped; every
/// frame on the simulator, whose SDK has no presented handler) are counted as ``dropped``, not recorded.
@MainActor
public final class LatencyProbe {
    /// Rolling seconds, last 240 presented ink frames (~2 s of scribbling at 120 Hz).
    public private(set) var stats = LatencyStats(capacity: 240)
    /// Ink frames that were never presented.
    public private(set) var dropped = 0

    /// PerfHUD gauge ID.
    public static let gaugeID = "ink.latency"

    init() {}

    /// Records the latency of `drawable` for a frame showing input up to `touchTimestamp`.
    func track(_ drawable: any MTLDrawable, touchTimestamp: TimeInterval) {
        #if targetEnvironment(simulator)
            // The simulator SDK has no presented handler; its latency would be meaningless anyway.
            _ = drawable
            dropped += 1
        #else
            drawable.addPresentedHandler { [weak self] presented in
                let presentedTime = presented.presentedTime
                Task { @MainActor in
                    self?.record(presentedTime: presentedTime, touchTimestamp: touchTimestamp)
                }
            }
        #endif
    }

    func record(presentedTime: CFTimeInterval, touchTimestamp: TimeInterval) {
        let latency = presentedTime - touchTimestamp
        guard presentedTime > 0, latency > 0, latency < 1 else {
            dropped += 1
            return
        }
        stats.record(latency)
    }

    /// Clears the stats.
    public func reset() {
        stats.reset()
        dropped = 0
    }

    /// `p50 x.x / p95 y.y ms (n)` for the HUD.
    public var summary: String {
        guard let p50 = stats.p50, let p95 = stats.p95 else { return "– (n 0)" }
        return String(format: "p50 %.1f / p95 %.1f ms (n %d)", p50 * 1000, p95 * 1000, stats.count)
    }

    /// Shows ``summary`` in the debug HUD (no-op in Release).
    func registerGauge() {
        PerfHUD.register(gauge: PerfGauge(id: Self.gaugeID, label: "ink p50/p95") { [weak self] in
            self?.summary ?? "–"
        })
    }
}
