import DSHDesktopCore
import Foundation

/// 执行 `AppDownloadFlow` 返回的异步 IO effect（副作用）。所有状态判断都留在
/// Core flow 中；driver 只把网络／文件结果连同原 operation token（操作令牌）送回。
@MainActor
final class AppDownloadDriver {
    typealias State = AppDownloadFlow.State

    var onStateChange: ((State) -> Void)?

    private var flow = AppDownloadFlow()
    private let service: AppReleaseDownloadService
    private let downloadsDirectory: URL?
    private let operations = AppDownloadOperationBag()

    init(
        service: AppReleaseDownloadService = AppReleaseDownloadService(),
        downloadsDirectory: URL? = AppRuntimeConfiguration.current.downloadDirectoryOverride
    ) {
        self.service = service
        self.downloadsDirectory = downloadsDirectory
    }

    var state: State { flow.state }

    func updateCheck(_ check: AppUpdateCheck?) {
        send(.latestCheckChanged(check))
    }

    func prepare(_ check: AppUpdateCheck) {
        send(.prepareRequested(check))
    }

    func download(_ check: AppUpdateCheck) {
        send(.downloadRequested(check))
    }

    func cancelTransfer() {
        send(.cancelTransferRequested)
    }

    func refreshCompletedFileAvailability() {
        guard case let .completed(result) = flow.state else { return }
        send(.completedFileAvailabilityChanged(
            result,
            isAvailable: service.downloadedFileIsAvailable(result)
        ))
    }

    func validateDownloadedFile(
        _ result: AppReleaseDownloadResult,
        onValidated: @escaping @MainActor () -> Void
    ) {
        let oldState = flow.state
        let effects = flow.send(.validationRequested(result))
        publishIfChanged(from: oldState)
        execute(effects, validationCompletion: onValidated)
    }

    func cancelDownloadedFileValidation() {
        guard case let .validatingDownloadedFile(result) = flow.state else { return }
        send(.cancelValidationRequested(
            result,
            isAvailable: service.downloadedFileIsAvailable(result)
        ))
    }

    func cancelAll() {
        send(.latestCheckChanged(nil))
        operations.cancelAll()
    }

    private func send(_ event: AppDownloadFlow.Event) {
        let oldState = flow.state
        let effects = flow.send(event)
        publishIfChanged(from: oldState)
        execute(effects)
    }

    private func publishIfChanged(from oldState: State) {
        guard oldState != flow.state else { return }
        onStateChange?(flow.state)
    }

    private func execute(
        _ effects: [AppDownloadFlow.Effect],
        validationCompletion: (@MainActor () -> Void)? = nil
    ) {
        for effect in effects {
            switch effect {
            case let .cancel(token):
                operations.cancel(token)
            case let .verifyChecksum(token, check):
                startChecksumVerification(token: token, check: check)
            case let .download(token, check):
                startDownload(token: token, check: check)
            case let .validateDownloadedFile(token, result):
                startDownloadedFileValidation(
                    token: token,
                    result: result,
                    completion: validationCompletion
                )
            }
        }
    }

    private func startChecksumVerification(
        token: AppDownloadFlow.OperationToken,
        check: AppUpdateCheck
    ) {
        let cancellation = AppReleaseDownloadCancellation()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await service.verifyChecksum(for: check, cancellation: cancellation)
                guard !Task.isCancelled, operations.contains(token) else { return }
                operations.finish(token)
                send(.checksumVerified(token))
            } catch is CancellationError {
                finishCancelledOperation(token)
            } catch {
                finishFailedOperation(token, error: error)
            }
        }
        operations.install(
            token: token,
            cancellation: cancellation,
            task: task,
            validationCompletion: nil
        )
    }

    private func startDownload(
        token: AppDownloadFlow.OperationToken,
        check: AppUpdateCheck
    ) {
        let cancellation = AppReleaseDownloadCancellation()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await service.download(
                    check: check,
                    downloadsDirectory: downloadsDirectory,
                    cancellation: cancellation
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.operations.contains(token) else { return }
                        self.send(.downloadProgress(token, progress))
                    }
                }
                guard !Task.isCancelled, operations.contains(token) else { return }
                operations.finish(token)
                send(.downloadCompleted(token, result))
            } catch is CancellationError {
                finishCancelledOperation(token)
            } catch {
                finishFailedOperation(token, error: error)
            }
        }
        operations.install(
            token: token,
            cancellation: cancellation,
            task: task,
            validationCompletion: nil
        )
    }

    private func startDownloadedFileValidation(
        token: AppDownloadFlow.OperationToken,
        result: AppReleaseDownloadResult,
        completion: (@MainActor () -> Void)?
    ) {
        let cancellation = AppReleaseDownloadCancellation()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let isValid = await service.downloadedFileMatchesChecksum(
                result,
                cancellation: cancellation
            )
            guard !Task.isCancelled, operations.contains(token) else { return }
            let validatedAction = operations.finish(token)?.validationCompletion
            send(.validationCompleted(token, result, isValid: isValid))
            if isValid {
                validatedAction?()
            }
        }
        operations.install(
            token: token,
            cancellation: cancellation,
            task: task,
            validationCompletion: completion
        )
    }

    private func finishCancelledOperation(_ token: AppDownloadFlow.OperationToken) {
        guard operations.finish(token) != nil else { return }
        send(.operationCancelled(token))
    }

    private func finishFailedOperation(
        _ token: AppDownloadFlow.OperationToken,
        error: Error
    ) {
        guard operations.finish(token) != nil else { return }
        let failure: AppDownloadFlow.Failure
        if let downloadError = error as? AppReleaseDownloadError,
           case .checksumUnavailable = downloadError {
            failure = .checksumUnavailable(downloadError.localizedDescription)
        } else {
            failure = .other(error.localizedDescription)
        }
        send(.operationFailed(token, failure))
    }
}

/// `Task` 与 cancellation（取消器）都可从 nonisolated deinit 安全取消；字典本身只由
/// `AppDownloadDriver` 的 MainActor 访问。
private final class AppDownloadOperationBag: @unchecked Sendable {
    struct Record {
        let cancellation: AppReleaseDownloadCancellation
        let task: Task<Void, Never>
        let validationCompletion: (@MainActor () -> Void)?
    }

    private var records: [AppDownloadFlow.OperationToken: Record] = [:]

    func install(
        token: AppDownloadFlow.OperationToken,
        cancellation: AppReleaseDownloadCancellation,
        task: Task<Void, Never>,
        validationCompletion: (@MainActor () -> Void)?
    ) {
        cancel(token)
        records[token] = Record(
            cancellation: cancellation,
            task: task,
            validationCompletion: validationCompletion
        )
    }

    func contains(_ token: AppDownloadFlow.OperationToken) -> Bool {
        records[token] != nil
    }

    @discardableResult
    func finish(_ token: AppDownloadFlow.OperationToken) -> Record? {
        records.removeValue(forKey: token)
    }

    func cancel(_ token: AppDownloadFlow.OperationToken) {
        guard let record = records.removeValue(forKey: token) else { return }
        record.cancellation.cancel()
        record.task.cancel()
    }

    func cancelAll() {
        let pending = Array(records.values)
        records.removeAll()
        for record in pending {
            record.cancellation.cancel()
            record.task.cancel()
        }
    }

    deinit {
        cancelAll()
    }
}
