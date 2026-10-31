import Backup
import Foundation
import InkModel
import Library
import Observation
import os
import UIKit

/// Backup to a folder in Files (#174): the folder, when runs happen, and the status Settings and the library
/// title show. Off until a folder is chosen.
///
/// Triggers: any library change (checkpoints arrive as `documentDidSave`, plus rename, move, trash, new…) arms a
/// 10 s debounce; leaving the editor runs once its notebooks are flushed; the scene going to the background
/// runs at once inside a background task (and so does every change until it comes back); launch runs after
/// the library loads; Back Up Now. Runs go to one ``BackupEngine`` (an actor, off main); one asked for during
/// a run makes it run once more.
@MainActor
@Observable
final class BackupModel {
    enum Status: Equatable {
        case off
        case idle(BackupSummary)
        case copying(BackupEngine.Progress)
        /// Copied; iCloud Drive is still uploading `pending` notebooks.
        case uploading(pending: Int)
        /// The bookmark no longer resolves: choose the folder again.
        case folderUnavailable
        case failed(String)
    }

    /// The quiet line under the library title (mock 05-D).
    enum Line: Equatable {
        /// "Backing up Thermodynamics · 3 of 14", hairline at `fraction`.
        case progress(String, fraction: Double)
        /// "Backed up just now", for ``doneLineDuration``.
        case done
    }

    /// A Restore row.
    enum RowState {
        case restorable, restoring, restored, onThisIPad
    }

    private(set) var status = Status.off
    private(set) var line: Line?
    /// "iCloud Drive › Notespace"; `nil` until a folder is chosen.
    private(set) var folderName: String?
    /// The folder's own name ("Notespace").
    private(set) var folderShortName = ""
    /// The folder's `library.json`: read at launch and when Restore opens.
    private(set) var catalog: BackupCatalog?
    private(set) var restoring: Set<NotebookID> = []
    private(set) var restored: Set<NotebookID> = []
    /// Already in the library (or its trash) when Restore tried.
    private(set) var skipped: Set<NotebookID> = []
    /// Fresh-iPad card → Settings opens on Restore.
    var opensRestore = false

    static let bookmarkKey = "backupFolder"
    static let debounce = Duration.seconds(10)
    static let doneLineDuration = Duration.seconds(2)
    static let uploadPollInterval = Duration.seconds(3)
    /// After the last background run, how long the background task waits for more changes (late flushes).
    static let backgroundGrace = Duration.seconds(3)

    @ObservationIgnored private let library: StoreLibrary
    /// `-backupRoot`: a fixed folder, no picker, no bookmark (UI tests).
    @ObservationIgnored private let fixedRoot: URL?
    @ObservationIgnored private var engine: BackupEngine?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var runsAgain = false
    @ObservationIgnored private var runID = 0
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var lineTask: Task<Void, Never>?
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    /// Files written that may still be uploading, one group per notebook.
    @ObservationIgnored private var uploading: [[URL]] = []
    @ObservationIgnored private var uploadPeak = 0
    @ObservationIgnored private var isBackground = false
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var backgroundEnd: Task<Void, Never>?
    @ObservationIgnored private var started = false

    private static let log = Logger(subsystem: "com.abhey.notespace", category: "backup")

    init(library: StoreLibrary, fixedRoot: URL? = nil) {
        self.library = library
        self.fixedRoot = fixedRoot
        if let fixedRoot {
            use(.url(fixedRoot))
        } else if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            use(.bookmark(data))
        }
        library.didChange = { [weak self] in self?.scheduleRun() }
    }

    var hasFolder: Bool {
        engine != nil
    }

    var isCopying: Bool {
        if case .copying = status {
            return true
        }
        return false
    }

    // MARK: Folder

    /// A folder picked in Files: bookmark it, back up there.
    func choose(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try BackupFolder.bookmark(for: url)
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            use(.bookmark(data))
            runNow()
        } catch {
            Self.log.error("bookmark: \(error.localizedDescription, privacy: .public)")
            status = .failed("Notespace can’t use that folder. Choose another one.")
        }
    }

    /// Stop Backing Up: forget the folder (what it holds stays).
    func stop() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        engine = nil
        folderName = nil
        catalog = nil
        debounceTask?.cancel()
        uploadTask?.cancel()
        uploading = []
        status = .off
        line = nil
    }

    private func use(_ folder: BackupFolder) {
        let url = folder.resolvedURL
        folderName = url.map(BackupFolder.displayName) ?? "Backup folder"
        folderShortName = url?.lastPathComponent ?? ""
        engine = BackupEngine(folder: folder, library: library.store, device: UIDevice.current.name, bookmarkRefreshed: { data in
            Task { @MainActor in UserDefaults.standard.set(data, forKey: Self.bookmarkKey) }
        })
        catalog = nil
        restored = []
        skipped = []
    }

    // MARK: Triggers

    /// After the library's first load: show the last backup, read the folder's catalog, catch up.
    func start() async {
        guard !started else { return }
        started = true
        guard let engine else { return }
        if let summary = try? await engine.summary() {
            status = .idle(summary)
        }
        await loadCatalog()
        runNow()
    }

    /// Library changed: run after the debounce (at once while in the background).
    func scheduleRun() {
        guard engine != nil else { return }
        if isBackground {
            return runNow()
        }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.runNow()
        }
    }

    /// The editor went away: run once its notebooks are flushed.
    func editorDidClose() {
        Task {
            await NotebookSession.closingFinished()
            runNow()
        }
    }

    /// Scene background: runs now, inside a background task, until the scene is back.
    func sceneDidEnterBackground() {
        isBackground = true
        guard engine != nil else { return }
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "backup") { [weak self] in
                self?.endBackgroundTask()
            }
        }
        runNow()
    }

    func sceneDidBecomeActive() {
        isBackground = false
        endBackgroundTask()
    }

    /// Back Up Now (and every trigger past its debounce).
    func runNow() {
        debounceTask?.cancel()
        guard let engine else { return }
        backgroundEnd?.cancel()
        if isRunning {
            runsAgain = true
            return
        }
        isRunning = true
        Task(priority: .utility) {
            repeat {
                runsAgain = false
                await run(engine)
            } while runsAgain && self.engine === engine
            isRunning = false
            if backgroundTask != .invalid {
                backgroundEnd = Task {
                    try? await Task.sleep(for: Self.backgroundGrace)
                    guard !Task.isCancelled else { return }
                    endBackgroundTask()
                }
            }
        }
    }

    private func run(_ engine: BackupEngine) async {
        runID += 1
        let id = runID
        do {
            let run = try await engine.run { progress in
                Task { @MainActor [weak self] in self?.show(progress, run: id) }
            }
            guard self.engine === engine else { return }
            runID += 1
            if run.notebooks > 0 {
                uploading += run.written
                await checkUploads(engine, summary: run.summary)
            } else if uploading.isEmpty {
                status = .idle(run.summary)
            }
        } catch {
            guard self.engine === engine else { return }
            runID += 1
            line = nil
            switch error {
            case .folderUnavailable:
                status = .folderUnavailable
            case let .failed(message):
                Self.log.error("backup: \(message, privacy: .public)")
                status = .failed(message)
            }
        }
    }

    private func show(_ progress: BackupEngine.Progress, run id: Int) {
        guard id == runID else { return }
        status = .copying(progress)
        lineTask?.cancel()
        let fraction = progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0
        line = .progress("Backing up \(progress.title) · \(progress.done + 1) of \(progress.total)", fraction: fraction)
    }

    /// Files still uploading → `uploading`, polled until done; then idle and "Backed up just now".
    private func checkUploads(_ engine: BackupEngine, summary: BackupSummary) async {
        let written = uploading
        let pending = await engine.pendingUploads(written)
        guard pending > 0 else {
            uploading = []
            uploadPeak = 0
            status = .idle(summary)
            return showDone()
        }
        uploadPeak = max(uploadPeak, pending)
        status = .uploading(pending: pending)
        line = .progress(
            "Uploading \(EditedLabel.notebooks(pending))", fraction: 1 - Double(pending) / Double(max(uploadPeak, 1))
        )
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.uploadPollInterval)
            guard !Task.isCancelled, let self, self.engine === engine, !isRunning else { return }
            await checkUploads(engine, summary: summary)
        }
    }

    private func showDone() {
        line = .done
        lineTask?.cancel()
        lineTask = Task { [weak self] in
            try? await Task.sleep(for: Self.doneLineDuration)
            guard !Task.isCancelled else { return }
            self?.line = nil
        }
    }

    private func endBackgroundTask() {
        backgroundEnd?.cancel()
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Restore

    /// Re-reads the folder's `library.json`.
    func loadCatalog() async {
        guard let engine else { return }
        do {
            catalog = try await engine.catalog()
        } catch {
            if error == .folderUnavailable {
                status = .folderUnavailable
            }
        }
    }

    /// Backed-up notebooks the library doesn't have, not deleted ones (the fresh-iPad card's count).
    var restorableCount: Int {
        catalog?.notebooks.count { !$0.trashed && rowState($0) == .restorable } ?? 0
    }

    func rowState(_ item: BackupCatalog.Notebook) -> RowState {
        if restored.contains(item.id) {
            return .restored
        }
        if restoring.contains(item.id) {
            return .restoring
        }
        if skipped.contains(item.id) || library.notebook(id: item.id) != nil {
            return .onThisIPad
        }
        return .restorable
    }

    /// Restores `items` one by one; each shows in the library as it lands. Local notebooks are never touched.
    func restore(_ items: [BackupCatalog.Notebook]) async {
        guard let engine, let catalog else { return }
        for item in items where rowState(item) == .restorable {
            restoring.insert(item.id)
            do {
                if try await engine.restore(item, from: catalog) {
                    restored.insert(item.id)
                    await library.reload()
                } else {
                    skipped.insert(item.id)
                }
            } catch {
                switch error {
                case .folderUnavailable: status = .folderUnavailable
                case let .failed(message): status = .failed(message)
                }
            }
            restoring.remove(item.id)
        }
    }

    /// Restore all (the fresh-iPad card, Restore's nav button): every notebook that isn't deleted.
    func restoreAll() async {
        await restore(catalog?.notebooks.filter { !$0.trashed } ?? [])
    }
}
