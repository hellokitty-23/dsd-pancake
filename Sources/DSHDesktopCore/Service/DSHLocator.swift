import Foundation

public struct DSHExecutable: Equatable, Sendable {
    public let url: URL

    public init?(url: URL, fileManager: FileManager = .default) {
        guard url.isFileURL,
              fileManager.fileExists(atPath: url.path),
              fileManager.isExecutableFile(atPath: url.path) else {
            return nil
        }
        self.url = url.standardizedFileURL
    }
}

/// 只检查固定候选路径或用户已选择路径；不运行 `which`，也不扫描磁盘。
public struct DSHLocator: Sendable {
    public static let automaticPaths = [
        URL(fileURLWithPath: "/opt/homebrew/bin/dsh"),
        URL(fileURLWithPath: "/usr/local/bin/dsh"),
    ]

    public init() {}

    public func locate(lastChosenPath: String? = nil, fileManager: FileManager = .default) -> DSHExecutable? {
        let preferred = lastChosenPath.map { URL(fileURLWithPath: $0) }
        let candidates = (preferred.map { [$0] } ?? []) + Self.automaticPaths
        for candidate in candidates {
            if let executable = DSHExecutable(url: candidate, fileManager: fileManager) {
                return executable
            }
        }
        return nil
    }
}
