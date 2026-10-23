import Foundation
import InkModel
import os

/// Format migrations run when an older package is opened (ARCHITECTURE.md §4.5).
///
/// **v1 → v2** (#71: stroke files and journals gain PencilKit rendering data):
/// 1. Backup, once: `manifest.json` and `pages/` (stroke files and journals) are copied to
///    `backup-v1/` (staged in a hidden directory, then renamed; APFS clones, so it costs no space until
///    files diverge). An existing backup is kept as is.
/// 2. Every page with a stroke file or journal is loaded (journal replayed) and checkpointed: stroke
///    files rewritten as v2, then the manifest as v2 (one write, `modifiedAt` untouched), then the
///    journals deleted. A damaged stroke file is skipped (still v1, readable by v2; loading the page
///    reports the damage as before).
///
/// Crash-safe and idempotent: until the manifest says v2 the next open redoes the work (v2 decoders
/// read v1 files and v1 journals; a journal whose stroke file was already rewritten is stale and
/// discarded). v1 strokes get no rendering; renderers derive it from the pen profile, as v1 did.
enum Migrations {
    /// Directory (inside the package) holding the pre-migration copy for `version`.
    static func backupName(from version: Int) -> String {
        "backup-v\(version)"
    }

    private static let log = Logger(subsystem: "com.abhey.notespace", category: "doc")

    /// Migrates `package` (opened from an older-format manifest) to ``Manifest/formatVersion``.
    static func migrate(_ package: inout NotebookPackage) throws(DocumentError) {
        let from = package.manifest.sourceFormatVersion
        guard from < Manifest.formatVersion else { return }
        try backUp(package, from: from)
        let fm = FileManager.default
        var pages: [Page] = []
        var journals: [URL] = []
        for id in package.manifest.notebook.pages {
            let strokes = package.strokesURL(for: id)
            let journal = package.journalURL(for: id)
            let hasJournal = fm.fileExists(atPath: journal.path(percentEncoded: false))
            guard hasJournal || fm.fileExists(atPath: strokes.path(percentEncoded: false)) else { continue }
            let base: Page, identity: StrokesIdentity
            do {
                (base, identity) = try package.loadPageAndIdentity(id)
            } catch let .corruptPage(id, error) {
                // Left as is (v2 reads v1 files): loading the page reports the damage, as before.
                log.error("migration skipped damaged page \(id, privacy: .public): \(String(describing: error), privacy: .public)")
                continue
            }
            let file = JournalFile(url: journal, directory: package.pagesDirectory)
            let recovery = try Journal.recover(base, identity: identity, journal: file.read())
            pages.append(recovery.page)
            if hasJournal {
                journals.append(journal)
            }
        }
        _ = try package.checkpoint(pages, marksModified: false)
        for journal in journals {
            try? FileIO.remove(journal)
        }
        let name = package.url.lastPathComponent
        let count = pages.count
        log.info("migrated \(name, privacy: .public) v\(from) → v\(Manifest.formatVersion): \(count) pages")
    }

    /// Copies `manifest.json` and `pages/` to `backup-v<from>/` unless that backup exists.
    private static func backUp(_ package: NotebookPackage, from: Int) throws(DocumentError) {
        let fm = FileManager.default
        let backup = package.url.appending(path: backupName(from: from), directoryHint: .isDirectory)
        guard !fm.fileExists(atPath: backup.path(percentEncoded: false)) else { return }
        let staging = package.url.appending(path: ".\(backupName(from: from)).staging", directoryHint: .isDirectory)
        do {
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            try fm.copyItem(at: package.manifestURL, to: staging.appending(path: "manifest.json", directoryHint: .notDirectory))
            if fm.fileExists(atPath: package.pagesDirectory.path(percentEncoded: false)) {
                try fm.copyItem(at: package.pagesDirectory, to: staging.appending(path: "pages", directoryHint: .isDirectory))
            }
            try fm.moveItem(at: staging, to: backup)
            FileIO.syncDirectory(package.url)
        } catch {
            try? fm.removeItem(at: staging)
            throw .io(backup, reason: "backup before migration failed: \(error)")
        }
    }
}
