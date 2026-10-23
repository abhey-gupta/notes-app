import Darwin
import Foundation
import InkModel

/// A page in memory plus its journal. Reference type so the actor mutates it in place.
final class LoadedPage {
    /// Page with every journaled edit applied.
    var page: Page
    /// Identity of the stroke file on disk (the base of any new journal).
    var base: StrokesIdentity
    let journal: JournalFile
    /// Differs from stroke file + manifest.
    var isDirty: Bool

    init(page: Page, base: StrokesIdentity, journal: JournalFile, isDirty: Bool) {
        self.page = page
        self.base = base
        self.journal = journal
        self.isDirty = isDirty
    }
}

/// One page's `.wal` file: created on first append after a checkpoint, appended with `pwrite` +
/// barrier sync, deleted by the next checkpoint. Owns its descriptor (closed on deinit).
final class JournalFile {
    let url: URL
    let directory: URL
    /// Bytes on disk (header + records); 0 = no file.
    private(set) var size = 0
    private var fd: Int32 = -1

    init(url: URL, directory: URL) {
        self.url = url
        self.directory = directory
    }

    deinit {
        if fd >= 0 {
            close(fd)
        }
    }

    /// The file's bytes, or `nil` if there is none.
    func read() throws(DocumentError) -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw .io(url, reason: "\(error)")
        }
    }

    /// Brings the file in line with a recovery of its `fileSize` bytes: cuts off a damaged tail and
    /// adopts the rest for appending, or deletes a stale / unusable file.
    /// - Returns: Bytes dropped.
    func settle(_ recovery: Journal.Recovery, fileSize: Int) throws(DocumentError) -> Int {
        switch recovery.disposition {
        case .none:
            return 0
        case let .keep(length):
            if length < fileSize {
                try truncate(to: length)
            }
            size = recovery.header == nil ? 0 : length
            return fileSize - length
        case .discard:
            try delete()
            return fileSize
        }
    }

    /// Appends one record, creating the file (with `header`) if there is none. Durable on return. On
    /// failure the file is cut back to its previous length so no torn record precedes later appends.
    func append(_ record: [UInt8], header: @autoclosure () -> Journal.Header) throws(DocumentError) {
        let creating = size == 0
        if creating {
            closeDescriptor()
            fd = try FileIO.open(url, O_WRONLY | O_CREAT | O_TRUNC)
        } else if fd < 0 {
            fd = try FileIO.open(url, O_WRONLY)
        }
        var status: Int32
        if creating {
            let bytes = Journal.encodeHeader(header()) + record
            status = bytes.withUnsafeBytes { FileIO.writeAll(fd, $0, at: 0) }
        } else {
            status = record.withUnsafeBytes { FileIO.writeAll(fd, $0, at: size) }
        }
        if status == 0 {
            status = FileIO.barrierSync(fd)
        }
        guard status == 0 else {
            if creating {
                closeDescriptor()
                try? FileIO.remove(url)
            } else {
                // Best effort. Even if this fails, the next append `pwrite`s at `size`, over the torn
                // bytes, and any leftover tail past the last good record is cut off on replay.
                _ = ftruncate(fd, off_t(size))
            }
            throw .io(url, reason: FileIO.message(status))
        }
        if creating {
            // Order the new directory entry ahead of later writes.
            FileIO.syncDirectory(directory)
            size = Journal.headerLength
        }
        size += record.count
    }

    /// Cuts a damaged tail off a recovered file.
    private func truncate(to length: Int) throws(DocumentError) {
        let fd = try FileIO.open(url, O_WRONLY)
        defer { close(fd) }
        guard ftruncate(fd, off_t(length)) == 0 else { throw .io(url, reason: FileIO.message(errno)) }
        _ = FileIO.barrierSync(fd)
    }

    /// Deletes the file (after a checkpoint, or when discarding a stale / unusable journal).
    func delete() throws(DocumentError) {
        closeDescriptor()
        size = 0
        try FileIO.remove(url)
    }

    private func closeDescriptor() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}
