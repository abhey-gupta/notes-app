import Foundation

/// `devices/<id>.json`: who syncs through the folder (Settings › Devices) and how far each has read the
/// others' logs (`applied`: device → last seq applied, the acks GC waits for). Rewritten only by its device.
public struct DeviceRecord: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    /// "Abhey's iPad".
    public var name: String
    /// "iPad", "iPhone", "Mac".
    public var model: String
    public var lastSeen: Date
    /// The device's Lamport clock when it wrote this.
    public var clock: UInt64
    public var applied: [String: UInt64]

    public init(id: String, name: String, model: String, lastSeen: Date, clock: UInt64, applied: [String: UInt64]) {
        self.id = id
        self.name = name
        self.model = model
        self.lastSeen = lastSeen
        self.clock = clock
        self.applied = applied
    }

    /// Whether this device has read `seq` of `device`'s log (its own log counts as read).
    func hasApplied(_ seq: UInt64, of device: String) -> Bool {
        device == id || (applied[device] ?? 0) >= seq
    }
}
