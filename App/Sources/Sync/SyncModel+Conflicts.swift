import Document
import Foundation
import InkModel
import Sync

/// Conflicts (#225, mock 05 C): a page this device had ink on was replaced by another device's version
/// written without seeing it. The editor shows the pill ("Replaced by the iPhone version · Keep mine · ×")
/// while that page is on screen, and the lost strokes as ghost ink under the page's ink.
///
/// - Keep mine: the editor writes the replaced version into the page itself (one undo step, checkpointed),
///   then the engine republishes that version's blob with a fresh clock and records it as the page's version
///   at the checkpoint's `rev` (``SyncEngine/keepMine(notebook:page:rev:)``), so the open editor shows it at
///   once and every device converges without waiting for the editor to close.
/// - × or 30 s after the pill first showed: the replaced version goes (``SyncEngine/dismissConflict(notebook:page:)``).
///
/// The list is the engine's (``SyncEngine/conflicts()``), loaded at launch and after a pull that reports new
/// ones; engine calls queue behind the running pass (``calls``).
extension SyncModel {
    /// How long a conflict's pill stays once shown.
    static let conflictWindow = Duration.seconds(30)

    /// Pending conflicts on `notebook`'s pages.
    func conflicts(in notebook: NotebookID) -> [Conflict] {
        conflicts.filter { $0.notebook == notebook }
    }

    /// The device whose version replaced the page, as the pill names it.
    func device(of conflict: Conflict) -> SyncDevice {
        let record = devicesByID[conflict.device]
        return SyncDevice(name: record?.name ?? "other device", model: record?.model)
    }

    /// The pill is on screen: the conflict goes in ``conflictWindow`` unless kept first.
    func conflictShown(_ conflict: Conflict) {
        let key = Self.key(conflict)
        guard conflictTimers[key] == nil else { return }
        conflictTimers[key] = Task { [weak self] in
            try? await Task.sleep(for: Self.conflictWindow)
            guard !Task.isCancelled else { return }
            self?.dismiss(conflict)
        }
    }

    /// Keep mine, after the editor wrote `conflict`'s replaced version into the page at `rev`.
    func keepMine(_ conflict: Conflict, rev: UInt64) {
        resolve(conflict) { engine throws(SyncError) in
            try await engine.keepMine(notebook: conflict.notebook, page: conflict.page, rev: rev)
        }
    }

    /// × or the 30 s: the replaced version goes.
    func dismiss(_ conflict: Conflict) {
        resolve(conflict) { engine throws(SyncError) in
            try await engine.dismissConflict(notebook: conflict.notebook, page: conflict.page)
        }
    }

    /// The replaced version's strokes and photos (read from the folder and decoded off main); `nil` if
    /// unreadable or not downloaded yet.
    func replacedContent(of conflict: Conflict) async -> PageContent? {
        guard let engine else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? engine.replacedStrokes(of: conflict) else { return nil }
            return try? StrokeCodec.decodeContent(data)
        }.value
    }

    /// Reads the engine's conflicts (behind any running pass).
    func loadConflicts() {
        enqueue { [weak self] engine in
            do throws(SyncError) {
                let loaded = try await engine.conflicts()
                guard let self, self.engine === engine else { return }
                conflicts = loaded
            } catch {
                self?.fail(error)
            }
        }
    }

    /// Runs `call` with the engine, one engine call at a time (``kick()``).
    func enqueue(_ call: @escaping @MainActor (SyncEngine) async -> Void) {
        calls.append(call)
        kick()
    }

    /// Takes `conflict` off screen now, then tells the engine.
    private func resolve(_ conflict: Conflict, _ call: @escaping @Sendable (SyncEngine) async throws(SyncError) -> Void) {
        let key = Self.key(conflict)
        conflictTimers.removeValue(forKey: key)?.cancel()
        conflicts.removeAll { Self.key($0) == key }
        enqueue { [weak self] engine in
            do throws(SyncError) {
                try await call(engine)
            } catch {
                self?.fail(error)
            }
        }
    }

    private static func key(_ conflict: Conflict) -> String {
        "\(conflict.notebook)/\(conflict.page)"
    }
}
