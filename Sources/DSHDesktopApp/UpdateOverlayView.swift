import DSHDesktopCore
import SwiftUI

/// 更新浮层的纯渲染层。按钮只发送 intent（用户意图）给稳定 controller façade，
/// 不持有 Task、URLSession、文件句柄或 AppKit attachment（挂接）状态。
struct UpdateOverlayView: View {
    @ObservedObject var controller: UpdateOverlayController
    @ObservedObject var presenter: UpdateOverlayPresenter

    var body: some View {
        VStack(alignment: .leading, spacing: -1) {
            ZStack(alignment: .leading) {
                Color.clear.frame(height: 9)
                UpdateOverlayArrow()
                    .fill(.regularMaterial)
                    .frame(width: 18, height: 9)
                    .offset(x: presenter.arrowX - 9)
            }
            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
        .frame(width: presenter.surfaceWidth)
        .fixedSize(horizontal: false, vertical: true)
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("可选更新")
    }

    private var content: some View {
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
                actionLayout {
                    Button("验证下载信息") { controller.prepareAppDownload(for: check) }
                    Button("发布页") { controller.openReleasePage(check) }
                }
            case .verifyingChecksum:
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView()
                    Text("正在验证 Release 的 SHA-256 校验文件…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("发布页") { controller.openReleasePage(check) }
                }
            case .readyToDownload:
                actionLayout {
                    Button("下载更新") { controller.downloadAppUpdate(check) }
                        .buttonStyle(.borderedProminent)
                    Button("发布页") { controller.openReleasePage(check) }
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
                    Button("取消下载") { controller.cancelDownload() }
                }
            case let .completed(result):
                Text("已校验 SHA-256 并保存到下载目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                actionLayout {
                    Button("在 Finder 中显示") { controller.revealDownloadedFile(result) }
                    Button("打开 DMG") { controller.openDownloadedDMG(result) }
                }
            case .validatingDownloadedFile:
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView()
                    Text("正在重新验证已下载文件的 SHA-256…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("取消") { controller.cancelDownloadedFileValidation() }
                }
            case let .checksumUnavailable(message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("打开发布页") { controller.openReleasePage(check) }
            case let .failed(message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                actionLayout {
                    Button("重试验证") { controller.prepareAppDownload(for: check) }
                    Button("打开发布页") { controller.openReleasePage(check) }
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
            Button("更新 DSH…") { controller.requestDSHUpdate(cached) }
        }
    }

    @ViewBuilder
    private func actionLayout<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if presenter.usesCompactActions {
            VStack(alignment: .leading, spacing: 8) { content() }
        } else {
            HStack(spacing: 8) { content() }
        }
    }
}

private struct UpdateOverlayArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
