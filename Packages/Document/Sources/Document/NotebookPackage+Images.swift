import Foundation
import InkModel

/// Photo bytes in the package (#157): `images/<asset>.heic`, written once before the edit that places the
/// image and never rewritten; an asset may be placed on several pages (duplicates share it).
public extension NotebookPackage {
    /// `images/`.
    var imagesDirectory: URL {
        Self.imagesDirectory(in: url)
    }

    /// `images/` of the package at `url`.
    static func imagesDirectory(in url: URL) -> URL {
        url.appending(path: "images", directoryHint: .isDirectory)
    }

    /// `images/<asset>.heic`: the bytes of an image placed on a page (#157).
    func imageURL(for asset: ImageAssetID) -> URL {
        Self.imageURL(for: asset, in: url)
    }

    /// `images/<asset>.heic` of the package at `url` (for renderers that don't open the package).
    static func imageURL(for asset: ImageAssetID, in url: URL) -> URL {
        imagesDirectory(in: url).appending(path: "\(asset).heic", directoryHint: .notDirectory)
    }

    /// Writes an image asset's bytes (HEIC) atomically. Assets are immutable: writing one that exists is a
    /// no-op. Not journaled; call it before the edit that places the image, so the bytes are on disk first.
    func writeImage(_ data: Data, asset: ImageAssetID) throws(DocumentError) {
        let file = imageURL(for: asset)
        guard !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        } catch {
            throw .io(imagesDirectory, reason: "\(error)")
        }
        try Self.writeAtomically(data, to: file)
        FileIO.syncDirectory(imagesDirectory)
    }
}
