import Foundation

/// The sync folder as the engine sees it: paths relative to the folder (``SyncLayout``), whole files only.
/// A protocol so tests can put a fault-injecting file system (late arrivals, evicted files, partial
/// listings) between engines and a temp folder; the app uses ``CoordinatedFileSystem``.
public protocol SyncFileSystem: Sendable {
    /// Absolute URL of `path` (upload tracking).
    func url(_ path: String) -> URL
    /// Names in a directory (files and subdirectories), hidden files left out; a missing directory is empty.
    /// A not-yet-downloaded file counts under its real name.
    func list(_ directory: String) throws(SyncError) -> [String]
    /// A small file's contents (downloading it first if needed); `nil` if it isn't there (yet).
    func read(_ path: String) throws(SyncError) -> Data?
    /// Writes `data` to `path` atomically (temp file beside it, then rename), replacing any file there.
    func write(_ path: String, _ data: Data) throws(SyncError)
    /// Copies a local file to `path` atomically.
    func copyIn(_ local: URL, to path: String) throws(SyncError)
    /// Copies `path` to `local` (which must not exist).
    func copyOut(_ path: String, to local: URL) throws(SyncError)
    /// Deletes a file; missing is fine.
    func delete(_ path: String) throws(SyncError)
    /// Whether `path` is there with its contents on this device (not missing, not an evicted placeholder).
    func isDownloaded(_ path: String) -> Bool
    /// Asks the provider to download an evicted file; a later pass finds it downloaded.
    func startDownload(_ path: String)
}

/// The real folder (#174's backup mechanics): every write is a copy into a hidden temp file beside the
/// target, inside the folder (a temp directory elsewhere may be another volume or provider), then an atomic
/// replace, all under `NSFileCoordinator` so the provider (iCloud Drive, Google Drive…) sees whole files and
/// uploads them out of process. Reads go through a coordinated read, which downloads a placeholder first.
/// Coordination gives up after `timeout` (a provider that never answers fails the pass, never hangs it).
/// Call inside the folder's security scope (``SyncFolder/beginAccess(refreshed:)``).
public struct CoordinatedFileSystem: SyncFileSystem {
    public let root: URL
    public var timeout: Duration

    public init(root: URL, timeout: Duration = .seconds(60)) {
        self.root = root
        self.timeout = timeout
    }

    public func url(_ path: String) -> URL {
        root.appending(path: path)
    }

    public func list(_ directory: String) throws(SyncError) -> [String] {
        let path = url(directory).path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(atPath: path).compactMap { name in
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    return String(name.dropFirst().dropLast(".icloud".count))
                }
                return name.hasPrefix(".") ? nil : name
            }
        } catch {
            throw SyncError(error)
        }
    }

    public func read(_ path: String) throws(SyncError) -> Data? {
        let target = url(path)
        let placeholder = Self.placeholder(for: target)
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path(percentEncoded: false)) || fm.fileExists(atPath: placeholder.path(percentEncoded: false))
        else { return nil }
        var data: Data?
        try attempt { try coordinate(reading: target) { data = try? Data(contentsOf: $0) } }
        return data
    }

    public func write(_ path: String, _ data: Data) throws(SyncError) {
        try attempt { try replace(path) { try data.write(to: $0) } }
    }

    public func copyIn(_ local: URL, to path: String) throws(SyncError) {
        try attempt { try replace(path) { try FileManager.default.copyItem(at: local, to: $0) } }
    }

    public func copyOut(_ path: String, to local: URL) throws(SyncError) {
        try attempt { try coordinate(reading: url(path)) { try FileManager.default.copyItem(at: $0, to: local) } }
    }

    public func delete(_ path: String) throws(SyncError) {
        let target = url(path)
        try attempt {
            try coordinate(writing: target, options: .forDeleting) { target in
                do {
                    try FileManager.default.removeItem(at: target)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {}
            }
        }
    }

    public func isDownloaded(_ path: String) -> Bool {
        var target = url(path)
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else { return false }
        target.removeAllCachedResourceValues()
        guard let values = try? target.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else { return true }
        return values.ubiquitousItemDownloadingStatus == .current
    }

    public func startDownload(_ path: String) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url(path))
    }

    /// Whether every file in `urls` is uploaded; files outside iCloud Drive count as uploaded (other providers
    /// don't say).
    public static func isUploaded(_ urls: [URL]) -> Bool {
        urls.allSatisfy { url in
            var url = url
            url.removeAllCachedResourceValues()
            guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey]),
                  values.isUbiquitousItem == true else { return true }
            return values.ubiquitousItemIsUploaded ?? true
        }
    }

    /// `.<name>.icloud` beside `url`: iCloud Drive's placeholder for an evicted file.
    static func placeholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud", directoryHint: .notDirectory)
    }

    // MARK: Coordination

    private func attempt(_ body: () throws -> Void) throws(SyncError) {
        do {
            try body()
        } catch {
            throw SyncError(error)
        }
    }

    /// Writes `relative` as `write` makes it at a temp URL beside it, then replaces it atomically.
    private func replace(_ relative: String, write: (URL) throws -> Void) throws {
        let target = url(relative)
        try coordinate(writing: target, options: .forReplacing) { target in
            let fm = FileManager.default
            let parent = target.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let temp = parent.appending(path: ".\(target.lastPathComponent).\(UUID().uuidString).tmp", directoryHint: .notDirectory)
            do {
                try write(temp)
                if fm.fileExists(atPath: target.path(percentEncoded: false)) {
                    _ = try fm.replaceItemAt(target, withItemAt: temp)
                } else {
                    try fm.moveItem(at: temp, to: target)
                }
            } catch {
                try? fm.removeItem(at: temp)
                throw error
            }
        }
    }

    private func coordinate(writing url: URL, options: NSFileCoordinator.WritingOptions, _ accessor: (URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        try guarded(coordinator) { error in
            var failure: (any Error)?
            coordinator.coordinate(writingItemAt: url, options: options, error: error) { url in
                do {
                    try accessor(url)
                } catch {
                    failure = error
                }
            }
            return failure
        }
    }

    private func coordinate(reading url: URL, _ accessor: (URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        try guarded(coordinator) { error in
            var failure: (any Error)?
            coordinator.coordinate(readingItemAt: url, options: [], error: error) { url in
                do {
                    try accessor(url)
                } catch {
                    failure = error
                }
            }
            return failure
        }
    }

    /// Runs one coordination (`body` gets the coordinator's error pointer, returns the accessor's error) with
    /// a watchdog that cancels it after ``timeout``; throws either error.
    private func guarded(_ coordinator: NSFileCoordinator, _ body: (NSErrorPointer) -> (any Error)?) throws {
        let watchdog = Watchdog(coordinator)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout.seconds) { watchdog.fire() }
        defer { watchdog.disarm() }
        var coordinationError: NSError?
        let failure = body(&coordinationError)
        if let error = coordinationError ?? failure {
            if watchdog.fired {
                throw SyncError.failed(SyncError.notResponding)
            }
            throw error
        }
    }
}

/// Cancels a coordination still waiting at its deadline.
/// `@unchecked Sendable`: `NSFileCoordinator.cancel()` may be called from any thread; the flags are guarded by `lock`.
private final class Watchdog: @unchecked Sendable {
    private let coordinator: NSFileCoordinator
    private let lock = NSLock()
    private var armed = true
    private var didFire = false

    var fired: Bool {
        lock.withLock { didFire }
    }

    init(_ coordinator: NSFileCoordinator) {
        self.coordinator = coordinator
    }

    func fire() {
        lock.withLock {
            guard armed else { return }
            didFire = true
            coordinator.cancel()
        }
    }

    func disarm() {
        lock.withLock { armed = false }
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
