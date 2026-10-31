import Foundation

/// The folder devices sync through (#225): picked once in Files and kept as a bookmark, or a plain URL
/// (`-syncRoot` in UI tests, package tests). Any provider's folder works (iCloud Drive, Google Drive,
/// Dropbox…): the provider moves the files between devices, the format (``SyncLayout``) makes that safe.
public enum SyncFolder: Hashable, Sendable {
    case bookmark(Data)
    case url(URL)

    /// A bookmark for a folder the Files picker returned. Call while accessing its security scope.
    public static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Where the folder is now (no security scope; for its name and a ``CoordinatedFileSystem``). `nil` if
    /// the bookmark doesn't resolve.
    public var resolvedURL: URL? {
        switch self {
        case let .bookmark(data):
            var isStale = false
            return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        case let .url(url):
            return url
        }
    }

    /// The folder's security scope, held from ``SyncFolder/beginAccess(refreshed:)`` until ``end()``.
    /// A value so an engine run can hold it across `await`s (a closure-scoped access can't).
    public struct Scope: Sendable {
        /// The resolved folder (standardized).
        public let url: URL
        private let scoped: Bool
        private let resolved: URL

        init(url: URL, scoped: Bool, resolved: URL) {
            self.url = url
            self.scoped = scoped
            self.resolved = resolved
        }

        /// Gives the security scope back.
        public func end() {
            if scoped {
                resolved.stopAccessingSecurityScopedResource()
            }
        }
    }

    /// Resolves the folder and enters its security scope; call ``Scope/end()`` when done.
    /// - Parameter refreshed: Called with a new bookmark when the stored one was stale (folder moved).
    /// - Throws: ``SyncError/folderUnavailable`` if the bookmark doesn't resolve or the folder is gone.
    public func beginAccess(refreshed: (Data) -> Void = { _ in }) throws(SyncError) -> Scope {
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
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
            throw .folderUnavailable
        }
        if isStale, let data = try? Self.bookmark(for: url) {
            refreshed(data)
        }
        return Scope(url: url.standardizedFileURL, scoped: scoped, resolved: url)
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

/// Why a sync pass failed. Nothing half-applied is recorded: the next pass retries from the same point.
public enum SyncError: Error, Hashable, Sendable {
    /// The bookmark no longer resolves or the folder is gone: choose it again.
    case folderUnavailable
    /// The folder was written by a newer Notespace (`sync.json` format): update the app.
    case newerFormat(Int)
    /// Anything else, as a sentence for Settings' footer; the next trigger retries.
    case failed(String)

    init(_ error: any Error) {
        if let error = error as? SyncError {
            self = error
        } else if let error = error as? CocoaError, error.code == .fileWriteOutOfSpace {
            self = .failed("There isn’t enough space in the sync folder. Syncing resumes once space is free.")
        } else if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSUserCancelledError {
            self = .failed(SyncError.notResponding)
        } else {
            self = .failed(error.localizedDescription)
        }
    }

    static let notResponding = "The sync folder didn’t respond. Syncing will try again."
}
