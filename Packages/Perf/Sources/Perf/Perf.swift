import Darwin
import Foundation
import MetricKit
import os
import Synchronization

/// App-level perf hooks: launch signpost and MetricKit. See ARCHITECTURE.md §11–§12.
public enum Perf {
    private struct LaunchState {
        var interval: SignpostInterval?
        var started = false
        var firstFrameMs: Double?
    }

    private static let launch = Mutex(LaunchState())
    private static let metricsStarted = Atomic(false)
    private static let log = Logger(subsystem: Signpost.subsystem, category: "launch")

    /// Call first thing in `App.init`. Begins `launch.firstFrame`. Nanoseconds when not recording.
    public static func markLaunchStart() {
        launch.withLock { state in
            guard !state.started else { return }
            state.started = true
            state.interval = Signpost.launchFirstFrame.begin()
        }
    }

    /// Call from the first `onAppear` of the root (library) view. Idempotent; only the first call counts.
    public static func markFirstFrame() {
        let ended: Bool = launch.withLock { state in
            guard state.firstFrameMs == nil else { return false }
            state.interval?.end()
            state.interval = nil
            state.firstFrameMs = millisecondsSinceProcessStart()
            return true
        }
        guard ended else { return }
        #if DEBUG
            if let ms = firstFrameMilliseconds {
                log.info("launch.firstFrame \(ms, format: .fixed(precision: 1), privacy: .public) ms since exec")
            }
        #endif
    }

    /// Process exec → `markFirstFrame()`, in ms. Nil until the first frame is marked.
    public static var firstFrameMilliseconds: Double? {
        launch.withLock { $0.firstFrameMs }
    }

    /// Subscribes to MetricKit off the main thread. Payloads land in `Library/Perf/*.json`. Idempotent.
    public static func startMetricKit(writer: PayloadWriter = PayloadWriter()) {
        guard metricsStarted.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else { return }
        Task.detached(priority: .utility) {
            MXMetricManager.shared.add(MetricsSubscriber.make(writer: writer))
        }
    }

    private static func millisecondsSinceProcessStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let startSeconds = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return (Date().timeIntervalSince1970 - startSeconds) * 1000
    }
}

extension MetricsSubscriber {
    /// MetricKit holds subscribers weakly; keep ours alive for the process lifetime.
    private static let retained = Mutex<MetricsSubscriber?>(nil)

    static func make(writer: PayloadWriter) -> MetricsSubscriber {
        retained.withLock { current in
            if let current {
                return current
            }
            let subscriber = MetricsSubscriber(writer: writer)
            current = subscriber
            return subscriber
        }
    }
}
