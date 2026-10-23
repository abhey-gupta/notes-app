import CoreGraphics
import Foundation
import UIKit

/// Identity of one touch sequence (one finger or one Pencil contact), stable from began to ended.
public struct TouchID: Hashable, Sendable {
    /// Opaque value.
    public let rawValue: UInt

    /// Creates an ID (tests use small integers).
    public init(_ rawValue: UInt) {
        self.rawValue = rawValue
    }
}

/// Value snapshot of a `UITouch` (main, coalesced or predicted), so the input pipeline is pure logic
/// and tests can synthesize touches.
public struct TouchRecord: Hashable, Sendable {
    /// Input device.
    public enum Kind: Hashable, Sendable {
        /// Apple Pencil.
        case pencil
        /// Finger (or palm) on the screen.
        case direct
        /// Pointer, indirect touch: never draws.
        case other
    }

    /// Mirror of `UITouch.Properties`.
    public struct Properties: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// Pressure.
        public static let force = Properties(rawValue: 1 << 0)
        /// Azimuth.
        public static let azimuth = Properties(rawValue: 1 << 1)
        /// Altitude.
        public static let altitude = Properties(rawValue: 1 << 2)
        /// Position.
        public static let location = Properties(rawValue: 1 << 3)
    }

    /// The touch sequence this record belongs to (coalesced/predicted records carry their main touch's ID).
    public var id: TouchID
    /// Input device.
    public var kind: Kind
    /// Position in the engine view (`preciseLocation` for Pencil).
    public var location: CGPoint
    /// `UITouch.timestamp`: seconds of system uptime, the `CACurrentMediaTime()` clock.
    public var timestamp: TimeInterval
    /// Raw force (`UITouch.force`).
    public var force: CGFloat
    /// `UITouch.maximumPossibleForce`; `0` when the device reports no pressure.
    public var maximumPossibleForce: CGFloat
    /// Altitude (radians, `π/2` upright).
    public var altitude: CGFloat
    /// Azimuth in the engine view (radians).
    public var azimuth: CGFloat
    /// Contact radius (pt); large values indicate a palm.
    public var majorRadius: CGFloat
    /// `UITouch.estimationUpdateIndex`: set while estimated properties await updates.
    public var estimationUpdateIndex: Int?
    /// Properties whose values are estimates that will be refined by a later update.
    public var estimatedPropertiesExpectingUpdates: Properties

    /// Creates a record. Defaults describe an upright Pencil with no pending estimates.
    public init(
        id: TouchID,
        kind: Kind = .pencil,
        location: CGPoint,
        timestamp: TimeInterval,
        force: CGFloat = 1,
        maximumPossibleForce: CGFloat = 4,
        altitude: CGFloat = .pi / 2,
        azimuth: CGFloat = 0,
        majorRadius: CGFloat = 1,
        estimationUpdateIndex: Int? = nil,
        estimatedPropertiesExpectingUpdates: Properties = []
    ) {
        self.id = id
        self.kind = kind
        self.location = location
        self.timestamp = timestamp
        self.force = force
        self.maximumPossibleForce = maximumPossibleForce
        self.altitude = altitude
        self.azimuth = azimuth
        self.majorRadius = majorRadius
        self.estimationUpdateIndex = estimationUpdateIndex
        self.estimatedPropertiesExpectingUpdates = estimatedPropertiesExpectingUpdates
    }

    /// Normalized pressure `0...1`; ``InkModel/Sample/neutralForce`` when the device reports none.
    public var normalizedForce: Float {
        guard maximumPossibleForce > 0, force.isFinite else { return 0.5 }
        return Float(min(max(force / maximumPossibleForce, 0), 1))
    }
}

@MainActor
public extension TouchID {
    /// Identity of a `UITouch` object (stable for the touch's lifetime).
    init(_ touch: UITouch) {
        self.init(UInt(bitPattern: ObjectIdentifier(touch)))
    }
}

@MainActor
public extension TouchRecord {
    /// Snapshots `touch` in `view`'s coordinates.
    /// - Parameter id: Sequence identity; pass the main touch's ID for coalesced/predicted touches.
    init(_ touch: UITouch, id: TouchID? = nil, in view: UIView) {
        let kind: Kind = switch touch.type {
        case .pencil: .pencil
        case .direct: .direct
        default: .other
        }
        self.init(
            id: id ?? TouchID(touch),
            kind: kind,
            location: kind == .pencil ? touch.preciseLocation(in: view) : touch.location(in: view),
            timestamp: touch.timestamp,
            force: touch.force,
            maximumPossibleForce: touch.maximumPossibleForce,
            altitude: touch.altitudeAngle,
            azimuth: kind == .pencil ? touch.azimuthAngle(in: view) : 0,
            majorRadius: touch.majorRadius,
            estimationUpdateIndex: touch.estimationUpdateIndex?.intValue,
            estimatedPropertiesExpectingUpdates: Properties(touch.estimatedPropertiesExpectingUpdates)
        )
    }
}

extension TouchRecord.Properties {
    init(_ properties: UITouch.Properties) {
        self = []
        if properties.contains(.force) {
            insert(.force)
        }
        if properties.contains(.azimuth) {
            insert(.azimuth)
        }
        if properties.contains(.altitude) {
            insert(.altitude)
        }
        if properties.contains(.location) {
            insert(.location)
        }
    }
}
