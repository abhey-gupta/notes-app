import CoreGraphics
@testable import Document
import Foundation
import InkModel
import Testing

/// A PDF with one page per size; each page has a black square in its top-left quarter.
func makePDF(at url: URL, sizes: [CGSize]) throws {
    let context = try #require(CGContext(url as CFURL, mediaBox: nil, nil))
    for size in sizes {
        var box = CGRect(origin: .zero, size: size)
        let info = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
        context.beginPDFPage(info)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: size.height / 2, width: size.width / 2, height: size.height / 2))
        context.endPDFPage()
    }
    context.closePDF()
}

struct PDFImportTests {
    @Test func backgroundRoundTripsAndStaysOptional() throws {
        let ids = [PageID(), PageID()]
        let manifest = Manifest(notebook: Notebook(title: "PDF", pages: ids), entries: [
            PageEntry(id: ids[0], template: .blank, background: .pdf(file: "a.pdf", page: 3)),
        ])
        let data = try manifest.encoded()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains(#""background" : {"#) && text.contains(#""kind" : "pdf""#) && text.contains(#""page" : 3"#))
        #expect(text.components(separatedBy: "\"background\"").count == 2, "template pages omit it")
        let decoded = try Manifest.decode(data)
        #expect(decoded == manifest)
        #expect(decoded.pages[0].background == .pdf(file: "a.pdf", page: 3))
        #expect(decoded.pages[1].background == .template)
    }

    @Test(arguments: [#"{"kind":"pdf","file":"../x.pdf","page":0}"#, #"{"kind":"pdf","file":"a.pdf","page":-1}"#, #"{"kind":"image"}"#])
    func backgroundRejectsBadValues(_ json: String) {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PageBackground.self, from: Data(json.utf8)) }
    }

    @Test func createFromPDFCopiesFileAndMakesOnePagePerPDFPage() throws {
        try withTemporaryDirectory { dir in
            let pdf = dir.appending(path: "Lecture 4.pdf")
            try makePDF(at: pdf, sizes: [CGSize(width: 612, height: 792), CGSize(width: 842, height: 595), CGSize(width: 612, height: 792)])
            let notebook = Notebook(title: "Lecture 4", paper: .blank)
            let url = dir.appending(path: "n.nb")
            let package = try NotebookPackage.create(at: url, notebook: notebook, pdf: pdf)
            let pages = package.manifest.pages
            #expect(pages.count == 3)
            #expect(package.manifest.notebook.pageSize == CGSize(width: 612, height: 792))
            guard case let .pdf(file, 0) = pages[0].background else {
                Issue.record("page 1 has no PDF background")
                return
            }
            #expect(pages.map(\.background) == (0 ..< 3).map { .pdf(file: file, page: $0) })
            #expect(pages.allSatisfy { $0.template == .blank })
            #expect(try Data(contentsOf: package.backgroundURL(file)) == Data(contentsOf: pdf))
            #expect(try NotebookPackage.open(at: url).manifest == package.manifest)
            #expect(package.artwork().count == 3)
        }
    }

    @Test func createFromNonPDFFailsCleanly() throws {
        try withTemporaryDirectory { dir in
            let bogus = dir.appending(path: "x.pdf")
            try Data("not a pdf".utf8).write(to: bogus)
            let url = dir.appending(path: "n.nb")
            #expect(throws: DocumentError.unreadablePDF(bogus)) {
                try NotebookPackage.create(at: url, notebook: Notebook(title: "x"), pdf: bogus)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)) == ["x.pdf"])
        }
    }

    @Test func deletedPDFPageComesBackOnItsPDF() throws {
        try withTemporaryDirectory { dir in
            let pdf = dir.appending(path: "a.pdf")
            try makePDF(at: pdf, sizes: [CGSize(width: 595, height: 842), CGSize(width: 595, height: 842)])
            var package = try NotebookPackage.create(at: dir.appending(path: "n.nb"), notebook: Notebook(title: "a"), pdf: pdf)
            let page = package.manifest.pages[1]
            try package.deletePage(page.id)
            try package.insertPage(id: page.id, at: 1, template: .blank)
            #expect(package.manifest.pages[1].background == page.background)
            try package.insertPage(at: 2)
            #expect(package.manifest.pages[2].background == .template, "new pages are plain paper")
        }
    }

    @Test func notebookPageSizeKeepsSaneSizesAndFitsOthersToA4Width() {
        #expect(PDFSource.notebookPageSize(for: CGSize(width: 612, height: 792)) == CGSize(width: 612, height: 792))
        #expect(PDFSource.notebookPageSize(for: CGSize(width: 2384, height: 3370)) == CGSize(width: 595, height: 841))
        #expect(PDFSource.notebookPageSize(for: CGSize(width: 100, height: 50)) == CGSize(width: 595, height: 298))
        #expect(PDFSource.notebookPageSize(for: .zero) == Notebook.a4Portrait)
    }

    @Test func artworkFitsThePDFPageIntoThePage() throws {
        try withTemporaryDirectory { dir in
            let pdf = dir.appending(path: "a.pdf")
            // Landscape page into a portrait notebook page: letterboxed, centered.
            try makePDF(at: pdf, sizes: [CGSize(width: 200, height: 100)])
            let artwork = try PDFArtwork(source: #require(PDFSource(url: pdf)), pageIndex: 0)
            let size = CGSize(width: 100, height: 100)
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            // Page space: y down.
            context.translateBy(x: 0, y: 100)
            context.scaleBy(x: 1, y: -1)
            artwork.draw(in: context, size: size)
            let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            // Bitmap memory starts at the image's top row, so `row` counts from the page top.
            func red(x: Int, row: Int) -> UInt8 {
                bytes[row * 400 + x * 4]
            }
            // Fitted rect: y 25...75. Black square: top-left quarter of it (x 0...50, y 25...50).
            #expect(red(x: 10, row: 10) == 255, "white paper above the letterboxed page")
            #expect(red(x: 10, row: 35) == 0, "PDF's top-left square")
            #expect(red(x: 75, row: 35) == 255)
            #expect(red(x: 10, row: 65) == 255)
        }
    }
}
