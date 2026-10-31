import Foundation
import InkModel
import Sync

/// Running passes (#225): one engine call at a time, progress on the title line, failures in Settings' footer.
extension SyncModel {
    /// Runs what is asked for, one engine call at a time: the editor's calls (``calls``), closed notebooks'
    /// deferred changes, then a pass, then (once per launch, after the first good pass) GC. The current engine
    /// each time: a folder chosen mid-run gets its own pass next.
    func kick() {
        guard started, engine != nil else { return }
        backgroundEnd?.cancel()
        guard !isRunning else { return }
        isRunning = true
        Task(priority: .utility) {
            while let engine, wantsPass || !closedNotebooks.isEmpty || !calls.isEmpty {
                if !calls.isEmpty {
                    await calls.removeFirst()(engine)
                    continue
                }
                if !closedNotebooks.isEmpty {
                    await applyDeferred(closedNotebooks.removeFirst(), engine)
                    continue
                }
                wantsPass = false
                if await pass(engine), !collectedGarbage {
                    collectedGarbage = true
                    await collectGarbage(engine)
                }
            }
            isRunning = false
            finishBackgroundSoon()
        }
    }

    /// One pull, then push. Returns whether it succeeded.
    func pass(_ engine: SyncEngine) async -> Bool {
        runID += 1
        let id = runID
        let adopts = library.notebooks.isEmpty
        let progress: @Sendable (SyncProgress) -> Void = { progress in
            Task { @MainActor [weak self] in self?.show(progress, run: id, adopting: adopts) }
        }
        do {
            await engine.setOpenNotebooks(openNotebooks)
            let pulled = try await adopts ? engine.adoptAll(progress: progress) : engine.pull(progress: progress)
            await library.reload()
            let pushed = try await engine.push(progress: progress)
            let devices = try await engine.devices()
            guard self.engine === engine else { return false }
            runID += 1
            endAdoption()
            lastSync = Date()
            deviceCount = Self.active(devices, me: engine.device.id).count
            devicesByID = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            landed(pulled, engine)
            if pushed.notebooks > 0 {
                uploading += pushed.written
                // Pull once more: whatever arrived while this pass sent.
                wantsPass = true
            }
            // Polling pauses during passes; any pass picks it up again.
            if !uploading.isEmpty {
                await checkUploads(engine)
            } else {
                status = .idle(summary)
                if let device = pulled.fromDevices.first, !pulled.applied.isEmpty {
                    showDone(.updated(from: device))
                } else if lineRun == id {
                    line = nil
                }
            }
            return true
        } catch {
            guard self.engine === engine else { return false }
            runID += 1
            line = nil
            endAdoption()
            fail(error)
            await library.reload()
            return false
        }
    }

    /// An editor closed: its notebook's deferred changes are written, then "Updated from ‹device›".
    func applyDeferred(_ id: NotebookID, _ engine: SyncEngine) async {
        do {
            let report = try await engine.applyDeferred(id)
            await library.reload()
            if let device = report.fromDevices.first, !report.applied.isEmpty {
                showDone(.updated(from: device))
            }
            landed(report, engine)
        } catch {
            fail(error)
        }
    }

    /// Once per launch: compact this device's log and delete what no device needs any more.
    func collectGarbage(_ engine: SyncEngine) async {
        do {
            let report = try await engine.gc()
            Self.log.info("sync gc: \(report.entries) entries, \(report.blobs) blobs")
        } catch {
            Self.log.error("sync gc: \(String(describing: error), privacy: .public)")
        }
    }

    var summary: SyncSummary {
        SyncSummary(last: lastSync, devices: deviceCount)
    }

    /// Shows a pass's failure in Settings' footer.
    func fail(_ error: SyncError) {
        switch error {
        case .folderUnavailable:
            status = .folderUnavailable
        case .newerFormat:
            status = .failed("This folder was synced by a newer Notespace. Update Notespace to keep syncing.")
        case let .failed(message):
            Self.log.error("sync: \(message, privacy: .public)")
            status = .failed(message)
        }
    }

    func show(_ progress: SyncProgress, run id: Int, adopting adopts: Bool) {
        guard id == runID else { return }
        lineRun = id
        lineTask?.cancel()
        switch progress.direction {
        case .sending:
            status = .sending(progress)
            line = .progress(
                "Sending \(progress.notebook) · \(EditedLabel.pages(progress.total))",
                fraction: Double(progress.done) / Double(max(progress.done + progress.total, 1))
            )
        case .receiving:
            status = .receiving(progress)
            let from = progress.device.map { "Updating from \($0)" } ?? "Updating \(progress.notebook)"
            line = .progress(
                "\(from) · \(progress.done) of \(EditedLabel.pages(progress.total))",
                fraction: Double(progress.done) / Double(max(progress.total, 1))
            )
            if adopts {
                adoptionEnd?.cancel()
                adoptionEnd = nil
                adoption = Adoption(
                    total: progress.notebooks, done: progress.notebooksDone, device: progress.device,
                    fraction: Double(progress.done) / Double(max(progress.total, 1))
                )
                // The library fills behind the card as notebooks land.
                Task { await library.reload() }
            }
        }
    }

    /// The adopt card shows "N of N" and goes after ``adoptionLinger`` (never just a flash).
    func endAdoption() {
        guard var adoption, adoptionEnd == nil else { return }
        adoption.done = adoption.total
        adoption.fraction = 1
        self.adoption = adoption
        adoptionEnd = Task { [weak self, adoptionLinger] in
            try? await Task.sleep(for: adoptionLinger)
            guard !Task.isCancelled, let self else { return }
            self.adoption = nil
            adoptionEnd = nil
        }
    }

    /// A pull wrote `report`'s notebooks: their cards say who sent them for 2 s; new conflicts load.
    func landed(_ report: PullReport, _ engine: SyncEngine) {
        var arrived: [NotebookID: SyncDevice] = [:]
        for (id, sender) in report.senders where sender != engine.device.id {
            let record = devicesByID[sender]
            arrived[id] = SyncDevice(name: record?.name ?? report.fromDevices.first ?? "another device", model: record?.model)
        }
        if !arrived.isEmpty {
            arrivals.merge(arrived) { _, new in new }
            arrivalsTask?.cancel()
            arrivalsTask = Task { [weak self, arrivalDuration] in
                try? await Task.sleep(for: arrivalDuration)
                guard !Task.isCancelled else { return }
                self?.arrivals = [:]
            }
        }
        if !report.conflicts.isEmpty {
            loadConflicts()
        }
    }

    /// "Synced just now" or "Updated from ‹device›" for 2 s, then the line folds away.
    func showDone(_ done: Line = .done) {
        line = done
        lineTask?.cancel()
        lineTask = Task { [weak self] in
            try? await Task.sleep(for: Self.doneLineDuration)
            guard !Task.isCancelled else { return }
            self?.line = nil
        }
    }
}
