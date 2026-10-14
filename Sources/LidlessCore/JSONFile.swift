import Darwin
import Foundation

public enum JSONFile {
    public enum Failure: Error { case missing, unsafe, tooLarge, unreadable }

    /// Reads a small JSON file and refuses symlinks, non-regular files, hard links and,
    /// when `owner` is given, files owned by anyone else.
    public static func read<T: Decodable>(_ type: T.Type, at path: String, owner: uid_t? = nil,
                                          maxBytes: Int = 8192) throws -> T {
        var info = stat()
        if lstat(path, &info) != 0 {
            throw errno == ENOENT ? Failure.missing : Failure.unreadable
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw Failure.unsafe }
        if let owner, info.st_uid != owner { throw Failure.unsafe }
        guard info.st_size <= maxBytes else { throw Failure.tooLarge }
        guard let data = FileManager.default.contents(atPath: path) else { throw Failure.unreadable }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Writes through a temporary file and rename, so readers never see half a file.
    public static func write<T: Encodable>(_ value: T, to path: String, mode: mode_t, sync: Bool = false) throws {
        let data = try JSONEncoder().encode(value)
        let directory = (path as NSString).deletingLastPathComponent
        let temp = directory + "/." + ((path as NSString).lastPathComponent) + ".\(getpid()).tmp"
        let fd = open(temp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw Failure.unreadable }
        var ok = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return buffer.count == 0 }
            return Darwin.write(fd, base, buffer.count) == buffer.count
        }
        if ok && fchmod(fd, mode) != 0 { ok = false }
        if ok && sync && fsync(fd) != 0 { ok = false }
        close(fd)
        guard ok, rename(temp, path) == 0 else {
            unlink(temp)
            throw Failure.unreadable
        }
        if sync {
            let dirFD = open(directory, O_RDONLY | O_DIRECTORY)
            if dirFD >= 0 { fsync(dirFD); close(dirFD) }
        }
    }

    public static func remove(_ path: String) {
        unlink(path)
    }

    public static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}
