import CoreGraphics
import InkModel
import Tools

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func randomStroke(_ rng: inout SplitMix64) -> Stroke {
    let samples = (0 ..< Int.random(in: 1 ... 8, using: &rng)).map { i in
        Sample(x: .random(in: 0 ... 595, using: &rng), y: .random(in: 0 ... 842, using: &rng), t: Float(i) / 240)
    }
    let tool = PenKind.allCases.randomElement(using: &rng) ?? .fountain
    return Stroke(tool: tool, color: .primary, width: .random(in: 1 ... 8, using: &rng), samples: samples)
}

private func randomSubset(_ page: Page, _ rng: inout SplitMix64) -> [StrokeID] {
    let ids = page.strokes.map(\.id).filter { _ in Bool.random(using: &rng) }
    return ids.isEmpty ? [page.strokes[0].id] : ids.shuffled(using: &rng)
}

/// A valid random edit for `page`, built with the `Page` factories.
func randomEdit(_ page: Page, _ rng: inout SplitMix64) throws -> PageEdit {
    if page.strokes.isEmpty {
        return page.addEdit([randomStroke(&rng)])
    }
    switch Int.random(in: 0 ..< 5, using: &rng) {
    case 0:
        return page.addEdit((0 ..< Int.random(in: 1 ... 3, using: &rng)).map { _ in randomStroke(&rng) })
    case 1:
        return try page.removeEdit(randomSubset(page, &rng))
    case 2:
        var replacements: [StrokeID: [Stroke]] = [:]
        for id in randomSubset(page, &rng) {
            replacements[id] = (0 ..< Int.random(in: 0 ... 3, using: &rng)).map { _ in randomStroke(&rng) }
        }
        return try page.replaceEdit(replacements)
    case 3:
        let t = CGAffineTransform(translationX: .random(in: -50 ... 50, using: &rng), y: .random(in: -50 ... 50, using: &rng))
            .scaledBy(x: .random(in: 0.5 ... 2, using: &rng), y: .random(in: 0.5 ... 2, using: &rng))
        return try page.transformEdit(randomSubset(page, &rng), by: t)
    default:
        let color = InkColor.custom(RGBA8(rgba: UInt32.random(in: 0 ... .max, using: &rng)))
        return try page.recolorEdit(randomSubset(page, &rng), to: color)
    }
}

/// Stroke-level equality up to Float rounding from transform round trips (`rev` ignored).
func approximatelyEqual(_ a: Page, _ b: Page) -> Bool {
    guard a.id == b.id, a.strokes.count == b.strokes.count else { return false }
    return zip(a.strokes, b.strokes).allSatisfy { s, t in
        s.id == t.id && s.tool == t.tool && s.color == t.color && abs(s.width - t.width) <= 1e-3 * s.width
            && s.samples.count == t.samples.count
            && zip(s.samples, t.samples).allSatisfy { abs($0.x - $1.x) < 1e-2 && abs($0.y - $1.y) < 1e-2 }
    }
}

/// Stand-in for `DocumentStore`: the only applier.
struct Model {
    var pages: [PageID: Page]
    var order: [PageID]

    init(pageCount: Int) {
        let pages = (0 ..< pageCount).map { _ in Page() }
        self.pages = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
        order = pages.map(\.id)
    }

    /// Builds a random edit on a random page and applies it.
    mutating func randomStep(_ rng: inout SplitMix64) throws -> EditStep {
        let id = order[Int.random(in: 0 ..< order.count, using: &rng)]
        let step = try EditStep(pageID: id, edit: randomEdit(pages[id] ?? Page(), &rng))
        try apply(step)
        return step
    }

    mutating func apply(_ step: EditStep) throws {
        guard var page = pages[step.pageID] else { return }
        try page.apply(step.edit)
        pages[step.pageID] = page
    }

    mutating func apply(_ entry: EditEntry) throws {
        for step in entry.steps {
            try apply(step)
        }
    }

    func approximatelyEquals(_ other: Model) -> Bool {
        order == other.order && order.allSatisfy { id in
            guard let a = pages[id], let b = other.pages[id] else { return false }
            return approximatelyEqual(a, b)
        }
    }
}
