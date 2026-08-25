import Darwin
import Foundation

public enum SingleInstanceLockError: Error, Equatable, Sendable {
    case cannotCreateDirectory(Int32)
    case cannotOpen(Int32)
    case cannotSetCloseOnExec(Int32)
    case cannotLock(Int32)
}

/// Advisory lock（建议性文件锁）仅表示当前 App 的启动权，不写入 PID 或跨会话停止权。
public final class SingleInstanceLock: @unchecked Sendable {
    public let fileURL: URL
    private let descriptor: Int32

    private init(fileURL: URL, descriptor: Int32) {
        self.fileURL = fileURL
        self.descriptor = descriptor
    }

    deinit {
        _ = close(descriptor)
    }

    public static func acquire(
        bundleIdentifier: String,
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> SingleInstanceLock? {
        let root: URL
        if let rootDirectory {
            root = rootDirectory
        } else {
            root = try applicationSupportDirectory(fileManager: fileManager)
        }
        let directory = root.appendingPathComponent(bundleIdentifier, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw SingleInstanceLockError.cannotCreateDirectory(errno)
        }

        let fileURL = directory.appendingPathComponent("instance.lock", isDirectory: false)
        let descriptor = open(fileURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw SingleInstanceLockError.cannotOpen(errno)
        }

        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            let error = errno
            _ = close(descriptor)
            throw SingleInstanceLockError.cannotSetCloseOnExec(error)
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            return SingleInstanceLock(fileURL: fileURL, descriptor: descriptor)
        }

        let lockError = errno
        _ = close(descriptor)
        if lockError == EWOULDBLOCK || lockError == EAGAIN {
            return nil
        }
        throw SingleInstanceLockError.cannotLock(lockError)
    }

    private static func applicationSupportDirectory(fileManager: FileManager) throws -> URL {
        guard let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SingleInstanceLockError.cannotCreateDirectory(ENOENT)
        }
        return root
    }
}
