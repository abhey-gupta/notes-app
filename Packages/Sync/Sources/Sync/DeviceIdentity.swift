import Foundation

/// This device in the sync folder: a random ID made once per install (it names the device's log and
/// blobs, so it must never change or be shared), plus the name and model shown on other devices.
public struct DeviceIdentity: Hashable, Sendable {
    public static let defaultsKey = "syncDeviceID"

    public var id: String
    /// `UIDevice.current.name`, passed in by the app.
    public var name: String
    public var model: String

    public init(id: String, name: String, model: String) {
        self.id = id
        self.name = name
        self.model = model
    }

    /// The ID stored in `defaults` under ``defaultsKey``, made and stored on first use.
    public static func current(name: String, model: String, defaults: UserDefaults = .standard) -> DeviceIdentity {
        if let id = defaults.string(forKey: defaultsKey), UUID(uuidString: id) != nil {
            return DeviceIdentity(id: id, name: name, model: model)
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: defaultsKey)
        return DeviceIdentity(id: id, name: name, model: model)
    }
}
