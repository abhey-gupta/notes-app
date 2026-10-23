import InkGeometry
import InkModel
import Metal
import os
import Perf
import QuartzCore
import UIKit

/// Screen 2: minimal Metal ink. Draws on every touch event (not the display link), coalesced samples
/// plus a predicted tail that is discarded next event, 2 drawables, 120 Hz. Measures
/// `UITouch.timestamp` (newest coalesced touch in the frame) → `MTLDrawable.presentedTime`.
final class MetalScreen: UIViewController, SpikeScreen {
    private let inkView = MetalInkView()
    private let stats = spikeLabel()
    private let gesture = UISegmentedControl(items: ["Straight lines", "Fast scribbles"])
    private var timer: Timer?

    override func loadView() {
        view = inkView
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if UserDefaults.standard.bool(forKey: "demoStroke") {
            inkView.addDemoStroke()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        PerfHUD.register(gauge: PerfGauge(id: "ink", label: "ink p50/p95") { [weak inkView] in
            inkView.map { MetalScreen.format($0.recorder.current) } ?? "–"
        })
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
        PerfHUD.unregister(id: "ink")
    }

    func toolbarItems() -> [UIView] {
        gesture.selectedSegmentIndex = 0
        gesture.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            inkView.recorder.bucket = gesture.selectedSegmentIndex
        }, for: .valueChanged)
        return [
            gesture,
            stats,
            UIView(),
            spikeButton("Reset stats") { [weak self] in self?.inkView.recorder.reset() },
            spikeButton("Copy results") { [weak self] in
                guard let self else { return }
                UIPasteboard.general.string = inkView.recorder.report()
            },
            spikeButton("Clear ink") { [weak self] in self?.inkView.clear() },
        ]
    }

    private func refresh() {
        let r = inkView.recorder
        stats.text = "lines  \(Self.format(r.buckets[0]))\nscribbles  \(Self.format(r.buckets[1]))"
    }

    static func format(_ s: LatencyStats) -> String {
        guard let p50 = s.p50, let p95 = s.p95 else { return "p50 – / p95 –  (n 0)" }
        return String(format: "p50 %.1f / p95 %.1f ms  (n %d)", p50 * 1000, p95 * 1000, s.count)
    }
}

/// Touch timestamp → presented time, split into the two gesture buckets of the results table.
@MainActor
final class LatencyRecorder {
    var buckets = [LatencyStats(capacity: 5000), LatencyStats(capacity: 5000)]
    var bucket = 0
    var dropped = 0
    private let log = Logger(subsystem: "com.abhey.notespace.spike", category: "latency")

    var current: LatencyStats {
        buckets[bucket]
    }

    func record(_ seconds: Double) {
        guard seconds > 0, seconds < 1 else {
            dropped += 1
            return
        }
        buckets[bucket].record(seconds)
    }

    func reset() {
        buckets[bucket].reset()
        dropped = 0
    }

    func report() -> String {
        let names = ["straight lines", "fast scribbles"]
        var lines = ["Metal touch.timestamp → presentedTime (\(UIDevice.current.model), iPadOS \(UIDevice.current.systemVersion))"]
        for (name, s) in zip(names, buckets) {
            lines.append("\(name): \(MetalScreen.format(s))")
        }
        lines.append("dropped/unpresented: \(dropped)")
        let text = lines.joined(separator: "\n")
        log.info("\(text, privacy: .public)")
        return text
    }
}

final class MetalInkView: UIView {
    override static var layerClass: AnyClass {
        CAMetalLayer.self
    }

    let recorder = LatencyRecorder()

    private var metalLayer: CAMetalLayer {
        // swiftlint:disable:next force_cast
        layer as! CAMetalLayer
    }

    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var displayLink: CADisplayLink?

    /// Committed strokes' vertices, one strip per stroke.
    private var committed: [StrokeVertex] = []
    private var strips: [Range<Int>] = []
    private var committedBuffer: MTLBuffer?
    /// Live stroke: coalesced samples (kept) and predicted samples (replaced every event).
    private var live: [Sample] = []
    private var predicted: [Sample] = []
    private var liveStart: TimeInterval = 0
    private var liveTouch: UITouch?

    private let profile = PenProfile.fountain
    private let width: Float = 3
    private let color = SIMD4<Float>(0.118, 0.129, 0.161, 1) // ink.primary

    override init(frame: CGRect) {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        super.init(frame: frame)
        backgroundColor = .white
        isMultipleTouchEnabled = false
        let layer = metalLayer
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 2
        layer.isOpaque = true
        layer.presentsWithTransaction = false
        if let device, let library = try? device.makeLibrary(source: inkShaderSource, options: nil) {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "ink_vertex")
            desc.fragmentFunction = library.makeFunction(name: "ink_fragment")
            let attachment = desc.colorAttachments[0]
            attachment?.pixelFormat = .bgra8Unorm
            attachment?.isBlendingEnabled = true
            attachment?.sourceRGBBlendFactor = .one
            attachment?.sourceAlphaBlendFactor = .one
            attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        contentScaleFactor = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        render(touchTimestamp: nil)
    }

    /// `-demoStroke YES`: commits a synthetic wave so rendering can be checked without a Pencil.
    func addDemoStroke() {
        liveStart = 0
        live = (0 ... 200).map { i in
            let x = Float(80 + i * 4)
            return Sample(x: x, y: 300 + 60 * sin(x / 50), force: 0.2 + 0.8 * Float(i) / 200, t: Float(i) / 240)
        }
        commitLive()
    }

    func clear() {
        committed = []
        strips = []
        committedBuffer = nil
        render(touchTimestamp: nil)
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard liveTouch == nil, let touch = touches.first else { return }
        liveTouch = touch
        live = []
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        liveStart = coalesced.first?.timestamp ?? touch.timestamp
        startHighRate()
        ingest(touch, event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = liveTouch, touches.contains(touch) else { return }
        ingest(touch, event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = liveTouch, touches.contains(touch) else { return }
        ingest(touch, event, predict: false)
        commitLive()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with _: UIEvent?) {
        guard let touch = liveTouch, touches.contains(touch) else { return }
        liveTouch = nil
        live = []
        predicted = []
        render(touchTimestamp: nil)
        stopHighRate()
    }

    /// Appends coalesced touches, replaces the predicted tail, and draws immediately.
    private func ingest(_ touch: UITouch, _ event: UIEvent?, predict: Bool = true) {
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        for t in coalesced {
            live.append(sample(t))
        }
        predicted = predict ? (event?.predictedTouches(for: touch) ?? []).map(sample) : []
        render(touchTimestamp: coalesced.last?.timestamp ?? touch.timestamp)
    }

    private func sample(_ t: UITouch) -> Sample {
        let p = t.preciseLocation(in: self)
        let force: Float = t.maximumPossibleForce > 0 ? Float(min(t.force / t.maximumPossibleForce, 1)) : Sample.neutralForce
        return Sample(
            x: Float(p.x), y: Float(p.y), force: force, altitude: Float(t.altitudeAngle),
            azimuth: Float(t.azimuthAngle(in: self)), t: Float(t.timestamp - liveStart)
        )
    }

    private func commitLive() {
        liveTouch = nil
        predicted = []
        let centerline = Centerline(samples: live, width: width, profile: profile)
        let start = committed.count
        StrokeTessellator.appendVertices(for: centerline, fringe: 1, to: &committed)
        if committed.count > start {
            strips.append(start ..< committed.count)
        }
        committedBuffer = committed.isEmpty ? nil : device?.makeBuffer(
            bytes: committed, length: committed.count * MemoryLayout<StrokeVertex>.stride, options: .storageModeShared
        )
        live = []
        render(touchTimestamp: nil)
        stopHighRate()
    }

    // MARK: 120 Hz

    /// A display link only to request 120 Hz while ink is live; drawing happens in touch handlers.
    private func startHighRate() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkTarget(), selector: #selector(DisplayLinkTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopHighRate() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: Render

    private func render(touchTimestamp: TimeInterval?) {
        guard let pipeline, let queue, bounds.width > 0, let drawable = metalLayer.nextDrawable(),
              let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)
        var uniforms = Uniforms(viewSize: SIMD2(Float(bounds.width), Float(bounds.height)), ppp: Float(contentScaleFactor), color: color)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        if let committedBuffer {
            encoder.setVertexBuffer(committedBuffer, offset: 0, index: 0)
            for strip in strips {
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: strip.lowerBound, vertexCount: strip.count)
            }
        }
        let display = live + predicted
        if !display.isEmpty {
            let mesh = StrokeTessellator.mesh(for: Centerline(samples: display, width: width, profile: profile))
            if !mesh.vertices.isEmpty, let buffer = device?.makeBuffer(
                bytes: mesh.vertices, length: mesh.vertices.count * MemoryLayout<StrokeVertex>.stride, options: .storageModeShared
            ) {
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: mesh.vertices.count)
            }
        }
        encoder.endEncoding()
        if let touchTimestamp {
            #if targetEnvironment(simulator)
                // No presentedTime on the simulator (and its numbers would be meaningless anyway).
                _ = touchTimestamp
            #else
                // presentedTime and UITouch.timestamp are both mach-absolute-time seconds (CACurrentMediaTime base).
                let recorder = recorder
                drawable.addPresentedHandler { presented in
                    let presentedTime = presented.presentedTime
                    Task { @MainActor in
                        recorder.record(presentedTime > 0 ? presentedTime - touchTimestamp : -1)
                    }
                }
            #endif
        }
        commands.present(drawable)
        commands.commit()
    }
}

private struct Uniforms {
    var viewSize: SIMD2<Float>
    var ppp: Float
    var pad: Float = 0
    var color: SIMD4<Float>
}

private final class DisplayLinkTarget: NSObject {
    @objc func tick() {}
}
