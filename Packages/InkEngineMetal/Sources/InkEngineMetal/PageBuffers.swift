import CoreGraphics
import InkEngine
import InkGeometry
import InkModel
import Metal

/// GPU buffers for one page's committed strokes, built off main from a snapshot and a theme.
///
/// All strokes share one vertex buffer; a parallel buffer holds each vertex's z-index (its style).
/// Ink is one indexed triangle-strip draw (primitive restart between strokes, in z-order).
/// Highlighters are grouped so strokes in a group never overlap; each group is one coverage pass.
/// Immutable after creation (Metal buffers are written once, before the value leaves the builder).
final class PageBuffers {
    /// Primitive-restart index for `.uint32` strips.
    static let restart = UInt32.max

    /// The snapshot and theme these buffers show.
    let snapshot: PageSnapshot
    let theme: PaperTheme
    let fringe: Float
    let vertices: (any MTLBuffer)?
    let strokeIndices: (any MTLBuffer)?
    let indices: (any MTLBuffer)?
    let styles: (any MTLBuffer)?
    /// Index range of the ink strips in ``indices``.
    let ink: Range<Int>
    /// Index ranges of the highlighter groups in ``indices``.
    let highlightGroups: [Range<Int>]
    let vertexCount: Int
    /// IDs of the strokes drawn.
    let strokeIDs: Set<StrokeID>

    init(
        snapshot: PageSnapshot,
        theme: PaperTheme,
        fringe: Float,
        device: any MTLDevice,
        assembly: Assembly
    ) {
        self.snapshot = snapshot
        self.theme = theme
        self.fringe = fringe
        vertices = Self.buffer(device, assembly.vertices, "page.vertices")
        strokeIndices = Self.buffer(device, assembly.strokeIndices, "page.strokeIndices")
        indices = Self.buffer(device, assembly.indices, "page.indices")
        styles = Self.buffer(device, assembly.styles, "page.styles")
        ink = assembly.ink
        highlightGroups = assembly.highlightGroups
        vertexCount = assembly.vertices.count
        strokeIDs = Set(snapshot.strokes.map(\.id))
    }

    /// GPU bytes held.
    var byteCount: Int {
        [vertices, strokeIndices, indices, styles].reduce(0) { $0 + ($1?.length ?? 0) }
    }

    private static func buffer(_ device: any MTLDevice, _ array: [some BitwiseCopyable], _ label: String) -> (any MTLBuffer)? {
        guard !array.isEmpty else { return nil }
        let buffer = array.withUnsafeBytes { raw in
            raw.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: raw.count, options: .storageModeShared) }
        }
        buffer?.label = label
        return buffer
    }

    /// CPU-side arrays, assembled from cached geometry.
    struct Assembly {
        var vertices: [StrokeVertex] = []
        var strokeIndices: [UInt32] = []
        var indices: [UInt32] = []
        var styles: [StrokeStyle] = []
        var ink: Range<Int> = 0 ..< 0
        var highlightGroups: [Range<Int>] = []
    }
}

/// What a page build needs (all `Sendable`).
struct PageBuildInput: Sendable {
    let snapshot: PageSnapshot
    let theme: PaperTheme
    let palette: any InkPalette
    let fringe: Float
    /// Cached geometry for (some of) the snapshot's strokes.
    let cached: [StrokeID: StrokeGeometry]
}

/// A finished build: buffers plus the geometry used (for the cache).
struct PageBuild {
    let buffers: PageBuffers
    let geometry: [StrokeID: StrokeGeometry]
    /// Strokes tessellated by this build (cache misses).
    let tessellated: Int
}

enum PageBuilder {
    /// Default AA fringe (pt) for cached geometry: ≥ 1 device pixel down to 1 px/pt (zoom 0.5 on 2×).
    static let fringe: Float = 1

    /// Tessellates cache misses and assembles GPU buffers, off the caller's actor.
    @concurrent
    static func build(_ input: PageBuildInput, device: any MTLDevice) async -> sending PageBuild {
        buildNow(input, device: device)
    }

    /// Synchronous body of ``build(_:device:)`` (offscreen renders call it from their own task).
    static func buildNow(_ input: PageBuildInput, device: any MTLDevice) -> PageBuild {
        let strokes = input.snapshot.strokes
        var geometry: [StrokeID: StrokeGeometry] = [:]
        geometry.reserveCapacity(strokes.count)
        var tessellated = 0
        for stroke in strokes {
            if let hit = input.cached[stroke.id], hit.matches(stroke, fringe: input.fringe) {
                geometry[stroke.id] = hit
            } else {
                geometry[stroke.id] = StrokeGeometry(stroke, fringe: input.fringe)
                tessellated += 1
            }
        }
        let assembly = assemble(strokes, geometry, theme: input.theme, palette: input.palette)
        let buffers = PageBuffers(snapshot: input.snapshot, theme: input.theme, fringe: input.fringe, device: device, assembly: assembly)
        return PageBuild(buffers: buffers, geometry: geometry, tessellated: tessellated)
    }

    /// Concatenates the strips, writes per-vertex z-indices and per-stroke styles, and lays out the
    /// index buffer: ink strips in z-order, then highlighter groups.
    private static func assemble(
        _ strokes: [Stroke],
        _ geometry: [StrokeID: StrokeGeometry],
        theme: PaperTheme,
        palette: any InkPalette
    ) -> PageBuffers.Assembly {
        let total = geometry.values.reduce(0) { $0 + $1.vertices.count }
        var a = PageBuffers.Assembly()
        a.vertices.reserveCapacity(total)
        a.strokeIndices.reserveCapacity(total)
        a.indices.reserveCapacity(total + strokes.count)
        a.styles.reserveCapacity(strokes.count)
        var bases: [Int] = []
        bases.reserveCapacity(strokes.count)
        for (z, stroke) in strokes.enumerated() {
            let g = geometry[stroke.id]?.vertices ?? []
            bases.append(a.vertices.count)
            a.vertices.append(contentsOf: g)
            a.strokeIndices.append(contentsOf: repeatElement(UInt32(z), count: g.count))
            a.styles.append(StrokeStyle(
                kind: stroke.tool,
                ink: palette.ink(stroke.color, on: theme),
                ends: geometry[stroke.id]?.ends ?? .none
            ))
        }

        func appendStrip(_ z: Int) {
            let count = geometry[strokes[z].id]?.vertices.count ?? 0
            guard count > 2 else { return }
            let base = UInt32(bases[z])
            a.indices.append(contentsOf: base ..< base + UInt32(count))
            a.indices.append(PageBuffers.restart)
        }

        // Ink in z-order.
        let inkStart = a.indices.count
        for z in strokes.indices where !PenProfile(strokes[z].tool).drawsBeneathInk {
            appendStrip(z)
        }
        a.ink = inkStart ..< a.indices.count

        // Highlighters: multiply/screen commute, so groups only need disjoint bounds, not z-order.
        for group in highlightGroups(strokes, geometry) {
            let start = a.indices.count
            group.forEach(appendStrip)
            a.highlightGroups.append(start ..< a.indices.count)
        }
        return a
    }

    /// Greedy first-fit grouping of highlighter z-indices into sets with pairwise disjoint bounds.
    static func highlightGroups(_ strokes: [Stroke], _ geometry: [StrokeID: StrokeGeometry]) -> [[Int]] {
        var groups: [(members: [Int], bounds: [CGRect])] = []
        for (z, stroke) in strokes.enumerated() where PenProfile(stroke.tool).drawsBeneathInk {
            guard let box = geometry[stroke.id]?.bounds, !box.isNull else { continue }
            if let g = groups.firstIndex(where: { !$0.bounds.contains { $0.intersects(box) } }) {
                groups[g].members.append(z)
                groups[g].bounds.append(box)
            } else {
                groups.append(([z], [box]))
            }
        }
        return groups.map(\.members)
    }
}
