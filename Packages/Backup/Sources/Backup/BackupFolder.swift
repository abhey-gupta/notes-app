import Foundation

/// The folder backups go to (#174): picked once in Files and kept as a bookmark, or a plain URL (`-backupRoot`
/// in UI tests, package tests).
public enum BackupFolder: Hashable, Sendable {
    case bookmark(Data)
    case url(URL)

    /// A bookmark for a folder the Files picker returned. Call while accessing its security scope.
    public static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Where the folder is now (no security scope; for its name). `nil` if the bookmark doesn't resolve.
    public var resolvedURL: URL? {
        switch self {
        case let .bookmark(data):
            var isStale = false
            return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        case let .url(url):
            return url
        }
    }

    /// Resolves the folder and runs `body` inside its security scope.
    /// - Parameter refreshed: Called with a new bookmark when the stored one was stale (folder moved).
    /// - Throws: ``BackupError/folderUnavailable`` if the bookmark doesn't resolve or the folder is gone;
    ///   `body`'s errors as ``BackupError/failed(_:)``.
    func access<T>(refreshed: (Data) -> Void = { _ in }, _ body: (URL) throws -> T) throws(BackupError) -> T {
        var url: URL
        var isStale = false
        switch self {
        case let .bookmark(data):
            guard let resolved = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
                throw .folderUnavailable
            }
            url = resolved
        case let .url(plain):
            url = plain
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw .folderUnavailable
        }
        if isStale, let data = try? Self.bookmark(for: url) {
            refreshed(data)
        }
        url = url.standardizedFileURL
        do {
            return try body(url)
        } catch {
            throw BackupError(error)
        }
    }

    /// "iCloud Drive › Notespace", or the folder's name where the provider isn't known from the path.
    public static func displayName(for url: URL) -> String {
        let components = url.standardizedFileURL.pathComponents
        if let i = components.firstIndex(of: "com~apple~CloudDocs"), i > 0, components[i - 1] == "Mobile Documents" {
            return i + 1 < components.count ? "iCloud Drive › \(url.lastPathComponent)" : "iCloud Drive"
        }
        return url.lastPathComponent
    }
}

/// Why a backup run or restore failed.
public enum BackupError: Error, Hashable, Sendable {
    /// The bookmark no longer resolves or the folder is gone: choose it again.
    case folderUnavailable
    /// Anything else, as a sentence for Settings' footer; the next trigger retries.
    case failed(String)

    init(_ error: any Error) {
        if let error = error as? BackupError {
            self = error
        } else if let error = error as? CocoaError, error.code == .fileWriteOutOfSpace {
            self = .failed("There isn’t enough space in the backup folder. Backups resume once space is free.")
        } else if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSUserCancelledError {
            self = .failed("The backup folder didn’t respond. Backups will try again.")
        } else {
            self = .failed(error.localizedDescription)
        }
    }
}
