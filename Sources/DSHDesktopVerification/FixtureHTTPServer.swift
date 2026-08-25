import Darwin
import Dispatch
import Foundation

enum FixtureHTTPResponse: Sendable {
    case response(status: Int, headers: [String: String], body: Data)
    case holdOpen(microseconds: useconds_t)

    static func html(_ body: String = "<html><body>fixture</body></html>") -> FixtureHTTPResponse {
        .response(
            status: 200,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data(body.utf8)
        )
    }

    static func manifest() -> FixtureHTTPResponse {
        .response(
            status: 200,
            headers: ["Content-Type": "application/manifest+json"],
            body: Data("{\"name\":\"DeepSeek Harness\",\"short_name\":\"DSH\"}".utf8)
        )
    }
}

/// 仅供独立验证 target 使用的最小 HTTP fixture；固定绑定随机 loopback 端口。
final class FixtureHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ path: String) -> FixtureHTTPResponse

    let port: Int
    var rootURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    private let descriptor: Int32
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.dshdesktop.verification.http-fixture")
    private let stateLock = NSLock()
    private var closed = false

    init(port requestedPort: UInt16 = 0, handler: @escaping Handler) throws {
        self.handler = handler

        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FixtureHTTPServerError.socket(errno) }
        self.descriptor = descriptor

        var reuseAddress: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            Darwin.close(descriptor)
            throw FixtureHTTPServerError.socket(errno)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(requestedPort).bigEndian
        let conversion = "127.0.0.1".withCString { source in
            inet_pton(AF_INET, source, &address.sin_addr)
        }
        guard conversion == 1 else {
            Darwin.close(descriptor)
            throw FixtureHTTPServerError.socket(errno)
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(descriptor)
            throw FixtureHTTPServerError.socket(errno)
        }
        guard listen(descriptor, SOMAXCONN) == 0 else {
            Darwin.close(descriptor)
            throw FixtureHTTPServerError.socket(errno)
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(descriptor)
            throw FixtureHTTPServerError.socket(errno)
        }
        port = Int(UInt16(bigEndian: boundAddress.sin_port))

        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    deinit {
        close()
    }

    func close() {
        let shouldClose = stateLock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        _ = shutdown(descriptor, SHUT_RDWR)
        _ = Darwin.close(descriptor)
    }

    private func acceptLoop() {
        while !isClosed {
            var address = sockaddr()
            var addressLength = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(descriptor, &address, &addressLength)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            let handler = handler
            DispatchQueue.global(qos: .utility).async {
                Self.respond(on: client, handler: handler)
            }
        }
    }

    private var isClosed: Bool {
        stateLock.withLock { closed }
    }

    private static func respond(on descriptor: Int32, handler: @escaping Handler) {
        defer { _ = Darwin.close(descriptor) }
        let request = readRequest(descriptor)
        let path = request
            .split(separator: "\r\n", maxSplits: 1)
            .first
            .flatMap { $0.split(separator: " ").dropFirst().first }
            .map(String.init) ?? "/"

        switch handler(path) {
        case let .holdOpen(microseconds):
            usleep(microseconds)

        case let .response(status, headers, body):
            var mergedHeaders = headers
            if mergedHeaders["Content-Length"] == nil {
                mergedHeaders["Content-Length"] = "\(body.count)"
            }
            mergedHeaders["Connection"] = "close"
            let headerLines = mergedHeaders
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\r\n")
            let prefix = "HTTP/1.1 \(status) Fixture\r\n\(headerLines)\r\n\r\n"
            var payload = Data(prefix.utf8)
            payload.append(body)
            sendAll(payload, to: descriptor)
        }
    }

    private static func readRequest(_ descriptor: Int32) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count < 16 * 1_024 {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            data.append(buffer, count: Int(count))
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func sendAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let sent = send(descriptor, pointer, remaining, 0)
                guard sent > 0 else { return }
                pointer = pointer.advanced(by: sent)
                remaining -= sent
            }
        }
    }
}

private enum FixtureHTTPServerError: LocalizedError {
    case socket(Int32)

    var errorDescription: String? {
        switch self {
        case let .socket(code): "HTTP fixture socket 错误 \(code)"
        }
    }
}
