import Foundation

final class ReleaseAssetRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func record(_ request: URLRequest) {
        guard let path = request.url?.path else { return }
        lock.withLock {
            paths.append(path)
        }
    }

    func containsPath(suffix: String) -> Bool {
        lock.withLock {
            paths.contains { $0.hasSuffix(suffix) }
        }
    }
}

/// 仅供验证 target 注入固定 GitHub URL 的受控响应；它不监听端口、不访问网络，也不会
/// 改变生产 App 的 URLSession 配置。下载服务仍按真实固定 URL 和重定向策略运行。
final class ReleaseAssetURLProtocol: URLProtocol, @unchecked Sendable {
    struct Fixture: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
        let delay: TimeInterval

        init(
            status: Int,
            headers: [String: String],
            body: Data,
            delay: TimeInterval = 0
        ) {
            self.status = status
            self.headers = headers
            self.body = body
            self.delay = max(0, delay)
        }
    }

    typealias ResponseHandler = @Sendable (URLRequest) -> Fixture

    private static let handlerLock = NSLock()
    nonisolated(unsafe) private static var handler: ResponseHandler?

    static func install(handler: @escaping ResponseHandler) {
        handlerLock.withLock {
            self.handler = handler
        }
    }

    static func reset() {
        handlerLock.withLock {
            handler = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.lowercased() == "github.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let handler = Self.handlerLock.withLock({ Self.handler }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let fixture = handler(request)
        if fixture.delay > 0 {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + fixture.delay) { [weak self] in
                self?.send(fixture, for: url)
            }
            return
        }
        send(fixture, for: url)
    }

    private func send(_ fixture: Fixture, for url: URL) {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: fixture.status,
            httpVersion: "HTTP/1.1",
            headerFields: fixture.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !fixture.body.isEmpty {
            client?.urlProtocol(self, didLoad: fixture.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
