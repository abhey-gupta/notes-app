import Darwin
import PencilKit
import UIKit

/// Screen 1: stock `PKCanvasView`. Latency is measured externally (240 fps video); PencilKit exposes
/// no present timestamps.
final class PencilKitScreen: UIViewController, SpikeScreen {
    private let canvas = PKCanvasView()

    override func viewDidLoad() {
        super.viewDidLoad()
        canvas.frame = view.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.backgroundColor = .white
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawingPolicy = .default
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        view.addSubview(canvas)
    }

    func toolbarItems() -> [UIView] {
        let note = spikeLabel()
        note.text = "Stock PKCanvasView · .pen 3 pt · measure with 240 fps video"
        return [note, UIView(), spikeButton("Clear") { [weak self] in self?.canvas.drawing = PKDrawing() }]
    }
}

/// Screen 3: 100 A4 pages stacked in one tall `PKCanvasView` with one `PKDrawing`, optionally filled
/// with synthetic handwriting, for memory and scroll-smoothness observation.
final class StackedPagesScreen: UIViewController, SpikeScreen {
    nonisolated static let pageCount = 100
    nonisolated static let gap: CGFloat = 24

    private let canvas = PKCanvasView()
    private let memory = spikeLabel()
    private var timer: Timer?
    private var pageHeight: CGFloat = 0
    private var fillTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.93, green: 0.92, blue: 0.89, alpha: 1)
        canvas.frame = view.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawingPolicy = .pencilOnly
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        canvas.alwaysBounceVertical = true
        view.addSubview(canvas)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = canvas.bounds.width
        guard width > 0, abs(width * 842 / 595 - pageHeight) > 0.5 else { return }
        pageHeight = width * 842 / 595
        canvas.contentSize = CGSize(width: width, height: CGFloat(Self.pageCount) * (pageHeight + Self.gap))
        for v in canvas.subviews where v.tag == 595 {
            v.removeFromSuperview()
        }
        for i in 0 ..< Self.pageCount {
            let page = UIView(frame: CGRect(x: 0, y: CGFloat(i) * (pageHeight + Self.gap), width: width, height: pageHeight))
            page.backgroundColor = .white
            page.tag = 595
            page.isUserInteractionEnabled = false
            canvas.insertSubview(page, at: 0)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMemory() }
        }
        updateMemory()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
        fillTask?.cancel()
    }

    func toolbarItems() -> [UIView] {
        [
            memory,
            UIView(),
            spikeButton("Empty") { [weak self] in self?.fill(strokesPerPage: 0) },
            spikeButton("Fill 40/page") { [weak self] in self?.fill(strokesPerPage: 40) },
            spikeButton("Fill 400/page") { [weak self] in self?.fill(strokesPerPage: 400) },
        ]
    }

    private func fill(strokesPerPage: Int) {
        fillTask?.cancel()
        let width = canvas.bounds.width
        let pageHeight = pageHeight
        memory.text = "building \(strokesPerPage * Self.pageCount) strokes…"
        let start = CACurrentMediaTime()
        fillTask = Task { [weak self] in
            let drawing = await Task.detached(priority: .userInitiated) {
                Self.syntheticDrawing(strokesPerPage: strokesPerPage, width: width, pageHeight: pageHeight)
            }.value
            guard let self, !Task.isCancelled else { return }
            let built = CACurrentMediaTime()
            canvas.drawing = drawing
            let assigned = CACurrentMediaTime()
            fillNote = String(
                format: "%d strokes · build %.0f ms · assign %.0f ms",
                drawing.strokes.count, (built - start) * 1000, (assigned - built) * 1000
            )
            updateMemory()
        }
    }

    private var fillNote = "empty"

    private func updateMemory() {
        memory.text = String(format: "footprint %.0f MB\n%@", Double(Self.footprint()) / 1_048_576, fillNote)
    }

    /// ~60 samples per stroke of jittery handwriting-ish curves, laid out in lines on each page.
    nonisolated static func syntheticDrawing(strokesPerPage: Int, width: CGFloat, pageHeight: CGFloat) -> PKDrawing {
        var rng = SystemRandomNumberGenerator()
        let ink = PKInk(.pen, color: .black)
        var strokes: [PKStroke] = []
        strokes.reserveCapacity(strokesPerPage * pageCount)
        let scale = width / 595
        for page in 0 ..< pageCount {
            let top = CGFloat(page) * (pageHeight + gap)
            for i in 0 ..< strokesPerPage {
                let line = i / 20
                let x0 = (40 + CGFloat(i % 20) * 26) * scale
                let y0 = top + (60 + CGFloat(line % 30) * 24) * scale
                var points: [PKStrokePoint] = []
                var heading = Double.random(in: 0 ..< 2 * .pi, using: &rng)
                var p = CGPoint(x: x0, y: y0)
                for k in 0 ..< 60 {
                    points.append(PKStrokePoint(
                        location: p, timeOffset: Double(k) / 240, size: CGSize(width: 2.5, height: 2.5),
                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
                    ))
                    heading += Double.random(in: -0.6 ... 0.6, using: &rng)
                    p.x += CGFloat(cos(heading)) * 0.6 * scale
                    p.y += CGFloat(sin(heading)) * 0.6 * scale
                }
                strokes.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date())))
            }
        }
        return PKDrawing(strokes: strokes)
    }

    /// `phys_footprint`: what Xcode's memory gauge and jetsam use.
    nonisolated static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
