import CryptoKit
import Foundation

/// 用户主动下载完成后的最小结果。文件仍在 Downloads（下载）目录；调用方必须在
/// 另一次明确的用户操作中才可打开、挂载或交给 Finder（访达）。
public struct AppReleaseDownloadResult: Equatable, Sendable {
    public let fileURL: URL
    public let sha256: String

    public init(fileURL: URL, sha256: String) {
        self.fileURL = fileURL
        self.sha256 = sha256
    }
}

public enum AppReleaseDownloadError: Error, Equatable, LocalizedError, Sendable {
    case updateNotAvailable
    case missingDownloadURL
    case missingChecksumURL
    case checksumUnavailable(statusCode: Int)
    case invalidChecksumFile
    case checksumResponseTooLarge
    case untrustedRedirect(String)
    case tooManyRedirects
    case requestFailed(statusCode: Int)
    case requestTimedOut
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case downloadsDirectoryUnavailable
    case fileOperationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .updateNotAvailable:
            "当前 Release 结果不是可下载的较新版本。"
        case .missingDownloadURL:
            "Release 没有可用的 DMG 下载地址。"
        case .missingChecksumURL:
            "Release 没有可用的 SHA-256 校验文件地址。"
        case let .checksumUnavailable(statusCode):
            "该 Release 尚未提供 SHA-256 校验文件（HTTP \(statusCode)），为避免下载未经校验的文件，已停止下载。"
        case .invalidChecksumFile:
            "Release 的 SHA-256 校验文件格式或目标文件名不正确。"
        case .checksumResponseTooLarge:
            "Release 的 SHA-256 校验文件异常过大，已停止读取。"
        case let .untrustedRedirect(url):
            "下载地址跳转到了不受信任的位置：\(url)"
        case .tooManyRedirects:
            "下载地址跳转次数过多，已停止下载。"
        case let .requestFailed(statusCode):
            "下载服务器返回 HTTP \(statusCode)。"
        case .requestTimedOut:
            "下载请求超时。"
        case let .downloadFailed(message):
            "下载失败：\(message)"
        case let .checksumMismatch(expected, actual):
            "下载文件的 SHA-256 不匹配（期望 \(expected)，实际 \(actual)），已删除临时文件。"
        case .downloadsDirectoryUnavailable:
            "无法定位 Downloads（下载）目录。"
        case let .fileOperationFailed(message):
            "无法安全写入下载文件：\(message)"
        }
    }
}

/// 明确用户操作可取消一次下载。它只保留本次 URLSession 请求的取消回调，不保存 URL、
/// Cookie、文件内容或下载历史；调用 `cancel()` 不会影响此前完成的文件。
public final class AppReleaseDownloadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var actions: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    public func cancel() {
        let pending = lock.withLock { () -> [@Sendable () -> Void] in
            cancelled = true
            defer { actions.removeAll() }
            return Array(actions.values)
        }
        pending.forEach { $0() }
    }

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    fileprivate func register(_ action: @escaping @Sendable () -> Void) -> UUID? {
        let identifier = UUID()
        let shouldCancelImmediately = lock.withLock { () -> Bool in
            guard !cancelled else { return true }
            actions[identifier] = action
            return false
        }
        if shouldCancelImmediately {
            action()
            return nil
        }
        return identifier
    }

    fileprivate func unregister(_ identifier: UUID?) {
        guard let identifier else { return }
        _ = lock.withLock {
            actions.removeValue(forKey: identifier)
        }
    }
}

/// 只服务于 App 自身固定 GitHub Release 的一次性下载器。它不枚举目录、不覆盖既有
/// 文件、不挂载 DMG，也不安装或替换正在运行的 App。
public struct AppReleaseDownloadService: Sendable {
    private static let checksumBodyLimit = 16 * 1_024
    private static let requestTimeout: TimeInterval = 30
    private static let resourceTimeout: TimeInterval = 15 * 60
    private let makeSessionConfiguration: @Sendable (TimeInterval, TimeInterval) -> URLSessionConfiguration

    public init() {
        makeSessionConfiguration = { requestTimeout, resourceTimeout in
            UpdateNetworkPolicy.makeEphemeralConfiguration(
                requestTimeout: requestTimeout,
                resourceTimeout: resourceTimeout
            )
        }
    }

    /// 仅供同一 Swift Package 的受控验证注入 URLProtocol（URL 协议夹具）。生产构造器
    /// 始终使用无 Cookie、无凭据缓存的临时会话，外部调用方不能替换网络策略。
    package init(
        makeSessionConfiguration: @escaping @Sendable (TimeInterval, TimeInterval) -> URLSessionConfiguration
    ) {
        self.makeSessionConfiguration = makeSessionConfiguration
    }

    public func download(
        check: AppUpdateCheck,
        downloadsDirectory: URL? = nil,
        cancellation: AppReleaseDownloadCancellation? = nil,
        progress: @escaping @Sendable (Double?) -> Void = { _ in }
    ) async throws -> AppReleaseDownloadResult {
        if cancellation?.isCancelled == true {
            throw CancellationError()
        }
        guard check.disposition == .updateAvailable else {
            throw AppReleaseDownloadError.updateNotAvailable
        }
        let (downloadURL, _) = try Self.fixedReleaseURLs(for: check)

        let filename = AppUpdateService.assetFilename(for: check.latestVersion)
        let expectedChecksum = try await verifiedChecksum(for: check, cancellation: cancellation)
        if cancellation?.isCancelled == true {
            throw CancellationError()
        }

        let fileManager = FileManager.default
        let directory: URL
        if let downloadsDirectory {
            directory = downloadsDirectory.standardizedFileURL
        } else if let defaultDirectory = fileManager.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first {
            directory = defaultDirectory.standardizedFileURL
        } else {
            throw AppReleaseDownloadError.downloadsDirectoryUnavailable
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw AppReleaseDownloadError.fileOperationFailed(error.localizedDescription)
        }

        let partURL = directory.appendingPathComponent(
            ".\(filename).\(UUID().uuidString).part",
            isDirectory: false
        )
        do {
            _ = try await ReleaseAssetDownloadRequest(
                url: downloadURL,
                expectedInitialURL: downloadURL,
                destinationURL: partURL,
                requestTimeout: Self.requestTimeout,
                resourceTimeout: Self.resourceTimeout,
                cancellation: cancellation,
                makeSessionConfiguration: makeSessionConfiguration,
                progress: progress
            ).run()

            let actualChecksum = try Self.sha256(of: partURL, cancellation: cancellation)
            guard actualChecksum.caseInsensitiveCompare(expectedChecksum) == .orderedSame else {
                try? fileManager.removeItem(at: partURL)
                throw AppReleaseDownloadError.checksumMismatch(
                    expected: expectedChecksum,
                    actual: actualChecksum
                )
            }

            let finalURL = try Self.uniqueDestinationURL(
                in: directory,
                filename: filename,
                fileManager: fileManager
            )
            if cancellation?.isCancelled == true {
                throw CancellationError()
            }
            do {
                try fileManager.moveItem(at: partURL, to: finalURL)
            } catch {
                throw AppReleaseDownloadError.fileOperationFailed(error.localizedDescription)
            }
            return AppReleaseDownloadResult(fileURL: finalURL, sha256: actualChecksum)
        } catch {
            if fileManager.fileExists(atPath: partURL.path) {
                try? fileManager.removeItem(at: partURL)
            }
            throw error
        }
    }

    /// 只读取并严格验证同一固定 Release 的 sidecar，不下载 DMG。Popover 在用户主动
    /// 打开更新详情后调用它，以便旧 Release 缺少 checksum 时只显示发布页而不提供
    /// 未经校验的内置下载入口。
    public func verifyChecksum(
        for check: AppUpdateCheck,
        cancellation: AppReleaseDownloadCancellation? = nil
    ) async throws -> String {
        guard check.disposition == .updateAvailable else {
            throw AppReleaseDownloadError.updateNotAvailable
        }
        return try await verifiedChecksum(for: check, cancellation: cancellation)
    }

    private func verifiedChecksum(
        for check: AppUpdateCheck,
        cancellation: AppReleaseDownloadCancellation?
    ) async throws -> String {
        if cancellation?.isCancelled == true {
            throw CancellationError()
        }
        let (_, checksumURL) = try Self.fixedReleaseURLs(for: check)
        let checksumData = try await ReleaseAssetDataRequest(
            url: checksumURL,
            expectedInitialURL: checksumURL,
            bodyLimit: Self.checksumBodyLimit,
            requestTimeout: Self.requestTimeout,
            resourceTimeout: Self.requestTimeout,
            cancellation: cancellation,
            makeSessionConfiguration: makeSessionConfiguration
        ).run()
        return try Self.parseSHA256Sidecar(
            checksumData,
            expectedFilename: AppUpdateService.assetFilename(for: check.latestVersion)
        )
    }

    /// 只接受由 `AppUpdateService` 根据已经验证的正式 tag 推导出的两个固定 GitHub
    /// 初始地址。即使某个 URL 恰好位于允许的 GitHub 资产 CDN，也不能绕过这个边界。
    package static func fixedReleaseURLs(for check: AppUpdateCheck) throws -> (URL, URL) {
        guard let downloadURL = check.downloadURL else {
            throw AppReleaseDownloadError.missingDownloadURL
        }
        guard let checksumURL = check.checksumURL else {
            throw AppReleaseDownloadError.missingChecksumURL
        }
        guard let expectedDownloadURL = AppUpdateService.downloadURL(for: check.latestVersion),
              let expectedChecksumURL = AppUpdateService.checksumURL(for: check.latestVersion),
              downloadURL == expectedDownloadURL,
              checksumURL == expectedChecksumURL else {
            throw AppReleaseDownloadError.untrustedRedirect(downloadURL.absoluteString)
        }
        return (downloadURL, checksumURL)
    }

    /// 严格接受本项目发布脚本写出的单行格式：
    /// `<64 位十六进制 SHA-256><空白><可选 *><精确 DMG 文件名>`。
    package static func parseSHA256Sidecar(
        _ data: Data,
        expectedFilename: String
    ) throws -> String {
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw AppReleaseDownloadError.invalidChecksumFile
        }
        var line = decoded
        if line.hasSuffix("\n") {
            line.removeLast()
            if line.hasSuffix("\r") {
                line.removeLast()
            }
        }
        guard !line.isEmpty,
              !line.contains("\n"),
              !line.contains("\r"),
              let separatorIndex = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            throw AppReleaseDownloadError.invalidChecksumFile
        }

        let hash = String(line[..<separatorIndex])
        guard hash.count == 64,
              hash.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
              }) else {
            throw AppReleaseDownloadError.invalidChecksumFile
        }

        var filenameStart = separatorIndex
        while filenameStart < line.endIndex,
              line[filenameStart] == " " || line[filenameStart] == "\t" {
            filenameStart = line.index(after: filenameStart)
        }
        guard filenameStart < line.endIndex else {
            throw AppReleaseDownloadError.invalidChecksumFile
        }
        if line[filenameStart] == "*" {
            filenameStart = line.index(after: filenameStart)
        }
        guard String(line[filenameStart...]) == expectedFilename else {
            throw AppReleaseDownloadError.invalidChecksumFile
        }
        return hash.lowercased()
    }

    /// 以固定发布文件名写入 Downloads；若同名文件已存在，仅选择带递增后缀的新文件名。
    /// 这一函数不会创建、移动或删除文件，实际提交由后续 `moveItem` 完成且绝不覆盖。
    package static func uniqueDestinationURL(
        in directory: URL,
        filename: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard !filename.isEmpty,
              !filename.contains("/"),
              !filename.contains("\\") else {
            throw AppReleaseDownloadError.fileOperationFailed("发布文件名不合法。")
        }
        let baseURL = directory.appendingPathComponent(filename, isDirectory: false)
        guard fileManager.fileExists(atPath: baseURL.path) == false else {
            let extensionName = baseURL.pathExtension
            let basename = baseURL.deletingPathExtension().lastPathComponent
            for suffix in 1 ... 10_000 {
                let candidateName = extensionName.isEmpty
                    ? "\(basename) (\(suffix))"
                    : "\(basename) (\(suffix)).\(extensionName)"
                let candidate = directory.appendingPathComponent(candidateName, isDirectory: false)
                if !fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            throw AppReleaseDownloadError.fileOperationFailed("Downloads 目录中同名文件过多。")
        }
        return baseURL
    }

    package static func sha256(
        of fileURL: URL,
        cancellation: AppReleaseDownloadCancellation? = nil
    ) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw AppReleaseDownloadError.fileOperationFailed("无法读取 \(fileURL.lastPathComponent)。")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            if cancellation?.isCancelled == true {
                throw CancellationError()
            }
            let data: Data
            do {
                data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
            } catch {
                throw AppReleaseDownloadError.fileOperationFailed(error.localizedDescription)
            }
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class ReleaseAssetDataRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let request: URLRequest
    private let expectedInitialURL: URL
    private let bodyLimit: Int
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval
    private let cancellation: AppReleaseDownloadCancellation?
    private let makeSessionConfiguration: @Sendable (TimeInterval, TimeInterval) -> URLSessionConfiguration
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Data, Error>?
    private var body = Data()
    private var completed = false
    private var redirectCount = 0
    private var cancellationIdentifier: UUID?

    init(
        url: URL,
        expectedInitialURL: URL,
        bodyLimit: Int,
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        cancellation: AppReleaseDownloadCancellation?,
        makeSessionConfiguration: @escaping @Sendable (TimeInterval, TimeInterval) -> URLSessionConfiguration
    ) {
        request = UpdateNetworkPolicy.makeReleaseAssetRequest(
            url: url,
            timeout: requestTimeout
        )
        self.expectedInitialURL = expectedInitialURL
        self.bodyLimit = bodyLimit
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.cancellation = cancellation
        self.makeSessionConfiguration = makeSessionConfiguration
    }

    func run() async throws -> Data {
        let configuration = makeSessionConfiguration(requestTimeout, resourceTimeout)
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        lock.withLock { self.session = session }

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request)
            lock.withLock {
                self.continuation = continuation
                self.task = task
            }
            let cancellationIdentifier = cancellation?.register { [weak self] in
                self?.cancel()
            }
            let shouldResume = lock.withLock { () -> Bool in
                self.cancellationIdentifier = cancellationIdentifier
                return !self.completed
            }
            if shouldResume {
                task.resume()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            finish(.failure(AppReleaseDownloadError.downloadFailed("服务器没有返回 HTTP 响应。")))
            completionHandler(.cancel)
            return
        }
        guard response.statusCode == 200 else {
            if response.statusCode == 404 || response.statusCode == 410 {
                finish(.failure(AppReleaseDownloadError.checksumUnavailable(statusCode: response.statusCode)))
            } else {
                finish(.failure(AppReleaseDownloadError.requestFailed(statusCode: response.statusCode)))
            }
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength < 0 || response.expectedContentLength <= Int64(bodyLimit) else {
            finish(.failure(AppReleaseDownloadError.checksumResponseTooLarge))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let redirectError = lock.withLock { () -> AppReleaseDownloadError? in
            redirectCount += 1
            return UpdateNetworkPolicy.redirectError(
                for: request.url,
                expectedInitialURL: expectedInitialURL,
                redirectCount: redirectCount
            )
        }
        if let redirectError {
            finish(.failure(redirectError))
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = lock.withLock { () -> Bool in
            guard body.count <= bodyLimit - data.count else { return true }
            body.append(data)
            return false
        }
        if overflow {
            finish(.failure(AppReleaseDownloadError.checksumResponseTooLarge))
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            let mapped = UpdateNetworkPolicy.mapNetworkError(error)
            finish(.failure(mapped))
            return
        }
        let data = lock.withLock { body }
        finish(.success(data))
    }

    private func cancel() {
        let task = lock.withLock { self.task }
        finish(.failure(CancellationError()))
        task?.cancel()
    }

    private func finish(_ result: Result<Data, Error>) {
        let outcome = lock.withLock { () -> (CheckedContinuation<Data, Error>?, UUID?) in
            guard !completed else { return (nil, nil) }
            completed = true
            task = nil
            session?.finishTasksAndInvalidate()
            session = nil
            let continuation = self.continuation
            self.continuation = nil
            let cancellationIdentifier = self.cancellationIdentifier
            self.cancellationIdentifier = nil
            return (continuation, cancellationIdentifier)
        }
        guard let continuation = outcome.0 else { return }
        cancellation?.unregister(outcome.1)
        switch result {
        case let .success(data): continuation.resume(returning: data)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }
}

private final class ReleaseAssetDownloadRequest: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let request: URLRequest
    private let expectedInitialURL: URL
    private let destinationURL: URL
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval
    private let cancellation: AppReleaseDownloadCancellation?
    private let makeSessionConfiguration: @Sendable (TimeInterval, TimeInterval) -> URLSessionConfiguration
    private let progress: @Sendable (Double?) -> Void
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var completed = false
    private var redirectCount = 0
    private var cancellationIdentifier: UUID?

    init(
        url: URL,
        expectedInitialURL: URL,
        destinationURL: URL,
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        cancellation: AppReleaseDownloadCancellation?,
        makeSessionConfiguration: @escaping @Sendable (TimeInterval, TimeInterval) -> URLSessionConfiguration,
        progress: @escaping @Sendable (Double?) -> Void
    ) {
        request = UpdateNetworkPolicy.makeReleaseAssetRequest(
            url: url,
            timeout: requestTimeout
        )
        self.expectedInitialURL = expectedInitialURL
        self.destinationURL = destinationURL
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.cancellation = cancellation
        self.makeSessionConfiguration = makeSessionConfiguration
        self.progress = progress
    }

    func run() async throws -> URL {
        let configuration = makeSessionConfiguration(requestTimeout, resourceTimeout)
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        lock.withLock { self.session = session }

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: request)
            lock.withLock {
                self.continuation = continuation
                self.task = task
            }
            let cancellationIdentifier = cancellation?.register { [weak self] in
                self?.cancel()
            }
            let shouldResume = lock.withLock { () -> Bool in
                self.cancellationIdentifier = cancellationIdentifier
                return !self.completed
            }
            if shouldResume {
                task.resume()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let redirectError = lock.withLock { () -> AppReleaseDownloadError? in
            redirectCount += 1
            return UpdateNetworkPolicy.redirectError(
                for: request.url,
                expectedInitialURL: expectedInitialURL,
                redirectCount: redirectCount
            )
        }
        if let redirectError {
            finish(.failure(redirectError))
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            progress(nil)
            return
        }
        progress(min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // 取消可以和 URLSession 完成回调并发到达。先检查状态，随后仍以 finish 的返回值
        // 裁决谁拥有结果，避免“已取消”后回调又留下一个 .part 文件。
        guard shouldAcceptDownloadedFile else { return }
        guard let response = downloadTask.response as? HTTPURLResponse else {
            finish(.failure(AppReleaseDownloadError.downloadFailed("服务器没有返回 HTTP 响应。")))
            return
        }
        guard response.statusCode == 200 else {
            finish(.failure(AppReleaseDownloadError.requestFailed(statusCode: response.statusCode)))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destinationURL)
            if !finish(.success(destinationURL)) {
                // 取消或另一个失败路径已经先完成 continuation；本次回调不能留下文件。
                try? FileManager.default.removeItem(at: destinationURL)
            }
        } catch {
            finish(.failure(AppReleaseDownloadError.fileOperationFailed(error.localizedDescription)))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }
        finish(.failure(UpdateNetworkPolicy.mapNetworkError(error)))
    }

    private func cancel() {
        let task = lock.withLock { self.task }
        guard finish(.failure(CancellationError())) else { return }
        task?.cancel()
        // 如果完成回调稍后才把 URLSession 的临时位置移动进来，它会因 finish 返回 false
        // 自行删除；这里覆盖“文件已经移动但尚未恢复 continuation”的另一种竞态。
        try? FileManager.default.removeItem(at: destinationURL)
    }

    private var shouldAcceptDownloadedFile: Bool {
        guard cancellation?.isCancelled != true else { return false }
        return lock.withLock { !completed }
    }

    @discardableResult
    private func finish(_ result: Result<URL, Error>) -> Bool {
        let outcome = lock.withLock { () -> (CheckedContinuation<URL, Error>?, UUID?) in
            guard !completed else { return (nil, nil) }
            completed = true
            task = nil
            session?.finishTasksAndInvalidate()
            session = nil
            let continuation = self.continuation
            self.continuation = nil
            let cancellationIdentifier = self.cancellationIdentifier
            self.cancellationIdentifier = nil
            return (continuation, cancellationIdentifier)
        }
        guard let continuation = outcome.0 else { return false }
        cancellation?.unregister(outcome.1)
        switch result {
        case let .success(url): continuation.resume(returning: url)
        case let .failure(error): continuation.resume(throwing: error)
        }
        return true
    }
}
