import CoreGraphics
import Foundation

/// Decides what each touch does: draw, navigate (scroll/zoom), or nothing (palm). ARCHITECTURE.md §3.2.
///
/// Rules, in order:
/// 1. Pencil touches draw.
/// 2. A finger touch that begins while a Pencil touch is down, or within ``palmWindow`` after one
///    ends, is a palm.
/// 3. A finger touch whose `majorRadius` exceeds ``palmMajorRadius`` (at any point) is a palm.
/// 4. Other finger touches draw only if "Draw with finger" is on and no Pencil has been seen this
///    session; otherwise they navigate.
///
/// Feed every touch's began/moved/ended so Pencil activity and roles stay current.
public struct InputPolicy: Sendable {
    /// Role of a touch.
    public enum Role: Hashable, Sendable {
        /// Ink (or eraser/lasso) input.
        case draw
        /// Scroll/zoom; the engine ignores it and the host's gestures handle it.
        case navigate
        /// Rejected contact: neither draws nor should navigate.
        case palm
    }

    /// Finger touches beginning this soon after a Pencil lift are palms (s).
    public var palmWindow: TimeInterval = 0.15
    /// Finger contacts larger than this (pt) are palms. The simulator reports ~37 pt for every synthesized
    /// touch, so it only rejects by timing there.
    public var palmMajorRadius: CGFloat = Self.defaultPalmMajorRadius

    #if targetEnvironment(simulator)
        public static let defaultPalmMajorRadius: CGFloat = .infinity
    #else
        public static let defaultPalmMajorRadius: CGFloat = 32
    #endif
    /// "Draw with finger" setting.
    public var allowsFingerDrawing: Bool

    /// A Pencil touched the screen this session.
    public private(set) var hasSeenPencil = false
    private var activePencils: Set<TouchID> = []
    private var lastPencilEnd: TimeInterval = -.infinity
    private var roles: [TouchID: Role] = [:]

    /// Creates a policy.
    public init(allowsFingerDrawing: Bool = false, palmMajorRadius: CGFloat = Self.defaultPalmMajorRadius) {
        self.allowsFingerDrawing = allowsFingerDrawing
        self.palmMajorRadius = palmMajorRadius
    }

    /// A Pencil touch is down.
    public var isPencilActive: Bool {
        !activePencils.isEmpty
    }

    /// Current role of a live touch.
    public func role(of id: TouchID) -> Role? {
        roles[id]
    }

    /// Classifies a new touch.
    public mutating func began(_ touch: TouchRecord) -> Role {
        let role: Role
        switch touch.kind {
        case .pencil:
            hasSeenPencil = true
            activePencils.insert(touch.id)
            role = .draw
        case .direct:
            if isPencilActive || touch.timestamp - lastPencilEnd < palmWindow || touch.majorRadius > palmMajorRadius {
                role = .palm
            } else {
                role = allowsFingerDrawing && !hasSeenPencil ? .draw : .navigate
            }
        case .other:
            role = .navigate
        }
        roles[touch.id] = role
        return role
    }

    /// Re-checks a moving touch; a finger contact that grows into a palm is demoted to ``Role/palm``.
    public mutating func moved(_ touch: TouchRecord) -> Role {
        guard var role = roles[touch.id] else { return began(touch) }
        if touch.kind == .direct, role != .palm, touch.majorRadius > palmMajorRadius {
            role = .palm
            roles[touch.id] = role
        }
        return role
    }

    /// A touch ended or was cancelled.
    public mutating func ended(_ touch: TouchRecord) {
        roles[touch.id] = nil
        if activePencils.remove(touch.id) != nil {
            lastPencilEnd = max(lastPencilEnd, touch.timestamp)
        }
    }
}
