import CoreGraphics

/// Extra paper beside every page of a notebook (#129): the page grows by ``left`` and ``right`` points
/// past its original width (``Notebook/pageSize``). Each side moves in ``step``s of the original width,
/// up to ``maximum`` of it.
///
/// Page space always starts at the widened page's left edge, so growing (or shrinking) ``left`` moves
/// every stroke by the same amount and nothing else (engine, export, thumbnails) needs to know.
public struct PageExtension: Hashable, Sendable, Codable {
    /// One drag step, as a fraction of the original page width.
    public static let step: CGFloat = 0.25
    /// Most a side can add, as a fraction of the original page width.
    public static let maximum: CGFloat = 2
    /// Steps per side up to ``maximum``.
    public static let maximumSteps = Int((maximum / step).rounded())
    /// No extra paper.
    public static let none = PageExtension()

    /// Points added left of the original page.
    public var left: CGFloat
    /// Points added right of the original page.
    public var right: CGFloat

    /// Creates an extension (negative values clamp to 0).
    public init(left: CGFloat = 0, right: CGFloat = 0) {
        self.left = max(left, 0)
        self.right = max(right, 0)
    }

    /// Steps of `width`.
    public init(leftSteps: Int, rightSteps: Int, of width: CGFloat) {
        self.init(left: CGFloat(leftSteps) * Self.step * width, right: CGFloat(rightSteps) * Self.step * width)
    }

    /// Whether the page has its original width.
    public var isNone: Bool {
        left == 0 && right == 0
    }

    /// The widened page for an original page of `size`.
    public func pageSize(for size: CGSize) -> CGSize {
        CGSize(width: size.width + left + right, height: size.height)
    }

    /// `side`'s extension in whole steps of `width` (rounded).
    public func steps(_ side: Side, of width: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        return Int((self[side] / (Self.step * width)).rounded())
    }

    /// Points added on `side`.
    public subscript(side: Side) -> CGFloat {
        get { side == .left ? left : right }
        set {
            if side == .left {
                left = max(newValue, 0)
            } else {
                right = max(newValue, 0)
            }
        }
    }

    /// A side of the page.
    public enum Side: Hashable, Sendable, CaseIterable {
        case left, right
    }
}

public extension Notebook {
    /// Every page's actual size: ``pageSize`` widened by ``pageExtension``.
    var extendedPageSize: CGSize {
        pageExtension.pageSize(for: pageSize)
    }
}
