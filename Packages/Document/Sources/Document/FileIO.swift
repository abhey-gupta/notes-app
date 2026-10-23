import Darwin
import Foundation

/// Thin POSIX layer for the writes that must be durable: journal appends and checkpoint renames.
///
/// Durability primitive is `fcntl(F_BARRIERFSYNC)`: `fsync` (data handed to the drive) plus an I/O
/// barrier (nothing issued after it reaches media before what was issued before it). Same choice as
/// SQLite's WAL mode on Apple platforms. `F_FULLFSYNC` also flushes the drive cache but costs ~8× more;
/// see ``DocumentStore`` for the resulting guarantee.
enum FileIO {
    /// `errno` of a failed call, as a message.
    static func message(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    /// Opens `url` with `flags`; returns the descriptor or throws `.io`.
    static func open(_ url: URL, _ flags: Int32, mode: mode_t = 0o644) throws(DocumentError) -> Int32 {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, flags | O_CLOEXEC, mode)
        }
        guard fd >= 0 else { throw .io(url, reason: message(errno)) }
        return fd
    }

    /// Writes all of `bytes` at file offset `offset`, retrying short writes and `EINTR`.
    /// - Returns: `0`, or the `errno` that stopped it (some bytes may have been written).
    static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer, at offset: Int = 0) -> Int32 {
        guard var p = bytes.baseAddress else { return 0 }
        var left = bytes.count
        var position = off_t(offset)
        while left > 0 {
            let n = pwrite(fd, p, left, position)
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                return errno
            }
            p += n
            left -= n
            position += off_t(n)
        }
        return 0
    }

    /// `F_BARRIERFSYNC`, falling back to `fsync` where unsupported.
    /// - Returns: `0` or `errno`.
    static func barrierSync(_ fd: Int32) -> Int32 {
        if fcntl(fd, F_BARRIERFSYNC) == 0 {
            return 0
        }
        return fsync(fd) == 0 ? 0 : errno
    }

    /// Barrier-syncs a directory so entries created, renamed or unlinked in it are ordered on media.
    /// Best effort: failures are ignored (the data files themselves were already synced).
    static func syncDirectory(_ url: URL) {
        guard let fd = try? open(url, O_RDONLY) else { return }
        _ = barrierSync(fd)
        close(fd)
    }

    /// Size of the file at `url`, or `nil` if it does not exist.
    static func size(of url: URL) -> Int? {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return stat(path, &info)
        }
        return status == 0 ? Int(info.st_size) : nil
    }

    /// Unlinks `url`; a missing file is not an error.
    static func remove(_ url: URL) throws(DocumentError) {
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return EINVAL }
            return unlink(path) == 0 || errno == ENOENT ? 0 : errno
        }
        guard status == 0 else { throw .io(url, reason: message(status)) }
    }

    /// Writes `data` to a hidden temp file beside `url`, barrier-syncs it, then `rename`s it over `url`.
    /// A crash leaves either the old file or the new one, never a mix. The rename itself is ordered by
    /// the next barrier in the same directory (see ``syncDirectory(_:)``).
    static func writeAtomically(_ data: Data, to url: URL) throws(DocumentError) {
        let temp = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        let fd = try open(temp, O_WRONLY | O_CREAT | O_EXCL)
        var status = data.withUnsafeBytes { writeAll(fd, $0) }
        if status == 0 {
            status = barrierSync(fd)
        }
        close(fd)
        if status == 0 {
            status = temp.withUnsafeFileSystemRepresentation { from in
                url.withUnsafeFileSystemRepresentation { to in
                    guard let from, let to else { return EINVAL }
                    return rename(from, to) == 0 ? 0 : errno
                }
            }
        }
        guard status == 0 else {
            try? remove(temp)
            throw .io(url, reason: message(status))
        }
    }
}
