import AppKit
import Combine
import DSHDesktopCore

/// 更新功能对 AppDelegate 与标题栏暴露的稳定 façade（门面）。下载状态归约、异步
/// IO、AppKit 展示和 SwiftUI 渲染分别委托给独立对象。
@MainActor
final class UpdateOverlayController: NSObject, ObservableObject {
    typealias AppDownloadState = AppDownloadFlow.State

    @Published private(set) var availability = UpdateAvailability.none
    @Published private(set) var appDownloadState = AppDownloadState.idle

    var onRequestDSHUpdate: ((CachedDSHUpdate) -> Void)?

    private let downloadDriver: AppDownloadDriver
    private let presenter: UpdateOverlayPresenter

    override init() {
        downloadDriver = AppDownloadDriver()
        presenter = UpdateOverlayPresenter()
        super.init()
        appDownloadState = downloadDriver.state
        downloadDriver.onStateChange = { [weak self] state in
            guard let self else { return }
            self.appDownloadState = state
            self.presenter.scheduleLayout()
        }
    }

    var isPresented: Bool { presenter.isPresented }
    var isDownloading: Bool { appDownloadState.isDownloading }

    func updateAvailability(_ availability: UpdateAvailability) {
        self.availability = availability
        downloadDriver.updateCheck(availability.app)
        presenter.scheduleLayout()

        if !availability.hasUpdates, !isDownloading {
            presenter.dismiss()
        } else if isPresented, let app = availability.app {
            prepareAppDownload(for: app)
        }
    }

    func toggle(relativeTo button: NSView) {
        if isPresented {
            guard !isDownloading else { return }
            presenter.dismiss()
            return
        }
        guard availability.hasUpdates else { return }

        downloadDriver.refreshCompletedFileAvailability()
        presenter.present(
            relativeTo: button,
            rootView: UpdateOverlayView(controller: self, presenter: presenter),
            isDismissBlocked: { [weak self] in self?.isDownloading == true },
            onWillDismiss: { [weak self] in
                self?.downloadDriver.cancelDownloadedFileValidation()
            }
        )
        guard isPresented else { return }
        if let app = availability.app {
            prepareAppDownload(for: app)
        }
    }

    func requestDSHUpdate(_ cached: CachedDSHUpdate) {
        guard !isDownloading else { return }
        presenter.dismiss()
        onRequestDSHUpdate?(cached)
    }

    func prepareAppDownload(for check: AppUpdateCheck) {
        guard availability.app == check else { return }
        downloadDriver.prepare(check)
    }

    func downloadAppUpdate(_ check: AppUpdateCheck) {
        guard availability.app == check else { return }
        downloadDriver.download(check)
    }

    func cancelDownload() {
        downloadDriver.cancelTransfer()
    }

    func openReleasePage(_ check: AppUpdateCheck) {
        NSWorkspace.shared.open(check.releasePageURL)
    }

    func revealDownloadedFile(_ result: AppReleaseDownloadResult) {
        validateDownloadedFile(result) {
            NSWorkspace.shared.activateFileViewerSelecting([result.fileURL])
        }
    }

    func openDownloadedDMG(_ result: AppReleaseDownloadResult) {
        validateDownloadedFile(result) {
            NSWorkspace.shared.open(result.fileURL)
        }
    }

    func cancelDownloadedFileValidation() {
        downloadDriver.cancelDownloadedFileValidation()
    }

    func cancelAll() {
        downloadDriver.cancelAll()
    }

    private func validateDownloadedFile(
        _ result: AppReleaseDownloadResult,
        action: @escaping @MainActor () -> Void
    ) {
        downloadDriver.validateDownloadedFile(result, onValidated: action)
    }
}
