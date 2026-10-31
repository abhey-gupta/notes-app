import Foundation
import InkModel
import Library
import Observation
import os
import Sync
import UIKit

/// Two-way sync through a folder in Files (#225): the folder, when passes run, and the status Settings and the
/// library title show. Off until a folder is chosen.
///
/// Every pass is one ``SyncEngine`` pull, then push, run one at a time from ``kick()`` (the engine's state
/// must never see two passes at once); one asked for during a pass makes it run once more. Triggers (`+Triggers`):
/// - push: any library change arms a 10 s debounce; leaving the editor runs once its notebooks are flushed;
///   the scene going to the background runs at once inside a background task; launch after the library loads;
///   Sync Now.
/// - pull: the folder's file presenter (3 s debounce), the scene coming to the foreground, every 30 s while
///   active, and once more after every pass that sent something.
///
/// Notebooks open in an editor are kept current in the engine (their page changes wait); when one closes its
/// deferred changes are written and the title line says "Updated from ‹device›". An empty library adopts
/// everything in the folder ("Bringing in N notebooks…").
@MainActor
@Observable
final class SyncModel {
    enum Status: Equatable {
        case off
        case idle(SyncSummary)
        case sending(SyncProgress)
        case receiving(SyncProgress)
        /// Sent; iCloud Drive is still uploading `pending` notebooks.
        case uploading(pending: Int)
        /// The bookmark no longer resolves: choose the folder again.
        case folderUnavailable
        case failed(String)
    }

    /// The quiet line under the library title (#174 mock 05-D, #225 mock 03).
    enum Line: Equatable {
        /// "Sending Thermodynamics · 2 pages", "Updating from iPhone · 3 of 7 pages", hairline at `fraction`.
        case progress(String, fraction: Double)
        /// "Synced just now", for ``doneLineDuration``.
        case done
        /// "Updated from iPhone", for ``doneLineDuration``.
        case updated(from: String)
    }

    var status = Status.off
    var line: Line?
    /// "iCloud Drive › Notespace"; `nil` until a folder is chosen.
    private(set) var folderName: String?
    /// Devices syncing through the folder (this one included), as of the last pass.
    var deviceCount = 0
    /// Notebooks coming into an empty library ("Bringing in N notebooks…"); `nil` when not adopting.
    var adopting: Int?

    static let bookmarkKey = "syncFolder"
    static let debounce = Duration.seconds(10)
    static let doneLineDuration = Duration.seconds(2)

    @ObservationIgnored let library: StoreLibrary
    /// `-syncRoot`: a fixed folder, no picker, no bookmark (UI tests).
    @ObservationIgnored private let fixedRoot: URL?
    @ObservationIgnored private(set) var folder: SyncFolder?
    @ObservationIgnored private(set) var engine: SyncEngine?
    @ObservationIgnored var presenter: FolderPresenter?
    @ObservationIgnored var wantsPass = false
    /// Notebooks whose editor closed: their deferred changes are written before the next pass.
    @ObservationIgnored var closedNotebooks: [NotebookID] = []
    @ObservationIgnored var openNotebooks: Set<NotebookID> = []
    @ObservationIgnored var openUpdate: Task<Void, Never>?
    @ObservationIgnored var isRunning = false
    @ObservationIgnored var runID = 0
    /// The pass whose progress the line shows.
    @ObservationIgnored var lineRun = 0
    @ObservationIgnored var lastSync: Date?
    @ObservationIgnored var collectedGarbage = false
    @ObservationIgnored var debounceTask: Task<Void, Never>?
    @ObservationIgnored var presenterDebounce: Task<Void, Never>?
    @ObservationIgnored var pollTask: Task<Void, Never>?
    @ObservationIgnored var lineTask: Task<Void, Never>?
    @ObservationIgnored var uploadTask: Task<Void, Never>?
    /// Files written that may still be uploading.
    @ObservationIgnored var uploading: [URL] = []
    @ObservationIgnored var uploadPeak = 0
    @ObservationIgnored var isBackground = false
    @ObservationIgnored var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored var backgroundEnd: Task<Void, Never>?
    /// The library has loaded: passes may run (an unloaded library would look empty).
    @ObservationIgnored var started = false

    static let log = Logger(subsystem: "com.abhey.notespace", category: "sync")

    init(library: StoreLibrary, fixedRoot: URL? = nil) {
        self.library = library
        self.fixedRoot = fixedRoot
        if let fixedRoot {
            use(.url(fixedRoot))
        } else if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            use(.bookmark(data))
        }
        library.didChange = { [weak self] in self?.scheduleSync() }
        NotebookSession.openNotebooksDidChange = { [weak self] ids in self?.openNotebooksChanged(ids) }
        startPolling()
    }

    var hasFolder: Bool {
        folder != nil
    }

    /// Sending or receiving (Sync Now is off meanwhile).
    var isSyncing: Bool {
        switch status {
        case .sending, .receiving: true
        default: false
        }
    }

    // MARK: Folder

    /// A folder picked in Files: bookmark it, sync there (an empty library adopts what it holds).
    func choose(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try SyncFolder.bookmark(for: url)
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            use(.bookmark(data))
            syncNow()
        } catch {
            Self.log.error("bookmark: \(error.localizedDescription, privacy: .public)")
            status = .failed("Notespace can’t use that folder. Choose another one.")
        }
    }

    /// Stop Syncing: forget the folder (what it holds stays; so does this library).
    func stop() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        removePresenter()
        folder = nil
        engine = nil
        folderName = nil
        debounceTask?.cancel()
        uploadTask?.cancel()
        uploading = []
        status = .off
        line = nil
        adopting = nil
        deviceCount = 0
        lastSync = nil
    }

    private func use(_ folder: SyncFolder) {
        removePresenter()
        let url = folder.resolvedURL
        self.folder = folder
        folderName = url.map(SyncFolder.displayName) ?? "Sync folder"
        deviceCount = 0
        lastSync = nil
        uploading = []
        guard let url else {
            engine = nil
            status = .folderUnavailable
            return
        }
        let device = UIDevice.current
        engine = SyncEngine(
            folder: folder,
            fileSystem: CoordinatedFileSystem(root: url),
            library: library.store,
            device: DeviceIdentity.current(name: device.name, model: device.model),
            stateURL: library.store.locations.libraryDirectory.appending(path: SyncState.fileName),
            bookmarkRefreshed: { data in
                Task { @MainActor in UserDefaults.standard.set(data, forKey: Self.bookmarkKey) }
            }
        )
        if !isBackground {
            addPresenter()
        }
    }

    /// Settings › Devices: every device using the folder, this one first; those unseen for 90 days left out.
    func devices() async -> [DeviceRecord] {
        guard let engine else { return [] }
        do {
            return try await Self.active(engine.devices(), me: engine.device.id)
        } catch {
            fail(error)
            return []
        }
    }

    /// This device and those seen within ``SyncEngine/activeWindow`` (older ones drop off the list).
    static func active(_ devices: [DeviceRecord], me: String) -> [DeviceRecord] {
        let now = Date()
        return devices.filter { $0.id == me || now.timeIntervalSince($0.lastSeen) <= SyncEngine.activeWindow }
    }
}

/// Settings' "Up to date · 2 minutes ago" and the Devices row's count.
struct SyncSummary: Equatable {
    var last: Date?
    var devices: Int
}
