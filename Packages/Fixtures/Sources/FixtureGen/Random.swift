/// SplitMix64. Every draw goes through this type's own helpers (not stdlib `random(in:using:)`, whose
/// algorithm may change between toolchains), so a seed maps to the same bytes on every build.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// Independent stream for `(seed, salt)`: per-page generators don't depend on generation order.
    init(seed: UInt64, salt: UInt64) {
        state = mix(seed ^ mix(salt &+ 0x6A09_E667_F3BC_C909))
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        return mix(state)
    }

    /// Uniform in `0..<1`.
    mutating func unit() -> Float {
        Float(next() >> 40) * 0x1p-24
    }

    /// Uniform in `range`.
    mutating func float(_ range: ClosedRange<Float>) -> Float {
        range.lowerBound + (range.upperBound - range.lowerBound) * unit()
    }

    /// Uniform in `range` (modulo bias is irrelevant here).
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }

    mutating func chance(_ p: Float) -> Bool {
        unit() < p
    }

    /// Index drawn with probability proportional to `weights`.
    mutating func weighted(_ weights: [Float]) -> Int {
        var r = unit() * weights.reduce(0, +)
        for (i, w) in weights.enumerated() {
            r -= w
            if r < 0 {
                return i
            }
        }
        return weights.count - 1
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[int(0 ... items.count - 1)]
    }

    /// Seed for a ``Noise`` channel.
    mutating func noise() -> Noise {
        Noise(seed: next())
    }
}

/// SplitMix64 finalizer: a good 64-bit hash.
func mix(_ value: UInt64) -> UInt64 {
    var z = value
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}

/// 1-D gradient (Perlin) noise: smooth, roughly `-1...1`, period-free. Hand tremor and baseline drift.
struct Noise {
    let seed: UInt64

    func callAsFunction(_ x: Float) -> Float {
        let cell = x.rounded(.down)
        let f = x - cell
        let i = Int64(cell)
        let g0 = gradient(i)
        let g1 = gradient(i &+ 1)
        let u = f * f * (3 - 2 * f)
        let a = g0 * f
        let b = g1 * (f - 1)
        return 2 * (a + (b - a) * u)
    }

    private func gradient(_ i: Int64) -> Float {
        Float(mix(UInt64(bitPattern: i) ^ seed) >> 40) * 0x1p-23 - 1
    }
}
