import Foundation

/// App Release 下载的纯状态机。它不创建 Task、不访问网络或文件系统，也不依赖 UI；
/// 调用方执行返回的 effect（副作用）后，再携带同一个 operation token（操作令牌）
/// 回送结果。旧任务的迟到结果因令牌不匹配而不会覆盖当前版本状态。
public struct AppDownloadFlow: Sendable {
    public struct OperationToken: Hashable, Equatable, Sendable {
        public let rawValue: UInt64

        fileprivate init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        case verifyingChecksum
        case readyToDownload
        case downloading(Double?)
        case completed(AppReleaseDownloadResult)
        case validatingDownloadedFile(AppReleaseDownloadResult)
        case checksumUnavailable(String)
        case failed(String)

        public var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }
    }

    public enum Failure: Equatable, Sendable {
        case checksumUnavailable(String)
        case other(String)
    }

    public enum Event: Equatable, Sendable {
        case latestCheckChanged(AppUpdateCheck?)
        case prepareRequested(AppUpdateCheck)
        case downloadRequested(AppUpdateCheck)
        case validationRequested(AppReleaseDownloadResult)
        case checksumVerified(OperationToken)
        case downloadProgress(OperationToken, Double?)
        case downloadCompleted(OperationToken, AppReleaseDownloadResult)
        case operationFailed(OperationToken, Failure)
        case operationCancelled(OperationToken)
        case validationCompleted(
            OperationToken,
            AppReleaseDownloadResult,
            isValid: Bool
        )
        case completedFileAvailabilityChanged(
            AppReleaseDownloadResult,
            isAvailable: Bool
        )
        case cancelTransferRequested
        case cancelValidationRequested(
            AppReleaseDownloadResult,
            isAvailable: Bool
        )
    }

    public enum Effect: Equatable, Sendable {
        case cancel(OperationToken)
        case verifyChecksum(OperationToken, AppUpdateCheck)
        case download(OperationToken, AppUpdateCheck)
        case validateDownloadedFile(OperationToken, AppReleaseDownloadResult)
    }

    private enum Operation: Equatable, Sendable {
        case checksum(SemanticVersion)
        case download(SemanticVersion)
        case validation(SemanticVersion, AppReleaseDownloadResult)
    }

    private struct ActiveOperation: Equatable, Sendable {
        let token: OperationToken
        let operation: Operation
    }

    public private(set) var state: State = .idle
    public private(set) var latestCheck: AppUpdateCheck?
    private var checksumReadyVersion: SemanticVersion?
    private var activeOperation: ActiveOperation?
    private var nextTokenRawValue: UInt64 = 1

    public init() {}

    @discardableResult
    public mutating func send(_ event: Event) -> [Effect] {
        switch event {
        case let .latestCheckChanged(check):
            guard latestCheck != check else { return [] }
            let effects = activeOperation.map { [Effect.cancel($0.token)] } ?? []
            latestCheck = check
            checksumReadyVersion = nil
            activeOperation = nil
            state = .idle
            return effects

        case let .prepareRequested(check):
            guard latestCheck == check,
                  activeOperation == nil,
                  !state.isDownloading else {
                return []
            }
            if checksumReadyVersion == check.latestVersion,
               state == .readyToDownload {
                return []
            }
            if case .completed = state { return [] }
            if case .validatingDownloadedFile = state { return [] }

            checksumReadyVersion = nil
            let token = makeToken()
            activeOperation = ActiveOperation(
                token: token,
                operation: .checksum(check.latestVersion)
            )
            state = .verifyingChecksum
            return [.verifyChecksum(token, check)]

        case let .downloadRequested(check):
            guard latestCheck == check,
                  activeOperation == nil,
                  checksumReadyVersion == check.latestVersion,
                  state == .readyToDownload else {
                return []
            }
            let token = makeToken()
            activeOperation = ActiveOperation(
                token: token,
                operation: .download(check.latestVersion)
            )
            state = .downloading(nil)
            return [.download(token, check)]

        case let .validationRequested(result):
            guard activeOperation == nil,
                  state == .completed(result),
                  let version = latestCheck?.latestVersion,
                  checksumReadyVersion == version else {
                return []
            }
            let token = makeToken()
            activeOperation = ActiveOperation(
                token: token,
                operation: .validation(version, result)
            )
            state = .validatingDownloadedFile(result)
            return [.validateDownloadedFile(token, result)]

        case let .checksumVerified(token):
            guard case let .checksum(version) = matchingOperation(token) else { return [] }
            activeOperation = nil
            guard latestCheck?.latestVersion == version else { return [] }
            checksumReadyVersion = version
            state = .readyToDownload
            return []

        case let .downloadProgress(token, progress):
            guard case let .download(version) = matchingOperation(token),
                  latestCheck?.latestVersion == version else {
                return []
            }
            state = .downloading(progress)
            return []

        case let .downloadCompleted(token, result):
            guard case let .download(version) = matchingOperation(token) else { return [] }
            activeOperation = nil
            guard latestCheck?.latestVersion == version else { return [] }
            state = .completed(result)
            return []

        case let .operationFailed(token, failure):
            guard matchingOperation(token) != nil else { return [] }
            activeOperation = nil
            switch failure {
            case let .checksumUnavailable(message):
                checksumReadyVersion = nil
                state = .checksumUnavailable(message)
            case let .other(message):
                state = .failed(message)
            }
            return []

        case let .operationCancelled(token):
            guard matchingOperation(token) != nil else { return [] }
            activeOperation = nil
            state = .idle
            return []

        case let .validationCompleted(token, result, isValid):
            guard case let .validation(version, expectedResult) = matchingOperation(token),
                  expectedResult == result else {
                return []
            }
            activeOperation = nil
            guard latestCheck?.latestVersion == version else { return [] }
            state = isValid ? .completed(result) : fallbackDownloadState()
            return []

        case let .completedFileAvailabilityChanged(result, isAvailable):
            guard state == .completed(result), !isAvailable else { return [] }
            state = fallbackDownloadState()
            return []

        case .cancelTransferRequested:
            guard let activeOperation else { return [] }
            switch activeOperation.operation {
            case .checksum, .download:
                self.activeOperation = nil
                state = .idle
                return [.cancel(activeOperation.token)]
            case .validation:
                return []
            }

        case let .cancelValidationRequested(result, isAvailable):
            guard let activeOperation,
                  case let .validation(_, expectedResult) = activeOperation.operation,
                  expectedResult == result else {
                return []
            }
            self.activeOperation = nil
            state = isAvailable ? .completed(result) : fallbackDownloadState()
            return [.cancel(activeOperation.token)]
        }
    }

    private mutating func makeToken() -> OperationToken {
        let token = OperationToken(rawValue: nextTokenRawValue)
        nextTokenRawValue &+= 1
        if nextTokenRawValue == 0 { nextTokenRawValue = 1 }
        return token
    }

    private func matchingOperation(_ token: OperationToken) -> Operation? {
        guard activeOperation?.token == token else { return nil }
        return activeOperation?.operation
    }

    private func fallbackDownloadState() -> State {
        guard checksumReadyVersion == latestCheck?.latestVersion else { return .idle }
        return .readyToDownload
    }
}
