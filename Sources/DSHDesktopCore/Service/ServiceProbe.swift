@preconcurrency import Foundation

public enum UnavailableReason: Equatable, Sendable {
    case connectionFailed
    case totalTimeoutBeforeHTTPResponse
}

public enum ReachableUnknownReason: Equatable, Sendable {
    case manifestMissing
    case manifestInvalid
    case manifestRedirectRejected
    case manifestRequestFailed
}

public enum ReachableNonHTMLReason: Equatable, Sendable {
    case rootCrossOriginRedirect
    case rootNon2xx(Int)
    case rootNotHTML(String?)
    case rootRedirectLoop
    case rootBodyTooLarge
    case rootInvalidResponse
}

/// Probe 只描述端口当前响应，不代表对本机进程身份的认证。
public enum ProbeResult: Equatable, Sendable {
    case unavailable(UnavailableReason)
    case dshLikely
    case reachableUnknown(ReachableUnknownReason)
    case reachableNonHTML(ReachableNonHTMLReason)

    public var preventsSpawn: Bool {
        switch self {
        case .unavailable:
            false
        case .dshLikely, .reachableUnknown, .reachableNonHTML:
            true
        }
    }
}

public struct ServiceProbe: Sendable {
    public static let rootBodyLimit = 512 * 1024
    public static let manifestBodyLimit = 64 * 1024
    public static let totalTimeout: TimeInterval = 2

    public let rootURL: URL

    public init(rootURL: URL = LocalService.url) {
        self.rootURL = rootURL
    }

    /// 在整个 probe（根页面与 manifest）共享的时间预算内检查服务。
    /// 这避免 manifest 的独立超时把一次启动轮询拉长为两倍的时间。
    public func probe(timeout: TimeInterval = Self.totalTimeout) async -> ProbeResult {
        guard timeout.isFinite, timeout > 0 else {
            return .unavailable(.totalTimeoutBeforeHTTPResponse)
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let deadline = now + min(nanoseconds(for: timeout), UInt64.max - now)
        guard let rootTimeout = remainingTimeout(until: deadline) else {
            return .unavailable(.totalTimeoutBeforeHTTPResponse)
        }
        let rootResult = await fetch(
            url: rootURL,
            bodyLimit: Self.rootBodyLimit,
            allowedOrigin: rootURL,
            timeout: rootTimeout
        )

        switch rootResult {
        case let .success(payload):
            return await classifyRoot(payload, deadline: deadline)
        case let .failure(context):
            if context.receivedHTTPResponse {
                switch context.redirectRejection {
                case .crossOrigin:
                    return .reachableNonHTML(.rootCrossOriginRedirect)
                case .loop:
                    return .reachableNonHTML(.rootRedirectLoop)
                case .none where context.bodyTooLarge:
                    return .reachableNonHTML(.rootBodyTooLarge)
                case .none:
                    return .reachableNonHTML(.rootInvalidResponse)
                }
            }
            return .unavailable(context.timedOut ? .totalTimeoutBeforeHTTPResponse : .connectionFailed)
        }
    }

    private func classifyRoot(_ payload: BoundedPayload, deadline: UInt64) async -> ProbeResult {
        guard let response = payload.response as? HTTPURLResponse else {
            return .reachableNonHTML(.rootInvalidResponse)
        }
        guard Self.isSameOrigin(response.url, rootURL) else {
            return .reachableNonHTML(.rootCrossOriginRedirect)
        }
        guard (200 ... 299).contains(response.statusCode) else {
            return .reachableNonHTML(.rootNon2xx(response.statusCode))
        }
        guard Self.isHTML(response.value(forHTTPHeaderField: "Content-Type")) else {
            return .reachableNonHTML(.rootNotHTML(response.value(forHTTPHeaderField: "Content-Type")))
        }

        let manifestURL = URL(string: "/manifest.webmanifest", relativeTo: response.url)?.absoluteURL
            ?? LocalService.manifestURL
        // 根页面已经收到 HTTP 响应，即使剩余预算耗尽也不能把端口重新判为
        // “不可访问”；这时只把软识别降级为需要确认。
        guard let manifestTimeout = remainingTimeout(until: deadline) else {
            return .reachableUnknown(.manifestRequestFailed)
        }
        let manifestResult = await fetch(
            url: manifestURL,
            bodyLimit: Self.manifestBodyLimit,
            allowedOrigin: rootURL,
            timeout: manifestTimeout
        )

        switch manifestResult {
        case let .success(manifest):
            guard let manifestResponse = manifest.response as? HTTPURLResponse else {
                return .reachableUnknown(.manifestInvalid)
            }
            guard Self.isSameOrigin(manifestResponse.url, rootURL) else {
                return .reachableUnknown(.manifestRedirectRejected)
            }
            guard (200 ... 299).contains(manifestResponse.statusCode) else {
                return .reachableUnknown(.manifestMissing)
            }
            return Self.matchesDSHManifest(manifest.body) ? .dshLikely : .reachableUnknown(.manifestInvalid)

        case let .failure(context):
            switch context.redirectRejection {
            case .crossOrigin, .loop:
                return .reachableUnknown(.manifestRedirectRejected)
            case .none where context.bodyTooLarge:
                return .reachableUnknown(.manifestInvalid)
            case .none:
                return .reachableUnknown(.manifestRequestFailed)
            }
        }
    }

    private func fetch(
        url: URL,
        bodyLimit: Int,
        allowedOrigin: URL,
        timeout: TimeInterval
    ) async -> FetchResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let runner = BoundedRequestRunner(
            request: request,
            allowedOrigin: allowedOrigin,
            bodyLimit: bodyLimit,
            timeout: timeout
        )

        do {
            return .success(try await runner.run())
        } catch {
            return .failure(runner.context)
        }
    }

    private func remainingTimeout(until deadline: UInt64) -> TimeInterval? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return nil }
        return TimeInterval(deadline - now) / 1_000_000_000
    }

    private func nanoseconds(for timeout: TimeInterval) -> UInt64 {
        let requested = timeout * 1_000_000_000
        if requested >= Double(UInt64.max) {
            return UInt64.max
        }
        return UInt64(requested)
    }

    static func isSameOrigin(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
    }

    static func isHTML(_ contentType: String?) -> Bool {
        guard let contentType else { return false }
        let mimeType = contentType.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return mimeType == "text/html" || mimeType == "application/xhtml+xml"
    }

    static func matchesDSHManifest(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let manifest = object as? [String: Any],
              let name = manifest["name"] as? String,
              let shortName = manifest["short_name"] as? String else {
            return false
        }
        return name == "DeepSeek Harness" && shortName == "DSH"
    }
}

private struct BoundedPayload: @unchecked Sendable {
    let body: Data
    let response: URLResponse
}

private enum RedirectRejection: Sendable {
    case crossOrigin
    case loop
}

private struct BoundedRequestContext: Sendable {
    var receivedHTTPResponse = false
    var redirectRejection: RedirectRejection?
    var bodyTooLarge = false
    var timedOut = false
}

private enum FetchResult: Sendable {
    case success(BoundedPayload)
    case failure(BoundedRequestContext)
}

private enum BoundedRequestError: Error {
    case bodyTooLarge
    case timedOut
    case redirectRejected
}

private final class BoundedRequestRunner: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let request: URLRequest
    private let allowedOrigin: URL
    private let bodyLimit: Int
    private let timeout: TimeInterval
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<BoundedPayload, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var buffer = Data()
    private var response: URLResponse?
    private var contextStorage = BoundedRequestContext()
    private var redirectCount = 0
    private var completed = false

    init(request: URLRequest, allowedOrigin: URL, bodyLimit: Int, timeout: TimeInterval) {
        self.request = request
        self.allowedOrigin = allowedOrigin
        self.bodyLimit = bodyLimit
        self.timeout = timeout
    }

    var context: BoundedRequestContext {
        lock.withLock { contextStorage }
    }

    func run() async throws -> BoundedPayload {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        lock.withLock { self.session = session }

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request)
            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.cancelForTimeout()
            }
            lock.withLock {
                self.continuation = continuation
                self.task = task
                self.timeoutWorkItem = timeoutWorkItem
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let shouldCancel = lock.withLock { () -> Bool in
            contextStorage.receivedHTTPResponse = response is HTTPURLResponse
            self.response = response
            if response.expectedContentLength > Int64(bodyLimit) {
                contextStorage.bodyTooLarge = true
                return true
            }
            return false
        }
        if shouldCancel {
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let decision = lock.withLock { () -> URLRequest? in
            contextStorage.receivedHTTPResponse = true
            redirectCount += 1
            guard redirectCount <= 5 else {
                contextStorage.redirectRejection = .loop
                return nil
            }
            guard ServiceProbe.isSameOrigin(request.url, allowedOrigin) else {
                contextStorage.redirectRejection = .crossOrigin
                return nil
            }
            return request
        }
        if decision == nil {
            // URLSession 会把“delegate 返回 nil”的原始 3xx 当作完成响应；
            // 主动结束 continuation，才能保留跨源/循环拒绝语义。
            finish(.failure(BoundedRequestError.redirectRejected))
        }
        completionHandler(decision)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = lock.withLock { () -> Bool in
            let remaining = bodyLimit - buffer.count
            guard remaining >= data.count else {
                contextStorage.bodyTooLarge = true
                return true
            }
            buffer.append(data)
            return false
        }
        if overflow {
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let outcome: Result<BoundedPayload, Error> = lock.withLock {
            if contextStorage.bodyTooLarge {
                return .failure(BoundedRequestError.bodyTooLarge)
            }
            if contextStorage.timedOut {
                return .failure(BoundedRequestError.timedOut)
            }
            if let error {
                // URLSession 自己的 request/resource timeout 可能与我们的
                // DispatchWorkItem 几乎同时到达；无论哪一个先回调，都必须
                // 归一为“收到 HTTP 响应前的总超时”，而不是连接失败。
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain,
                   URLError.Code(rawValue: nsError.code) == .timedOut {
                    contextStorage.timedOut = true
                    return .failure(BoundedRequestError.timedOut)
                }
                return .failure(error)
            }
            guard let response else {
                return .failure(URLError(.badServerResponse))
            }
            return .success(BoundedPayload(body: buffer, response: response))
        }
        finish(outcome)
    }

    private func cancelForTimeout() {
        let task = lock.withLock { () -> URLSessionDataTask? in
            guard !completed else { return nil }
            contextStorage.timedOut = true
            return self.task
        }
        task?.cancel()
    }

    private func finish(_ outcome: Result<BoundedPayload, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<BoundedPayload, Error>? in
            guard !completed else { return nil }
            completed = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            task = nil
            session?.finishTasksAndInvalidate()
            session = nil
            defer { self.continuation = nil }
            return self.continuation
        }
        guard let continuation else { return }
        switch outcome {
        case let .success(payload):
            continuation.resume(returning: payload)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
