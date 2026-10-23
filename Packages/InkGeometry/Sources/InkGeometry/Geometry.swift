import CoreGraphics

/// 2D point/vector in page-space points. All geometry in this package is `Float` (GPU-ready).
public typealias Point2 = SIMD2<Float>

public extension SIMD2<Float> {
    /// Converts a `CGPoint`.
    init(_ p: CGPoint) {
        self.init(Float(p.x), Float(p.y))
    }

    /// As a `CGPoint`.
    var cgPoint: CGPoint {
        CGPoint(x: CGFloat(x), y: CGFloat(y))
    }
}

@inline(__always) func dot(_ a: Point2, _ b: Point2) -> Float {
    a.x * b.x + a.y * b.y
}

/// z of the 2D cross product (twice the signed triangle area spanned by `a`, `b`).
@inline(__always) func cross(_ a: Point2, _ b: Point2) -> Float {
    a.x * b.y - a.y * b.x
}

@inline(__always) func norm(_ a: Point2) -> Float {
    dot(a, a).squareRoot()
}

/// Axis-aligned bounds accumulator.
struct BoundsBuilder {
    var lower = Point2(repeating: .infinity)
    var upper = Point2(repeating: -.infinity)

    @inline(__always) mutating func add(_ p: Point2, radius: Float = 0) {
        lower = pointwiseMin(lower, p - radius)
        upper = pointwiseMax(upper, p + radius)
    }

    var rect: CGRect {
        guard lower.x <= upper.x, lower.y <= upper.y else { return .null }
        return CGRect(
            x: CGFloat(lower.x),
            y: CGFloat(lower.y),
            width: CGFloat(upper.x - lower.x),
            height: CGFloat(upper.y - lower.y)
        )
    }
}

/// Closed-interval rectangle overlap (touching edges count), unlike `CGRect.intersects`.
@inline(__always) func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
    !a.isNull && !b.isNull && a.minX <= b.maxX && b.minX <= a.maxX && a.minY <= b.maxY && b.minY <= a.maxY
}
