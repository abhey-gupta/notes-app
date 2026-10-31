@testable import Backup
import Document
import Foundation
import InkModel
import Library
import Testing

/// The engine against a temp folder (#174): what a run copies, moves and deletes, `library.json`, Restore.
struct BackupEngineTests {
    @Test func firstRunCopiesWhatABackupHoldsThenNothing() async throws {
        let b = try TempBackup()
        let physics = try await b.store.createFolder(named: "Physics")
        let a = try await b.store.create(notebook("Thermodynamics", pages: 2), in: physics.id)
        let c = try await b.store.create(notebook("Sketches"))
        let asset = ImageAssetID()
        try b.package(a).writeImage(Data("photo".utf8), asset: asset)
        try b.ink(a, page: 0, images: [PageImage(asset: asset, frame: CGRect(x: 0, y: 0, width: 10, height: 10))])
        let package = try b.package(a)
        let (page1, page2) = (package.manifest.pages[0].id, package.manifest.pages[1].id)
        try Data("cover".utf8).write(to: package.coverThumbnailURL)
        try Data("thumb".utf8).write(to: package.thumbnailURL(for: page1))
        try Data("wal".utf8).write(to: package.journalURL(for: page2))

        let run = try await b.engine().run()
        #expect(run.notebooks == 2)
        let remote = "Notebooks/\(a.id).nb"
        for file in ["manifest.json", "pages/\(page1).strokes", "images/\(asset).heic", "thumbs/cover.heic"] {
            #expect(b.exists(b.remote("\(remote)/\(file)")), "\(file)")
        }
        for file in ["pages/\(page2).strokes", "pages/\(page2).wal", "thumbs/\(page1).heic"] {
            #expect(!b.exists(b.remote("\(remote)/\(file)")), "never \(file)")
        }
        #expect(try Data(contentsOf: b.remote("\(remote)/manifest.json")) == Data(contentsOf: package.manifestURL))
        #expect(b.exists(b.remote("Notebooks/\(c.id).nb/manifest.json")))

        let catalog = try b.catalog()
        #expect(Set(catalog.notebooks.map(\.id)) == [a.id, c.id])
        #expect(catalog.folders == [physics])
        let item = try #require(catalog.notebooks.first { $0.id == a.id })
        #expect(item.title == "Thermodynamics" && item.folderID == physics.id && item.pageCount == 2 && !item.trashed)
        #expect(item.rev == package.manifest.notebook.rev)
        #expect(catalog.device == "Test iPad")
        #expect(run.summary.notebooks == 2 && run.summary.bytes > 0 && run.summary.last != nil)

        let again = try await b.engine().run()
        #expect(again.notebooks == 0 && again.written.isEmpty, "nothing changed")
    }

    @Test func editingOnePageCopiesItsStrokesAndTheManifestOnly() async throws {
        let b = try TempBackup()
        let a = try await b.store.create(notebook("A", pages: 3))
        _ = try await b.store.create(notebook("B"))
        try b.ink(a, page: 0)
        try b.ink(a, page: 1)
        let engine = b.engine()
        try await engine.run()
        try b.ink(a, page: 1)
        try await b.store.refresh(a.id)

        let run = try await engine.run()
        let page = try b.package(a).manifest.pages[1].id
        #expect(run.notebooks == 1)
        #expect(b.relative(run.written) == [
            ["Notebooks/\(a.id).nb/pages/\(page).strokes", "Notebooks/\(a.id).nb/manifest.json"],
            ["library.json"],
        ])
        #expect(try Data(contentsOf: b.remote("Notebooks/\(a.id).nb/pages/\(page).strokes"))
            == Data(contentsOf: b.package(a).strokesURL(for: page)))
    }

    @Test func deletedPageLosesItsRemoteStrokes() async throws {
        let b = try TempBackup()
        let a = try await b.store.create(notebook("A", pages: 2))
        try b.ink(a, page: 0)
        let engine = b.engine()
        try await engine.run()
        var package = try b.package(a)
        let page = package.manifest.pages[0].id
        #expect(b.exists(b.remote("Notebooks/\(a.id).nb/pages/\(page).strokes")))
        try package.deletePage(page)
        try await engine.run()
        #expect(!b.exists(b.remote("Notebooks/\(a.id).nb/pages/\(page).strokes")))
        #expect(try Data(contentsOf: b.remote("Notebooks/\(a.id).nb/manifest.json")) == Data(contentsOf: package.manifestURL))
    }

    @Test func photoIsCopiedOnce() async throws {
        let b = try TempBackup()
        let a = try await b.store.create(notebook("A"))
        let engine = b.engine()
        try await engine.run()
        let asset = ImageAssetID()
        try b.package(a).writeImage(Data("photo".utf8), asset: asset)
        try b.ink(a, page: 0, images: [PageImage(asset: asset, frame: CGRect(x: 0, y: 0, width: 10, height: 10))])
        let first = try await engine.run()
        #expect(b.relative(first.written).first?.contains("Notebooks/\(a.id).nb/images/\(asset).heic") == true)
        try b.ink(a, page: 0)
        let second = try await engine.run()
        #expect(second.notebooks == 1)
        #expect(b.relative(second.written).first?.contains { $0.contains("images/") } == false, "assets are immutable")
    }

    @Test func coverChangeCopiesTheCoverOnly() async throws {
        let b = try TempBackup()
        let a = try await b.store.create(notebook("A"))
        let engine = b.engine()
        try await engine.run()
        let cover = try b.package(a).coverThumbnailURL
        try FileManager.default.createDirectory(at: cover.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cover 1".utf8).write(to: cover)
        let run = try await engine.run()
        #expect(b.relative(run.written) == [["Notebooks/\(a.id).nb/thumbs/cover.heic"]])
        try FileManager.default.removeItem(at: cover)
        try await engine.run()
        #expect(!b.exists(b.remote("Notebooks/\(a.id).nb/thumbs/cover.heic")))
    }

    @Test func trashRestoreAndPurgeFollowTheLibrary() async throws {
        let b = try TempBackup()
        let a = try await b.store.create(notebook("A"))
        let engine = b.engine()
        try await engine.run()
        let (live, trashed) = (b.remote("Notebooks/\(a.id).nb"), b.remote("Trash/\(a.id).nb"))

        try await b.store.delete(a.id)
        try await engine.run()
        #expect(!b.exists(live) && b.exists(trashed))
        #expect(try b.catalog().notebooks.map(\.trashed) == [true])

        try await b.store.restore(a.id)
        try await engine.run()
        #expect(b.exists(live) && !b.exists(trashed))
        #expect(try b.catalog().notebooks.map(\.trashed) == [false])

        try await b.store.delete(a.id)
        try await b.store.purgeTrash(now: Date().addingTimeInterval(31 * 86400))
        try await engine.run()
        #expect(!b.exists(live) && !b.exists(trashed))
        #expect(try b.catalog().notebooks.isEmpty)
    }

    @Test func freshLibraryRestoresNotebooksAndFoldersFromTheBackup() async throws {
        let old = try TempBackup()
        let university = try await old.store.createFolder(named: "University")
        let physics = try await old.store.createFolder(named: "Physics", in: university.id)
        let a = try await old.store.create(notebook("Thermodynamics", pages: 2), in: physics.id)
        try old.ink(a, page: 0)
        try Data("cover".utf8).write(to: old.package(a).coverThumbnailURL)
        try await old.engine(device: "Old iPad").run()

        let fresh = try TempBackup(folder: old.folder)
        let engine = fresh.engine(device: "New iPad")
        try await engine.run()
        let catalog = try #require(try await engine.catalog())
        #expect(catalog.notebooks.map(\.id) == [a.id], "a fresh library doesn't drop what it hasn't backed up")
        #expect(catalog.device == "Old iPad", "and leaves library.json alone")

        let item = try #require(catalog.notebooks.first)
        #expect(try await engine.restore(item, from: catalog))
        let snapshot = await fresh.store.snapshot()
        let entry = try #require(snapshot.notebook(a.id))
        #expect(entry.folderID == physics.id)
        #expect(snapshot.folders == [university, physics])
        #expect(entry.coverThumbnailPath != nil)
        let restored = try fresh.package(entry)
        #expect(try restored.manifest == old.package(a).manifest)
        #expect(try restored.loadPage(at: 0).strokes.count == 1)
        #expect(try await engine.restore(item, from: catalog) == false, "never replaces a local notebook")
        let staged = try FileManager.default.contentsOfDirectory(atPath: fresh.locations.notebooksDirectory.path(percentEncoded: false))
        #expect(staged == ["\(a.id).nb"], "no staging left behind")
    }

    @Test func unavailableFolder() async throws {
        let b = try TempBackup()
        let missing = b.root.appending(path: "Gone", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        let bookmark = try BackupFolder.bookmark(for: missing)
        try FileManager.default.removeItem(at: missing)
        for folder in [BackupFolder.bookmark(Data("not a bookmark".utf8)), .bookmark(bookmark), .url(missing)] {
            let engine = BackupEngine(folder: folder, library: b.store, device: "iPad")
            await #expect(throws: BackupError.folderUnavailable) { try await engine.run() }
        }
    }

    @Test func corruptStateCopiesEverythingAgain() async throws {
        let b = try TempBackup()
        let a = try await b.store.create(notebook("A"))
        let c = try await b.store.create(notebook("C"))
        try b.ink(a, page: 0)
        let engine = b.engine()
        try await engine.run()
        try Data("{ damaged".utf8).write(to: engine.stateURL)
        try b.ink(c, page: 0)

        let run = try await engine.run()
        #expect(run.notebooks == 2)
        for entry in [a, c] {
            let package = try b.package(entry)
            let page = package.manifest.pages[0].id
            #expect(try Data(contentsOf: b.remote("Notebooks/\(entry.id).nb/pages/\(page).strokes")) ==
                Data(contentsOf: package.strokesURL(for: page)))
        }
        #expect(try Set(b.catalog().notebooks.map(\.id)) == [a.id, c.id])
        #expect(try await engine.run().notebooks == 0, "state rewritten")
    }

    @Test func remotePackageDeletedInFilesIsCopiedAgain() async throws {
        let b = try TempBackup()
        let a = try await b.store.create(notebook("A"))
        let engine = b.engine()
        try await engine.run()
        try FileManager.default.removeItem(at: b.remote("Notebooks/\(a.id).nb"))
        #expect(try await engine.run().notebooks == 1)
        #expect(b.exists(b.remote("Notebooks/\(a.id).nb/manifest.json")))
    }
}

struct BackupPlannerTests {
    @Test func moveComesFirstAndManifestLast() throws {
        let entry = LibraryEntry(manifest: Manifest(notebook: notebook("A")), packagePath: "a.nb")
        let id = entry.id
        let state = BackupState(destination: "/b", notebooks: [id: .empty(at: .notebooks)])
        var local = LocalNotebook(
            entry: entry, location: .trash, packageURL: URL(filePath: "/lib/a.nb"), manifestModified: Date(), cover: FileStamp(
                modified: Date(),
                size: 3
            )
        )
        local.contents = .init(manifest: Manifest(notebook: Notebook(id: id, title: "A")), files: ["manifest.json": 10, "images/x.heic": 5])
        let plans = BackupPlanner.plan(local: [local], state: state, remote: RemoteListing(notebooks: [id]))
        let operations = try #require(plans.first?.operations)
        #expect(operations.first == .move("Notebooks/\(id).nb", to: "Trash/\(id).nb"))
        #expect(operations.last == .copy(URL(filePath: "/lib/a.nb/manifest.json"), to: "Trash/\(id).nb/manifest.json", bytes: 10))
        #expect(operations.count == 4, "move, photo, cover, manifest")
        #expect(plans.first?.state?.bytes == 18)
    }

    @Test func unreadablePackageIsLeftAloneNotDeleted() {
        let entry = LibraryEntry(manifest: Manifest(notebook: notebook("A")), packagePath: "a.nb")
        let known = BackupState.Notebook.empty(at: .notebooks)
        let state = BackupState(destination: "/b", notebooks: [entry.id: known])
        let local = LocalNotebook(entry: entry, location: .notebooks, packageURL: URL(filePath: "/lib/a.nb"), manifestModified: nil)
        #expect(BackupPlanner.plan(local: [local], state: state, remote: RemoteListing(notebooks: [entry.id])).isEmpty)
    }

    @Test func folderNamesShowTheProvider() {
        let icloud = URL(
            filePath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Notespace",
            directoryHint: .isDirectory
        )
        #expect(BackupFolder.displayName(for: icloud) == "iCloud Drive › Notespace")
        #expect(BackupFolder.displayName(for: URL(filePath: "/x/File Provider Storage/Backups", directoryHint: .isDirectory)) == "Backups")
    }
}
