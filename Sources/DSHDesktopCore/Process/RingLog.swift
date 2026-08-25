import Foundation

public enum LogStream: String, Equatable, Sendable {
    case stdout
    case stderr
}

public struct LogEntry: Equatable, Sendable {
    public let timestamp: Date
    public let stream: LogStream
    public let text: String

    public init(timestamp: Date = Date(), stream: LogStream, text: String) {
        self.timestamp = timestamp
        self.stream = stream
        self.text = text
    }

    fileprivate var storageBytes: Int {
        text.lengthOfBytes(using: .utf8)
    }
}

/// 只驻留内存的有界日志；读取端持续排空与 UI 是否打开无关。
public final class RingLog: @unchecked Sendable {
    public static let defaultLineLimit = 2_000
    public static let defaultByteLimit = 1_024 * 1_024
    public static let maximumLineBytes = 16 * 1_024

    private let lock = NSLock()
    private let lineLimit: Int
    private let byteLimit: Int
    private var entries: [LogEntry] = []
    private var totalBytes = 0
    private var partial = [LogStream.stdout: Data(), LogStream.stderr: Data()]
    /// 某一路已超过可保留的单行片段上限；在下一次换行前丢弃余下字节，
    /// 以免把被切开的请求头或 Cookie 后半段写进后续日志条目。
    private var discardingOversizedLine = [LogStream.stdout: false, LogStream.stderr: false]

    public init(lineLimit: Int = RingLog.defaultLineLimit, byteLimit: Int = RingLog.defaultByteLimit) {
        self.lineLimit = max(1, lineLimit)
        self.byteLimit = max(1, byteLimit)
    }

    public func append(_ data: Data, stream: LogStream, timestamp: Date = Date()) {
        lock.withLock {
            let partialLimit = partialByteLimitPerStream
            guard partialLimit > 0 else {
                appendDataAsEntries(data, stream: stream, timestamp: timestamp)
                partial[stream] = Data()
                return
            }

            var pending = partial[stream, default: Data()]
            var nextIndex = data.startIndex

            // `availableData` 不保证每次都带换行。分块处理可避免单次巨大、
            // 无换行输出先完整落入 pending 再截断，从而保持整个日志驻留内存有界。
            while nextIndex < data.endIndex {
                if discardingOversizedLine[stream, default: false] {
                    guard let newline = data[nextIndex...].firstIndex(of: 0x0A) else {
                        // 一整块仍属于同一条过长日志；不保留任何后半段内容。
                        break
                    }
                    discardingOversizedLine[stream] = false
                    nextIndex = data.index(after: newline)
                    continue
                }

                let remaining = data.distance(from: nextIndex, to: data.endIndex)
                let chunkLength = min(remaining, partialLimit - pending.count)
                let chunkEnd = data.index(nextIndex, offsetBy: chunkLength)
                pending.append(data[nextIndex..<chunkEnd])

                while let newline = pending.firstIndex(of: 0x0A) {
                    let lineData = pending.prefix(upTo: newline)
                    pending.removeSubrange(...newline)
                    appendLine(Data(lineData), stream: stream, timestamp: timestamp)
                }
                nextIndex = chunkEnd

                if pending.count == partialLimit {
                    // 对逻辑上没有换行的超长行，不保留首段或续段：若它恰好是
                    // 被拆开的敏感请求头，任何一段都不应进入日志。
                    appendOversizedLineMarker(stream: stream, timestamp: timestamp)
                    pending.removeAll(keepingCapacity: true)
                    discardingOversizedLine[stream] = true
                }
            }
            partial[stream] = pending
        }
    }

    public func finish(stream: LogStream, timestamp: Date = Date()) {
        lock.withLock {
            let pending = partial[stream, default: Data()]
            guard !pending.isEmpty else {
                discardingOversizedLine[stream] = false
                return
            }
            appendLine(pending, stream: stream, timestamp: timestamp)
            partial[stream] = Data()
            discardingOversizedLine[stream] = false
        }
    }

    public func snapshot() -> [LogEntry] {
        lock.withLock { entries }
    }

    public var count: Int {
        lock.withLock { entries.count }
    }

    public var bytes: Int {
        lock.withLock { totalBytes }
    }

    /// 包含尚未遇到换行的两路 pending（待补全片段）的总驻留字节数。
    /// 已完成条目与两路 pending 共用同一上限，便于验证无换行输出不会突破内存边界。
    public var retainedBytes: Int {
        lock.withLock {
            totalBytes + partial.values.reduce(0) { $0 + $1.count }
        }
    }

    private var partialByteLimitPerStream: Int {
        // 给 stdout/stderr 各预留最多 16 KiB，且两者合计不超过总预算的四分之一。
        min(Self.maximumLineBytes, byteLimit / 8)
    }

    private var entryByteLimit: Int {
        max(1, byteLimit - partialByteLimitPerStream * 2)
    }

    private func appendDataAsEntries(_ data: Data, stream: LogStream, timestamp: Date) {
        var nextIndex = data.startIndex
        while nextIndex < data.endIndex {
            let remaining = data.distance(from: nextIndex, to: data.endIndex)
            let chunkLength = min(remaining, Self.maximumLineBytes + 1)
            let chunkEnd = data.index(nextIndex, offsetBy: chunkLength)
            appendLine(Data(data[nextIndex..<chunkEnd]), stream: stream, timestamp: timestamp)
            nextIndex = chunkEnd
        }
    }

    private func appendOversizedLineMarker(stream: LogStream, timestamp: Date) {
        appendLine(
            Data("[单行日志超过保留上限，内容未保留]".utf8),
            stream: stream,
            timestamp: timestamp
        )
    }

    private func appendLine(_ originalData: Data, stream: LogStream, timestamp: Date) {
        let trimmedData: Data
        if originalData.last == 0x0D {
            trimmedData = originalData.dropLast()
        } else {
            trimmedData = originalData
        }
        let limitedData = Data(trimmedData.prefix(Self.maximumLineBytes))
        var text = String(decoding: limitedData, as: UTF8.self)
        if originalData.count > Self.maximumLineBytes {
            text += " …（单行已截断）"
        }
        let entry = LogEntry(stream: stream, text: boundedText(Self.redact(text), limit: entryByteLimit))
        let entryBytes = entry.storageBytes

        while !entries.isEmpty && (entries.count >= lineLimit || totalBytes + entryBytes > entryByteLimit) {
            totalBytes -= entries.removeFirst().storageBytes
        }
        entries.append(entry)
        totalBytes += entryBytes
    }

    private func boundedText(_ text: String, limit: Int) -> String {
        guard text.lengthOfBytes(using: .utf8) > limit else { return text }

        let suffix = " …（日志已截断）"
        let suffixBytes = suffix.lengthOfBytes(using: .utf8)
        let budget = max(0, limit - suffixBytes)
        guard budget > 0 else {
            // 使用 ASCII 占位，保证即使 byteLimit 小于一个 Unicode 字符也绝不越界。
            return String(repeating: ".", count: limit)
        }

        var result = ""
        var usedBytes = 0
        for character in text {
            let characterText = String(character)
            let characterBytes = characterText.lengthOfBytes(using: .utf8)
            guard usedBytes + characterBytes <= budget else { break }
            result += characterText
            usedBytes += characterBytes
        }
        return result + suffix
    }

    private static func redact(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let authorizationPattern = "(?i)(authorization)\\s*([:=])\\s*[^\\r\\n]+"
        let cookiePattern = "(?i)(set-cookie|cookie)\\s*([:=])\\s*[^\\r\\n]+"
        let genericPattern = "(?i)(token|api[_-]?key|password|secret)\\s*([:=])\\s*([^\\s,;]+)"

        let authorizationRedacted = replaceSensitiveValue(
            in: text,
            pattern: authorizationPattern,
            range: range
        )
        let cookieRedacted = replaceSensitiveValue(
            in: authorizationRedacted,
            pattern: cookiePattern,
            range: NSRange(authorizationRedacted.startIndex..<authorizationRedacted.endIndex, in: authorizationRedacted)
        )
        return replaceSensitiveValue(
            in: cookieRedacted,
            pattern: genericPattern,
            range: NSRange(cookieRedacted.startIndex..<cookieRedacted.endIndex, in: cookieRedacted)
        )
    }

    private static func replaceSensitiveValue(in text: String, pattern: String, range: NSRange) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        return expression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "$1$2[REDACTED]"
        )
    }
}
