import AppKit
import Combine
import DSHDesktopCore
import SwiftUI

@MainActor
final class UpdatePopoverController: NSObject, ObservableObject {
    enum AppDownloadState: Equatable {
        case idle
        case verifyingChecksum
        case readyToDownload
        case downloading(Double?)
        case completed(AppReleaseDownloadResult)
        case checksumUnavailable(String)
        case failed(String)

        var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }
    }

    @Published private(set) var availability = UpdateAvailability.none
    @Published private(set) var appDownloadState = AppDownloadState.idle

    var onRequestDSHUpdate: ((CachedDSHUpdate) -> Void)?

    private let downloadService = AppReleaseDownloadService()
    private var checksumTask: Task<Void, Never>?
    private var checksumCancellation: AppReleaseDownloadCancellation?
    private var checksumReadyVersion: SemanticVersion?
    private var downloadTask: Task<Void, Never>?
    private var downloadCancellation: AppReleaseDownloadCancellation?
    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: UpdatePopoverView(controller: self)
        )
        return popover
    }()

    deinit {
        checksumCancellation?.cancel()
        checksumTask?.cancel()
        downloadCancellation?.cancel()
        downloadTask?.cancel()
    }

    var isDownloading: Bool {
        appDownloadState.isDownloading
    }

    func updateAvailability(_ availability: UpdateAvailability) {
        let previousAppVersion = self.availability.app?.latestVersion
        self.availability = availability
        let currentAppVersion = availability.app?.latestVersion
        if previousAppVersion != currentAppVersion, !isDownloading {
            cancelChecksumVerification()
            checksumReadyVersion = nil
            appDownloadState = .idle
        }
        if !availability.hasUpdates,
           !isDownloading,
           popover.isShown {
            popover.performClose(nil)
        } else if popover.isShown, let app = availability.app {
            prepareAppDownload(for: app)
        }
    }

    func toggle(relativeTo button: NSView) {
        if popover.isShown {
            guard !isDownloading else { return }
            popover.performClose(nil)
            return
        }
        guard availability.hasUpdates else { return }
        popover.behavior = .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let app = availability.app {
            prepareAppDownload(for: app)
        }
    }

    func requestDSHUpdate(_ cached: CachedDSHUpdate) {
        guard !isDownloading, downloadTask == nil else { return }
        popover.performClose(nil)
        onRequestDSHUpdate?(cached)
    }

    func downloadAppUpdate(_ check: AppUpdateCheck) {
        guard downloadTask == nil,
              checksumTask == nil,
              checksumReadyVersion == check.latestVersion,
              appDownloadState == .readyToDownload else {
            return
        }
        let cancellation = AppReleaseDownloadCancellation()
        downloadCancellation = cancellation
        appDownloadState = .downloading(nil)
        // 下载中保留 Popover，避免用户误点页面背景后失去取消和文件位置入口。
        popover.behavior = .applicationDefined
        downloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await downloadService.download(
                    check: check,
                    cancellation: cancellation
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloadTask != nil else { return }
                        self.appDownloadState = .downloading(progress)
                    }
                }
                guard !Task.isCancelled else { return }
                appDownloadState = .completed(result)
            } catch is CancellationError {
                appDownloadState = .idle
            } catch let error as AppReleaseDownloadError {
                if case .checksumUnavailable = error {
                    appDownloadState = .checksumUnavailable(error.localizedDescription)
                } else {
                    appDownloadState = .failed(error.localizedDescription)
                }
            } catch {
                appDownloadState = .failed(error.localizedDescription)
            }
            downloadTask = nil
            if downloadCancellation === cancellation {
                downloadCancellation = nil
            }
            popover.behavior = .transient
        }
    }

    func cancelDownload() {
        cancelChecksumVerification()
        downloadCancellation?.cancel()
        downloadTask?.cancel()
    }

    /// 用户已主动打开 Popover 后只读取 sidecar；直到成功验证前，界面绝不显示可开始
    /// DMG 传输的按钮。旧 Release 缺失 sidecar 时保持“发布页”这一条安全路径。
    func prepareAppDownload(for check: AppUpdateCheck) {
        guard availability.app?.latestVersion == check.latestVersion,
              checksumTask == nil,
              downloadTask == nil else {
            return
        }
        if checksumReadyVersion == check.latestVersion,
           appDownloadState == .readyToDownload {
            return
        }
        if case .completed = appDownloadState {
            return
        }

        let cancellation = AppReleaseDownloadCancellation()
        checksumCancellation = cancellation
        checksumReadyVersion = nil
        appDownloadState = .verifyingChecksum
        checksumTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await downloadService.verifyChecksum(for: check, cancellation: cancellation)
                guard !Task.isCancelled,
                      availability.app?.latestVersion == check.latestVersion else {
                    return
                }
                checksumReadyVersion = check.latestVersion
                appDownloadState = .readyToDownload
            } catch is CancellationError {
                if availability.app?.latestVersion == check.latestVersion {
                    appDownloadState = .idle
                }
            } catch let error as AppReleaseDownloadError {
                checksumReadyVersion = nil
                if case .checksumUnavailable = error {
                    appDownloadState = .checksumUnavailable(error.localizedDescription)
                } else {
                    appDownloadState = .failed(error.localizedDescription)
                }
            } catch {
                checksumReadyVersion = nil
                appDownloadState = .failed(error.localizedDescription)
            }
            if checksumCancellation === cancellation {
                checksumCancellation = nil
                checksumTask = nil
            }
        }
    }

    private func cancelChecksumVerification() {
        checksumCancellation?.cancel()
        checksumTask?.cancel()
        checksumCancellation = nil
        checksumTask = nil
        if case .verifyingChecksum = appDownloadState {
            appDownloadState = .idle
        }
    }

    func openReleasePage(_ check: AppUpdateCheck) {
        NSWorkspace.shared.open(check.releasePageURL)
    }

    func revealDownloadedFile(_ result: AppReleaseDownloadResult) {
        NSWorkspace.shared.activateFileViewerSelecting([result.fileURL])
    }

    func openDownloadedDMG(_ result: AppReleaseDownloadResult) {
        NSWorkspace.shared.open(result.fileURL)
    }
}

private struct UpdatePopoverView: View {
    @ObservedObject var controller: UpdatePopoverController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("发现可选更新")
                .font(.headline)

            if let app = controller.availability.app {
                appSection(app)
            }

            if controller.availability.app != nil, controller.availability.dsh != nil {
                Divider()
            }

            if let dsh = controller.availability.dsh {
                dshSection(dsh)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    @ViewBuilder
    private func appSection(_ check: AppUpdateCheck) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DSD Pancake")
                .font(.subheadline.weight(.semibold))
            Text(check.currentVersion.description + " → " + check.latestVersion.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            switch controller.appDownloadState {
            case .idle:
                HStack {
                    Button("验证下载信息") {
                        controller.prepareAppDownload(for: check)
                    }
                    Button("发布页") {
                        controller.openReleasePage(check)
                    }
                }
            case .verifyingChecksum:
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView()
                    Text("正在验证 Release 的 SHA-256 校验文件…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("发布页") {
                        controller.openReleasePage(check)
                    }
                }
            case .readyToDownload:
                HStack {
                    Button("下载更新") {
                        controller.downloadAppUpdate(check)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("发布页") {
                        controller.openReleasePage(check)
                    }
                }
            case let .downloading(progress):
                VStack(alignment: .leading, spacing: 6) {
                    if let progress {
                        ProgressView(value: progress)
                        Text("正在下载 \(Int((progress * 100).rounded()))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                        Text("正在下载…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("取消下载") {
                        controller.cancelDownload()
                    }
                }
            case let .completed(result):
                Text("已校验 SHA-256 并保存到 Downloads。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("在 Finder 中显示") {
                        controller.revealDownloadedFile(result)
                    }
                    Button("打开 DMG") {
                        controller.openDownloadedDMG(result)
                    }
                }
            case let .checksumUnavailable(message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("打开发布页") {
                    controller.openReleasePage(check)
                }
            case let .failed(message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                HStack {
                    Button("重试验证") {
                        controller.prepareAppDownload(for: check)
                    }
                    Button("打开发布页") {
                        controller.openReleasePage(check)
                    }
                }
            }
        }
    }

    private func dshSection(_ cached: CachedDSHUpdate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DeepSeek Harness")
                .font(.subheadline.weight(.semibold))
            Text(cached.currentVersion.description + " → " + cached.latestVersion.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("更新 DSH…") {
                controller.requestDSHUpdate(cached)
            }
        }
    }
}
