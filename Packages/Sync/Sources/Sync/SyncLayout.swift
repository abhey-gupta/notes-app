import Foundation
import InkModel
import Library

/// Paths inside the sync folder (#225). Each device writes only under its own names and every content file
/// is written once, never modified, so two devices never write the same file and a reader never sees half
/// of one:
///
/// ```
/// sync.json                                         format version, created
/// devices/<deviceId>.json                           DeviceRecord: name, model, lastSeen, clock, acks
/// log/<deviceId>/<seq, 10 digits>.json              LogEntry: that device's ops, append-only
/// log/<deviceId>/snapshot.json                      that device's ops folded (GC)
/// blobs/<notebookId>/pages/<pageId>/<clock 12 digits>-<deviceId>.strokes
/// blobs/<notebookId>/cover/<clock 12 digits>-<deviceId>.heic
/// blobs/<notebookId>/images/<name>                  package asset name (unique, written once)
/// blobs/<notebookId>/backgrounds/<name>
/// ```
///
/// A folder without `sync.json` holds nothing to read (a #174 backup folder's `Notebooks/` is never read).
public enum SyncLayout {
    public static let format = "sync.json"
    public static let devices = "devices"
    public static let log = "log"
    public static let blobs = "blobs"
    static let snapshotName = "snapshot.json"

    public static func device(_ id: String) -> String {
        "\(devices)/\(id).json"
    }

    public static func log(of device: String) -> String {
        "\(log)/\(device)"
    }

    /// `log/<device>/0000000042.json`.
    public static func entry(_ seq: UInt64, of device: String) -> String {
        "\(log(of: device))/\(entryName(seq))"
    }

    public static func snapshot(of device: String) -> String {
        "\(log(of: device))/\(snapshotName)"
    }

    static func entryName(_ seq: UInt64) -> String {
        let digits = String(seq)
        return String(repeating: "0", count: max(0, 10 - digits.count)) + digits + ".json"
    }

    /// The seq a log entry name stands for; `nil` for anything else (snapshot, stray files).
    static func seq(ofEntry name: String) -> UInt64? {
        guard name.hasSuffix(".json"), name.count == 15 else { return nil }
        return UInt64(name.dropLast(5))
    }

    /// `<clock 12 digits>-<device>.<ext>`: unique (a device never reuses a clock) and sortable by clock.
    public static func blobName(clock: UInt64, device: String, ext: String) -> String {
        let digits = String(clock)
        return String(repeating: "0", count: max(0, 12 - digits.count)) + digits + "-\(device).\(ext)"
    }

    /// The device a versioned blob name was written by (GC deletes only its own).
    static func device(ofBlob name: String) -> String? {
        guard let dash = name.firstIndex(of: "-"), let dot = name.lastIndex(of: "."), dash < dot else { return nil }
        return String(name[name.index(after: dash) ..< dot])
    }

    static func notebook(_ id: NotebookID) -> String {
        "\(blobs)/\(id)"
    }

    public static func strokes(_ name: String, notebook: NotebookID, page: PageID) -> String {
        "\(self.notebook(notebook))/pages/\(page)/\(name)"
    }

    public static func cover(_ name: String, notebook: NotebookID) -> String {
        "\(self.notebook(notebook))/cover/\(name)"
    }

    /// `blobs/<nb>/images/<name>` or `…/backgrounds/<name>`.
    public static func asset(_ asset: SyncAsset, notebook: NotebookID) -> String {
        "\(self.notebook(notebook))/\(asset.kind.rawValue)/\(asset.name)"
    }
}

/// `sync.json`: marks a folder as a sync folder. A newer `formatVersion` than this build's is refused.
public struct SyncFormat: Hashable, Sendable, Codable {
    public static let formatVersion = 1

    public var formatVersion: Int
    public var created: Date

    public init(formatVersion: Int = SyncFormat.formatVersion, created: Date) {
        self.formatVersion = formatVersion
        self.created = created
    }
}

/// JSON for every file in the folder and the state file: sorted keys, dates as Unix ms (like the manifest).
enum SyncJSON {
    static func encode(_ value: some Encodable) throws(SyncError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        do {
            return try encoder.encode(value)
        } catch {
            throw .failed("Couldn’t encode \(type(of: value)): \(error)")
        }
    }

    /// `nil` if `data` isn't a `T`.
    static func decode<T: Decodable>(_: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(T.self, from: data)
    }
}
