import Foundation
import InkModel
import Sync
import UIKit

/// When passes run (#225): library changes, the editor, the scene, the folder's presenter, a 30 s poll; and
/// upload tracking after a pass that sent something.
extension SyncModel {
    static let presenterDebounce = Duration.seconds(3)
    static let pollInterval = Duration.seconds(30)
    static let uploadPollInterval = Duration.seconds(3)
    /// After the last background pass, how long the background task waits for more changes (late flushes).
    static let backgroundGrace = Duration.seconds(3)

    /// After the library's first load: show the last state, then catch up (an empty library adopts).
    func start() async {
        guard !started else { return }
        started = true
        guard let engine else { return }
        if let devices = try? await engine.devices() {
            devicesByID = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            deviceCount = Self.active(devices, me: engine.device.id).count
            lastSync = devices.first { $0.id == engine.device.id }?.lastSeen
            status = .idle(summary)
        }
        loadConflicts()
        syncNow()
    }

    /// Sync Now (and every trigger past its debounce).
    func syncNow() {
        debounceTask?.cancel()
        wantsPass = true
        kick()
    }

    /// Library changed: sync after the debounce (at once while in the background).
    func scheduleSync() {
        guard engine != nil else { return }
        if isBackground {
            return syncNow()
        }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    /// The editor went away: sync once its notebooks are flushed (their deferred changes are written first,
    /// ``openNotebooksChanged(_:)``).
    func editorDidClose() {
        Task {
            await NotebookSession.closingFinished()
            syncNow()
        }
    }

    /// Editors opened or closed notebooks (any window). The engine learns at once, in order; closed ones get
    /// their deferred changes written.
    func openNotebooksChanged(_ ids: Set<NotebookID>) {
        let closed = openNotebooks.subtracting(ids)
        openNotebooks = ids
        for id in closed {
            engine?.didClose(id)
        }
        if let engine {
            let previous = openUpdate
            openUpdate = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                await engine.setOpenNotebooks(openNotebooks)
            }
        }
        closedNotebooks += closed.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
        kick()
    }

    // MARK: Scene

    /// Scene background: sync now, inside a background task, until the scene is back. The presenter goes
    /// (a suspended app must not present files) and polling pauses.
    func sceneDidEnterBackground() {
        isBackground = true
        removePresenter()
        guard engine != nil else { return }
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "sync") { [weak self] in
                self?.endBackgroundTask()
            }
        }
        syncNow()
    }

    /// Scene foreground: pull what other devices sent meanwhile.
    func sceneDidBecomeActive() {
        let wasBackground = isBackground
        isBackground = false
        endBackgroundTask()
        guard engine != nil else { return }
        if presenter == nil {
            addPresenter()
        }
        if wasBackground {
            syncNow()
        }
    }

    /// Every 30 s while in the foreground: list the folder's logs (the presenter doesn't fire for every provider).
    func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self else { return }
                if !isBackground, engine != nil {
                    syncNow()
                }
            }
        }
    }

    func finishBackgroundSoon() {
        guard backgroundTask != .invalid else { return }
        backgroundEnd = Task {
            try? await Task.sleep(for: Self.backgroundGrace)
            guard !Task.isCancelled else { return }
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        backgroundEnd?.cancel()
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Presenter

    func addPresenter() {
        guard let folder, presenter == nil else { return }
        presenter = FolderPresenter(folder: folder) { [weak self] in
            Task { @MainActor in self?.folderDidChange() }
        }
    }

    func removePresenter() {
        presenter?.remove()
        presenter = nil
    }

    /// Files arrived or changed in the folder: pull after things settle (also fires for this device's writes;
    /// that pass finds nothing new).
    private func folderDidChange() {
        presenterDebounce?.cancel()
        presenterDebounce = Task { [weak self] in
            try? await Task.sleep(for: Self.presenterDebounce)
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    // MARK: Uploads

    /// Files still uploading → `uploading`, polled until done; then idle and "Synced just now".
    func checkUploads(_ engine: SyncEngine) async {
        let written = uploading
        let pending = await Self.pendingNotebooks(written, folder: engine.folder)
        guard pending > 0 else {
            // A pass may have added files while this check was out.
            uploading.removeFirst(min(written.count, uploading.count))
            guard uploading.isEmpty else { return await checkUploads(engine) }
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
            await checkUploads(engine)
        }
    }

    /// Notebooks with files in `urls` not uploaded yet (`blobs/<notebook>/…`; log and device files count as
    /// one), off main and inside the folder's scope.
    private nonisolated static func pendingNotebooks(_ urls: [URL], folder: SyncFolder) async -> Int {
        await Task.detached(priority: .utility) {
            guard let scope = try? folder.beginAccess() else { return 0 }
            defer { scope.end() }
            var pending: Set<String> = []
            for url in urls where !CoordinatedFileSystem.isUploaded([url]) {
                let components = url.pathComponents
                if let i = components.lastIndex(of: SyncLayout.blobs), i + 1 < components.count {
                    pending.insert(components[i + 1])
                } else {
                    pending.insert("")
                }
            }
            return pending.count
        }.value
    }
}
