import Foundation
import InkModel

/// Why a notebook package operation failed. Failed mutations leave the package and the in-memory
/// ``NotebookPackage/manifest`` unchanged (orphaned files aside).
public enum DocumentError: Error, Hashable, Sendable {
    /// The manifest or a stroke file was written by a newer Notespace. Never opened, never overwritten.
    case unsupportedFormatVersion(found: Int, supported: Int)
    /// `manifest.json` is not valid JSON or is missing/mistyped required fields.
    case corruptManifest(reason: String)
    /// A page's stroke file is damaged.
    case corruptPage(PageID, StrokeCodecError)
    /// A page holds more ink than ``StrokeCodec/maxBodyLength`` allows; not saved.
    case pageTooLarge(PageID)
    /// No page with this ID in the manifest.
    case unknownPage(PageID)
    /// The edit does not apply to the page's current strokes; nothing was journaled or changed.
    case invalidEdit(PageID, PageEditError)
    /// The page ID already exists (or appears twice in the manifest).
    case duplicatePage(PageID)
    /// Page index outside `0..<pageCount` (or `0...pageCount` for inserts).
    case pageIndexOutOfRange(Int)
    /// Something already exists at the target URL.
    case alreadyExists(URL)
    /// No package (or manifest) at the URL.
    case notFound(URL)
    /// File system failure at `url`.
    case io(URL, reason: String)
    /// Not a PDF CoreGraphics can open, password-protected, or without pages (PDF import, #119).
    case unreadablePDF(URL)
}

extension DocumentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unsupportedFormatVersion(found, supported):
            "This notebook was saved by a newer version of Notespace (format \(found); this version reads up to \(supported)). "
                + "Update Notespace to open it."
        case let .corruptManifest(reason):
            "The notebook's manifest is damaged (\(reason))."
        case let .corruptPage(id, error):
            "Page \(id) is damaged (\(error))."
        case let .pageTooLarge(id):
            "Page \(id) is too large to save."
        case let .unknownPage(id):
            "No page \(id) in this notebook."
        case let .invalidEdit(id, error):
            "The change to page \(id) could not be applied (\(error))."
        case let .duplicatePage(id):
            "Page \(id) already exists."
        case let .pageIndexOutOfRange(index):
            "Page index \(index) is out of range."
        case let .alreadyExists(url):
            "\(url.lastPathComponent) already exists."
        case let .notFound(url):
            "No notebook at \(url.path(percentEncoded: false))."
        case let .io(url, reason):
            "Could not access \(url.lastPathComponent): \(reason)"
        case let .unreadablePDF(url):
            "\(url.lastPathComponent) can't be opened as a PDF."
        }
    }
}

extension Date {
    /// Milliseconds since 1970, rounded: the manifest's date precision.
    var unixMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    /// Date from milliseconds since 1970.
    init(unixMilliseconds ms: Int64) {
        self.init(timeIntervalSince1970: Double(ms) / 1000)
    }

    /// This date rounded to the manifest's millisecond precision.
    var roundedToMilliseconds: Date {
        Date(unixMilliseconds: unixMilliseconds)
    }
}
