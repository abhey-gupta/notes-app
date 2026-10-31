import Foundation
import InkModel

/// The backup folder's side of a run (#174): every write is a copy into a hidden temp file beside the target,
/// inside the folder (a temp directory elsewhere may be another volume or provider), then an atomic replace,
/// all under `NSFileCoordinator` so the provider (iCloud Drive, Google Drive…) sees whole files and uploads
/// them out of process. Reads go through a coordinated read, which downloads a placeholder first.
/// Coordination gives up after `timeout` (a provider that never answers fails the run, never hangs it).
struct BackupDestination: Sendable {
    let root: URL
    var timeout: Duration = .seconds(60)

    func url(_ relative: String) -> URL {
        root.appending(path: relative)
    }

    /// Packages in `Notebooks/` and `Trash/` (placeholders `.<id>.nb.icloud` count).
    func listing() throws -> RemoteListing {
        func ids(_ location: BackupLocation) throws -> Set<NotebookID> {
            let directory = url(location.directory).path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: directory) else { return [] }
            return try Set(FileManager.default.contentsOfDirectory(atPath: directory).compactMap { name in
                var name = name
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    name = String(name.dropFirst().dropLast(".icloud".count))
                }
                guard name.hasSuffix(".nb") else { return nil }
                return NotebookID(uuidString: String(name.dropLast(3)))
            })
        }
        return try RemoteListing(notebooks: ids(.notebooks), trash: ids(.trash))
    }

    /// `library.json`, or `nil` if missing or unreadable.
    func readCatalog() -> BackupCatalog? {
        var data: Data?
        try? coordinate(reading: url(BackupLayout.catalog)) { data = try? Data(contentsOf: $0) }
        return data.flatMap(BackupCatalog.decode)
    }

    func writeCatalog(_ catalog: BackupCatalog) throws {
        let data = try catalog.encoded()
        try replace(BackupLayout.catalog) { try data.write(to: $0) }
    }

    /// Copies a local file over `relative` (APFS clones it where the folder is on the same volume).
    func copy(_ source: URL, to relative: String) throws {
        try replace(relative) { try FileManager.default.copyItem(at: source, to: $0) }
    }

    /// Deletes a file or package; missing is fine.
    func delete(_ relative: String) throws {
        let target = url(relative)
        try coordinate(writing: target, options: .forDeleting) { target in
            do {
                try FileManager.default.removeItem(at: target)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {}
        }
    }

    /// Moves a package, replacing anything at `to`.
    func move(_ relative: String, to destination: String) throws {
        let (source, target) = (url(relative), url(destination))
        let coordinator = NSFileCoordinator(filePresenter: nil)
        try guarded(coordinator) { error in
            var failure: (any Error)?
            coordinator.coordinate(
                writingItemAt: source, options: .forMoving, writingItemAt: target, options: .forReplacing, error: error
            ) { source, target in
                do {
                    let fm = FileManager.default
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: target.path(percentEncoded: false)) {
                        try fm.removeItem(at: target)
                    }
                    try fm.moveItem(at: source, to: target)
                    coordinator.item(at: source, didMoveTo: target)
                } catch {
                    failure = error
                }
            }
            return failure
        }
    }

    /// Copies `relative` (a package) out of the folder to the local `destination` (Restore), downloading it first.
    func copyOut(_ relative: String, to destination: URL) throws {
        try coordinate(reading: url(relative)) { try FileManager.default.copyItem(at: $0, to: destination) }
    }

    /// Whether every file in `urls` is uploaded; files outside iCloud Drive count as uploaded (other providers
    /// don't say).
    static func isUploaded(_ urls: [URL]) -> Bool {
        urls.allSatisfy { url in
            var url = url
            url.removeAllCachedResourceValues()
            guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey]),
                  values.isUbiquitousItem == true else { return true }
            return values.ubiquitousItemIsUploaded ?? true
        }
    }

    // MARK: Coordination

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
                throw BackupError.failed("The backup folder didn’t respond. Backups will try again.")
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
