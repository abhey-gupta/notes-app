import SwiftUI
import UIKit

/// A HUD row. `read` runs on main at HUD refresh rate (4 Hz) and only while the HUD is visible.
public struct PerfGauge: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let read: @MainActor @Sendable () -> String

    public init(id: String, label: String, read: @escaping @MainActor @Sendable () -> String) {
        self.id = id
        self.label = label
        self.read = read
    }
}

/// Debug HUD: frame time, FPS, hitches + pluggable gauges. DEBUG builds only;
/// in Release every call is a no-op and `.perfHUD()` returns the view unchanged.
/// Toggle with a 3-finger triple-tap, or launch with `-perfHUD YES`.
@MainActor
public enum PerfHUD {
    /// Adds or replaces (by `id`) a gauge, e.g. ink latency p50/p95, resident tiles MB, WAL size.
    public static func register(gauge: PerfGauge) {
        #if DEBUG
            HUDModel.shared.register(gauge)
        #endif
    }

    public static func unregister(id: String) {
        #if DEBUG
            HUDModel.shared.gauges.removeAll { $0.id == id }
        #endif
    }

    public static var isVisible: Bool {
        get {
            #if DEBUG
                HUDModel.shared.isVisible
            #else
                false
            #endif
        }
        set {
            #if DEBUG
                HUDModel.shared.setVisible(newValue)
            #endif
        }
    }

    public static func toggle() {
        isVisible.toggle()
    }
}

public extension View {
    /// Attach once at the scene root. Overlays the debug HUD and installs the 3-finger triple-tap toggle.
    func perfHUD() -> some View {
        #if DEBUG
            modifier(PerfHUDModifier())
        #else
            self
        #endif
    }
}

#if DEBUG

    struct GaugeValue: Equatable {
        let id: String
        let label: String
        let value: String
    }

    @MainActor @Observable
    final class HUDModel: NSObject {
        static let shared = HUDModel()

        private(set) var isVisible = false
        private(set) var frame: FrameStats.Window?
        private(set) var hitches = 0
        private(set) var gaugeValues: [GaugeValue] = []
        @ObservationIgnored var gauges: [PerfGauge] = [
            PerfGauge(id: "launch", label: "launch") {
                Perf.firstFrameMilliseconds.map { String(format: "%.0f ms", $0) } ?? "–"
            },
        ]

        @ObservationIgnored private var stats = FrameStats()
        @ObservationIgnored private var link: CADisplayLink?
        @ObservationIgnored private var lastPublish: CFTimeInterval = 0
        @ObservationIgnored private var didReadDefaults = false

        override private init() {
            super.init()
        }

        func register(_ gauge: PerfGauge) {
            if let i = gauges.firstIndex(where: { $0.id == gauge.id }) {
                gauges[i] = gauge
            } else {
                gauges.append(gauge)
            }
        }

        /// `-perfHUD YES` launch argument shows the HUD at launch.
        func applyLaunchDefault() {
            guard !didReadDefaults else { return }
            didReadDefaults = true
            if UserDefaults.standard.bool(forKey: "perfHUD") {
                setVisible(true)
            }
        }

        func setVisible(_ visible: Bool) {
            guard visible != isVisible else { return }
            isVisible = visible
            if visible {
                stats.reset()
                hitches = 0
                frame = nil
                readGauges()
                let link = CADisplayLink(target: self, selector: #selector(tick))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
                link.add(to: .main, forMode: .common)
                self.link = link
            } else {
                link?.invalidate()
                link = nil
            }
        }

        @objc private func tick(_ link: CADisplayLink) {
            stats.record(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp)
            // Publish at 4 Hz so the HUD itself doesn't cost frames.
            guard link.timestamp - lastPublish >= 0.25 else { return }
            lastPublish = link.timestamp
            if let window = stats.drainWindow(), window != frame {
                frame = window
            }
            if hitches != stats.hitchCount {
                hitches = stats.hitchCount
            }
            readGauges()
        }

        /// Assigns only on change so a steady HUD doesn't re-render.
        private func readGauges() {
            let values = gauges.map { GaugeValue(id: $0.id, label: $0.label, value: $0.read()) }
            if values != gaugeValues {
                gaugeValues = values
            }
        }
    }

    struct PerfHUDModifier: ViewModifier {
        func body(content: Content) -> some View {
            content
                .overlay(alignment: .topLeading) { PerfHUDOverlay() }
                .background(TripleTapInstaller().frame(width: 0, height: 0))
                .onAppear { HUDModel.shared.applyLaunchDefault() }
        }
    }

    struct PerfHUDOverlay: View {
        private let model = HUDModel.shared

        var body: some View {
            if model.isVisible {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 1) {
                    row("frame", model.frame.map { String(format: "%.1f ms", $0.averageMs) } ?? "–")
                    row("max", model.frame.map { String(format: "%.1f ms", $0.maxMs) } ?? "–")
                    row("fps", model.frame.map { String(format: "%.0f", $0.fps) } ?? "–")
                    row("hitches", "\(model.hitches)")
                    ForEach(model.gaugeValues, id: \.id) { gauge in
                        row(gauge.label, gauge.value)
                    }
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
                .padding(.leading, 12)
                .padding(.top, 4)
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("perfHUD")
            }
        }

        private func row(_ label: String, _ value: String) -> some View {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).gridColumnAlignment(.trailing)
            }
        }
    }

    /// Installs a 3-finger triple-tap recognizer on the hosting window. Doesn't cancel or delay touches,
    /// recognizes simultaneously, ignores Pencil.
    struct TripleTapInstaller: UIViewRepresentable {
        func makeUIView(context _: Context) -> InstallerView {
            InstallerView()
        }

        func updateUIView(_: InstallerView, context _: Context) {}

        final class InstallerView: UIView, UIGestureRecognizerDelegate {
            private lazy var recognizer: UITapGestureRecognizer = {
                let tap = UITapGestureRecognizer(target: self, action: #selector(toggle))
                tap.numberOfTouchesRequired = 3
                tap.numberOfTapsRequired = 3
                tap.cancelsTouchesInView = false
                tap.delaysTouchesEnded = false
                tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                tap.delegate = self
                return tap
            }()

            override init(frame: CGRect) {
                super.init(frame: frame)
                isUserInteractionEnabled = false
                isHidden = true
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) {
                fatalError("init(coder:) not supported")
            }

            override func willMove(toWindow newWindow: UIWindow?) {
                super.willMove(toWindow: newWindow)
                recognizer.view?.removeGestureRecognizer(recognizer)
                newWindow?.addGestureRecognizer(recognizer)
            }

            @objc private func toggle() {
                PerfHUD.toggle()
            }

            func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
                true
            }
        }
    }

#endif
