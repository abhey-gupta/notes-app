import CoreGraphics
import Foundation
import InkModel
@testable import Library
import Testing

func entry(
    _ title: String,
    folder: FolderID? = nil,
    modified: TimeInterval = 1_800_000_000,
    created: TimeInterval = 1_700_000_000
) -> LibraryEntry {
    let id = NotebookID()
    return LibraryEntry(
        id: id, title: title, folderID: folder, cover: .plum, paper: .lined, theme: .white,
        createdAt: Date(timeIntervalSince1970: created), modifiedAt: Date(timeIntervalSince1970: modified),
        pageCount: 12, pageSize: Notebook.a4Portrait, packagePath: "\(id).nb", coverThumbnailPath: "\(id).nb/thumbs/cover.heic", rev: 7
    )
}

struct LibraryIndexTests {
    @Test func roundTrips() throws {
        let folder = LibraryFolder(name: "Physics")
        let index = LibraryIndex(
            notebooks: [entry("A", folder: folder.id), entry("B", modified: 1_800_000_100)],
            folders: [folder],
            trash: [TrashedNotebook(entry: entry("C"), trashedAt: Date(timeIntervalSince1970: 1_800_000_000.123))]
        )
        #expect(index.notebooks.map(\.title) == ["B", "A"])
        #expect(try LibraryIndex.decode(index.encoded()) == index)
    }

    @Test func jsonShape() throws {
        let e = entry("Shape")
        let json = try #require(try JSONSerialization.jsonObject(with: LibraryIndex(notebooks: [e]).encoded()) as? [String: Any])
        #expect(json["formatVersion"] as? Int == 1)
        let columns = try #require(json["notebooks"] as? [String: Any], "notebooks stored column-wise")
        #expect(columns["title"] as? [String] == ["Shape"])
        #expect(columns["modifiedAt"] as? [Int64] == [1_800_000_000_000], "dates are Unix ms")
        #expect(columns["packagePath"] as? [String] == ["\(e.id).nb"], "paths relative to the Notebooks root")
        #expect((columns["folderID"] as? [Any])?.first is NSNull)
    }

    @Test func toleratesUnknownAndMissingOptionalKeys() throws {
        let id = NotebookID()
        let json = """
        {"formatVersion":1,"addedLater":{"x":[1,2]},"notebooks":{"id":["\(id)"],"title":["Café"],"cover":["sage"],"paper":["grid"],
        "theme":["night"],"createdAt":[1],"modifiedAt":[2],"pageCount":[3],"pageWidth":[595],"pageHeight":[842],
        "packagePath":["\(id).nb"],"sparkle":[true]}}
        """
        let index = try LibraryIndex.decode(Data(json.utf8))
        let e = try #require(index.notebooks.first)
        #expect(e.id == id)
        #expect(e.title == "Café")
        #expect(e.theme == .night)
        #expect(e.folderID == nil)
        #expect(e.coverThumbnailPath == nil)
        #expect(e.rev == 0)
        #expect(e.modifiedAt == Date(timeIntervalSince1970: 0.002))
        #expect(e.pageSize == CGSize(width: 595, height: 842))
        #expect(index.folders.isEmpty)
        #expect(index.trash.isEmpty)
    }

    @Test func rejectsMismatchedColumnsAndUnknownValues() {
        let id = NotebookID()
        func index(title: String = "[\"A\"]", cover: String = "[\"sage\"]") -> Data {
            Data("""
            {"formatVersion":1,"notebooks":{"id":["\(id)"],"title":\(title),"cover":\(cover),"paper":["grid"],"theme":["night"],
            "createdAt":[1],"modifiedAt":[2],"pageCount":[3],"pageWidth":[595],"pageHeight":[842],"packagePath":["x.nb"]}}
            """.utf8)
        }
        #expect(throws: Never.self) { try LibraryIndex.decode(index()) }
        #expect(throws: LibraryError.self) { try LibraryIndex.decode(index(title: "[\"A\",\"B\"]")) }
        #expect(throws: LibraryError.self) { try LibraryIndex.decode(index(cover: "[\"chartreuse\"]")) }
    }

    @Test func rejectsGarbageWithTypedErrors() {
        for bad in ["", "[]", "{}", "{\"formatVersion\":0,\"notebooks\":[]}", "{\"formatVersion\":1,\"notebooks\":{}}"] {
            #expect(throws: LibraryError.self) { try LibraryIndex.decode(Data(bad.utf8)) }
        }
        #expect(throws: LibraryError.unsupportedFormatVersion(found: 2, supported: 1)) {
            try LibraryIndex.decode(Data("{\"formatVersion\":2}".utf8))
        }
    }
}

struct LibrarySearchTests {
    let entries = [
        entry("Café Notes", modified: 10),
        entry("cafe budget", modified: 20),
        entry("CAFÉ menu", modified: 30),
        entry("Thermodynamics", modified: 40),
        entry("Résumé", modified: 50),
    ]

    @Test func foldsCaseAndDiacritics() {
        #expect(Set(entries.filtered(matching: "cafe").map(\.title)) == ["Café Notes", "cafe budget", "CAFÉ menu"])
        #expect(Set(entries.filtered(matching: "CAFÉ").map(\.title)) == ["Café Notes", "cafe budget", "CAFÉ menu"])
        #expect(entries.filtered(matching: "resume").map(\.title) == ["Résumé"])
        #expect(entries.filtered(matching: " thermo ").map(\.title) == ["Thermodynamics"])
        #expect(entries.filtered(matching: "").count == entries.count)
        #expect(entries.filtered(matching: "xyz").isEmpty)
    }

    @Test func filtersByFolder() {
        let folder = FolderID()
        var items = entries
        items[1].folderID = folder
        items[3].folderID = folder
        #expect(items.filtered(folder: folder).map(\.title) == ["cafe budget", "Thermodynamics"])
        #expect(items.filtered(folder: folder, matching: "café").map(\.title) == ["cafe budget"])
    }

    @Test func sortsAndRecents() {
        var items = entries + [entry("Notebook 10", modified: 5), entry("Notebook 9", modified: 6)]
        items.shuffle()
        #expect(items.sorted(by: .recent).map(\.title).prefix(2) == ["Résumé", "Thermodynamics"])
        #expect(items.sorted(by: .title).map(\.title) == [
            "cafe budget", "CAFÉ menu", "Café Notes", "Notebook 9", "Notebook 10", "Résumé", "Thermodynamics",
        ])
        #expect(items.recents().count == 6)
        #expect(items.recents().first?.title == "Résumé")
        #expect(items.recents().last?.title == "Notebook 9")
        let index = LibraryIndex(notebooks: items)
        #expect(LibrarySnapshot(index: index).recents.map(\.title) == items.recents().map(\.title))
    }

    @Test func sortsByCreated() {
        let items = [entry("a", created: 1), entry("b", created: 3), entry("c", created: 2)]
        #expect(items.sorted(by: .created).map(\.title) == ["b", "c", "a"])
    }
}
