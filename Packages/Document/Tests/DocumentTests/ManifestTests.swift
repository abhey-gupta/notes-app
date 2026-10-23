import CoreGraphics
@testable import Document
import Foundation
import InkModel
import Testing

private func sampleManifest() -> Manifest {
    let pages = [PageID(), PageID(), PageID()]
    let notebook = Notebook(
        title: "Thermodynamics \u{1F525} / \"quoted\"",
        cover: .plum,
        paper: .dotted,
        theme: .night,
        keepsExactColors: true,
        pages: pages,
        createdAt: Date(timeIntervalSince1970: 1_792_000_000.123_456),
        rev: 42
    )
    return Manifest(notebook: notebook, entries: [
        PageEntry(id: pages[0], template: .lined(spacing: 24.5), rev: 7),
        PageEntry(id: pages[2], template: .cornell, rev: 1),
    ])
}

private func json(_ manifest: Manifest) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: manifest.encoded()) as? [String: Any])
}

struct ManifestTests {
    @Test func roundTripIsLosslessAndByteStable() throws {
        let manifest = sampleManifest()
        let data = try manifest.encoded()
        let decoded = try Manifest.decode(data)
        #expect(decoded == manifest)
        #expect(decoded.notebook.createdAt.unixMilliseconds == 1_792_000_000_123)
        #expect(try decoded.encoded() == data)
    }

    @Test func layoutIsFlatSortedAndHumanReadable() throws {
        let manifest = sampleManifest()
        let text = try #require(String(data: manifest.encoded(), encoding: .utf8))
        let topLevel = [
            "cover",
            "createdAt",
            "formatVersion",
            "id",
            "keepsExactColors",
            "modifiedAt",
            "pageSize",
            "pages",
            "paper",
            "rev",
            "theme",
            "title",
        ]
        let positions = try topLevel.map { key in try #require(text.range(of: "\n  \"\(key)\"")).lowerBound }
        #expect(positions == positions.sorted())
        let object = try json(manifest)
        #expect(Set(object.keys) == Set(topLevel))
        #expect(object["formatVersion"] as? Int == 2)
        #expect(object["createdAt"] as? Int64 == 1_792_000_000_123)
        #expect(object["cover"] as? String == "plum")
        #expect((object["pageSize"] as? [String: Double]) == ["width": 595, "height": 842])
        let pages = try #require(object["pages"] as? [[String: Any]])
        #expect(pages.map { $0["id"] as? String } == manifest.notebook.pages.map(\.description))
        #expect(pages.allSatisfy { $0["background"] == nil })
    }

    @Test func pagesWithoutEntriesGetPaperDefaults() {
        let manifest = sampleManifest()
        let middle = manifest.notebook.pages[1]
        #expect(manifest.entry(for: middle) == PageEntry(id: middle, template: PaperStyle.dotted.defaultTemplate))
        #expect(manifest.entry(for: PageID()) == nil)
        #expect(manifest.pages.map(\.rev) == [7, 0, 1])
    }

    @Test func pageMutations() throws {
        var manifest = sampleManifest()
        let ids = manifest.notebook.pages
        let new = PageEntry(id: PageID(), template: .grid(spacing: 10))
        try manifest.insertPage(new, at: 1)
        #expect(manifest.notebook.pages == [ids[0], new.id, ids[1], ids[2]])
        #expect(throws: DocumentError.duplicatePage(new.id)) { try manifest.insertPage(new, at: 0) }
        #expect(throws: DocumentError.pageIndexOutOfRange(9)) { try manifest.insertPage(PageEntry(id: PageID(), template: .blank), at: 9) }
        try manifest.movePage(from: 0, to: 3)
        #expect(manifest.notebook.pages == [new.id, ids[1], ids[2], ids[0]])
        #expect(throws: DocumentError.pageIndexOutOfRange(4)) { try manifest.movePage(from: 0, to: 4) }
        try manifest.removePage(ids[1])
        #expect(manifest.notebook.pages == [new.id, ids[2], ids[0]])
        #expect(throws: DocumentError.unknownPage(ids[1])) { try manifest.removePage(ids[1]) }
        #expect(throws: DocumentError.unknownPage(ids[1])) { try manifest.updateEntry(PageEntry(id: ids[1], template: .blank)) }
        #expect(try Manifest.decode(manifest.encoded()) == Manifest(notebook: manifest.notebook, entries: manifest.pages))
    }

    @Test func unknownKeysSurviveRoundTrip() throws {
        var object = try json(sampleManifest())
        object["syncState"] = ["cursor": "abc", "vector": [1, 2, 3], "nested": ["deep": NSNull()]]
        object["bigCounter"] = Int64.max
        object["ratio"] = 0.25
        object["flag"] = true
        var pages = try #require(object["pages"] as? [[String: Any]])
        pages[1]["ocr"] = ["lang": "en", "confidence": 0.9]
        pages[1]["pinned"] = false
        object["pages"] = pages
        let data = try JSONSerialization.data(withJSONObject: object)

        let manifest = try Manifest.decode(data)
        #expect(manifest.extra["bigCounter"] == .integer(.max))
        #expect(manifest.extra["ratio"] == .double(0.25))
        #expect(manifest.extra["flag"] == .bool(true))
        #expect(manifest.extra["syncState"] == .object([
            "cursor": .string("abc"),
            "vector": .array([.integer(1), .integer(2), .integer(3)]),
            "nested": .object(["deep": .null]),
        ]))
        let page = manifest.pages[1]
        #expect(page.extra == ["ocr": .object(["lang": .string("en"), "confidence": .double(0.9)]), "pinned": .bool(false)])

        let again = try Manifest.decode(manifest.encoded())
        #expect(again == manifest)
        #expect(try again.encoded() == manifest.encoded())
    }

    @Test func extraNeverShadowsKnownKeys() throws {
        var manifest = sampleManifest()
        manifest.extra = ["title": .string("hijack"), "x": .integer(1)]
        let object = try json(manifest)
        #expect(object["title"] as? String == manifest.notebook.title)
        #expect(object["x"] as? Int == 1)
    }

    @Test(arguments: [3, 99])
    func newerFormatIsRefusedWithClearMessage(version: Int) throws {
        // A future layout: nothing else is guaranteed to parse.
        let data = Data(#"{"formatVersion": \#(version), "notebook": {"renamed": true}}"#.utf8)
        #expect(throws: DocumentError.unsupportedFormatVersion(found: version, supported: 2)) { try Manifest.decode(data) }
        let message = DocumentError.unsupportedFormatVersion(found: version, supported: 2).localizedDescription
        #expect(message.contains("newer version of Notespace"))
    }

    @Test func corruptManifestsAreTyped() throws {
        let valid = try sampleManifest().encoded()
        var object = try json(sampleManifest())
        object["formatVersion"] = 0
        let versionZero = try JSONSerialization.data(withJSONObject: object)
        object["formatVersion"] = 1
        object["cover"] = "chartreuse"
        let badEnum = try JSONSerialization.data(withJSONObject: object)
        object["cover"] = "sage"
        var pages = try #require(object["pages"] as? [Any])
        pages.append(pages[0])
        object["pages"] = pages
        let duplicate = try JSONSerialization.data(withJSONObject: object)
        object.removeValue(forKey: "pages")
        let missing = try JSONSerialization.data(withJSONObject: object)

        for data in [Data(), Data("{".utf8), Data("[]".utf8), valid.prefix(valid.count / 2), versionZero, badEnum, duplicate, missing] {
            #expect {
                try Manifest.decode(data)
            } throws: { error in
                if case .corruptManifest = error as? DocumentError {
                    true
                } else {
                    false
                }
            }
        }
    }

    @Test func encodingRejectsDuplicatePageIDs() {
        var manifest = sampleManifest()
        let id = manifest.notebook.pages[0]
        manifest.notebook.pages.append(id)
        #expect(throws: DocumentError.duplicatePage(id)) { try manifest.encoded() }
    }
}
