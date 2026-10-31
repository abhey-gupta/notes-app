import Foundation
import Sync

/// Tells sync when files in the folder change (another device's log entries and blobs arriving), where the
/// provider reports it: iCloud Drive does for its folders, others may not (the 30 s poll covers them). Holds the
/// folder's security scope while registered. Our own coordinated writes are reported too.
///
/// `@unchecked Sendable`: every stored property is a `let` set in `init`; `NSFileCoordinator` calls the
/// presenter methods on `presentedItemOperationQueue`, and `onChange` is `@Sendable`.
final class FolderPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let scope: SyncFolder.Scope?
    private let onChange: @Sendable () -> Void

    /// Registers at once; ``remove()`` before dropping it.
    init(folder: SyncFolder, onChange: @escaping @Sendable () -> Void) {
        scope = try? folder.beginAccess()
        presentedItemURL = scope?.url ?? folder.resolvedURL
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        presentedItemOperationQueue = queue
        self.onChange = onChange
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    func remove() {
        NSFileCoordinator.removeFilePresenter(self)
        scope?.end()
    }

    func presentedItemDidChange() {
        onChange()
    }

    func presentedSubitemDidChange(at _: URL) {
        onChange()
    }

    func presentedSubitemDidAppear(at _: URL) {
        onChange()
    }
}
