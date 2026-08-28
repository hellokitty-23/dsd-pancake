import AppKit
import DSHDesktopCore
import SwiftUI

struct RootView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var isShowingLogs = false

    var body: some View {
        ZStack {
            // 与 NSWindow 和 WKWebView 的首帧底色一致。这样 SwiftUI 尚未完成一次
            // 绘制、以及网页尚未产生真实主题色时，都不会留下默认白底。
            Color(nsColor: AppLaunchSurface.color)
                .ignoresSafeArea()

            Group {
                switch coordinator.presentation {
                case .ready:
                    readyView

                case .checking:
                    progressView(title: "正在检查本机 \(LocalService.hostAndPort)", detail: "不会修改已存在的服务。")
                case .locating:
                    progressView(title: "正在定位 dsh", detail: "仅检查已安装的可执行文件。")
                case .starting:
                    progressView(title: "正在启动本次 DSH 服务", detail: "服务将作为受控子进程运行。")
                case .waitingForService:
                    progressView(title: "正在等待 DSH 就绪", detail: "地址固定为 \(LocalService.url.absoluteString)。")

                case let .unknownExistingService(reason):
                    decisionView(
                        title: "检测到无法确认身份的本机服务",
                        detail: "\(LocalService.hostAndPort) 已有可访问响应（\(unknownReasonText(reason))）。它可能不是 DSH。确认后才会在 WebView 中打开；拒绝不会停止或修改它。",
                        primaryTitle: "确认在 App 中打开",
                        primaryAction: coordinator.acceptUnknownExistingService,
                        secondaryTitle: "不打开",
                        secondaryAction: coordinator.rejectUnknownExistingService
                    )

                case let .portAbnormal(reason):
                    statusView(
                        title: "\(LocalService.port) 端口的响应不能作为 DSH 页面加载",
                        detail: nonHTMLReasonText(reason),
                        primaryTitle: "重新检查",
                        primaryAction: coordinator.retry,
                        retry: false
                    )

                case .dshNotFound:
                    statusView(
                        title: "未找到可执行的 dsh",
                        detail: "请先安装 DSH，或手动选择当前已安装的 dsh 可执行文件。",
                        primaryTitle: "选择 dsh",
                        primaryAction: coordinator.chooseDSHFile,
                        retry: true
                    )

                case let .launchFailed(message):
                    errorView(title: "无法启动本次 DSH 服务", detail: message, retry: true)
                case .readinessTimedOut:
                    statusView(
                        title: "等待 DSH 就绪超时",
                        detail: "本次创建的进程仍受监视，不会重复启动。可继续等待或查看本次内存日志。",
                        primaryTitle: "继续等待",
                        primaryAction: { coordinator.continueWaitingForService() },
                        retry: false
                    )
                case .portConflict:
                    statusView(
                        title: "\(LocalService.port) 已被其他服务占用",
                        detail: "本次创建的 dsh 仍在受监督，但它没有监听 \(LocalService.hostAndPort)。为避免把其他服务误认为 owned，App 不会加载或停止该端口服务；可重新检查或查看本次内存日志。",
                        primaryTitle: "重新检查",
                        primaryAction: { coordinator.continueWaitingForService() },
                        retry: false
                    )
                case .listenerLost:
                    statusView(
                        title: "本次 DSH 已不再监听 \(LocalService.hostAndPort)",
                        detail: "App 仍只监督自己创建的子进程，但已永久关闭本轮 native bridge（原生桥接）。可重新检查端口；若页面恢复，只会按重新验证后的归属加载。",
                        primaryTitle: "重新检查",
                        primaryAction: { coordinator.continueWaitingForService() },
                        retry: false
                    )
                case .ownershipLost:
                    statusView(
                        title: "已失去本次子进程的停止权",
                        detail: "为避免误停其他服务，App 不会再对该 PID 发送信号。可以重新检查 \(LocalService.hostAndPort)；此操作只探测服务，不会创建或停止进程。",
                        primaryTitle: "重新检查",
                        primaryAction: coordinator.retry,
                        retry: false
                    )
                case .serviceStopped:
                    statusView(
                        title: "DSH 服务未运行",
                        detail: "可以重新检查 \(LocalService.hostAndPort)，若端口空闲，App 才会启动本次受控 DSH。",
                        primaryTitle: "重新检查",
                        primaryAction: coordinator.retry,
                        retry: false
                    )
                case .drainingCleanup:
                    statusView(
                        title: "正在排空本次进程遗留的日志",
                        detail: "主进程已不再具有停止权。App 会继续读取 stdout/stderr，自然 EOF 前不会再次启动 DSH。可以重新检查 \(LocalService.hostAndPort)；此操作只探测服务，不会创建或停止进程。",
                        primaryTitle: "重新检查",
                        primaryAction: coordinator.retry,
                        retry: false
                    )
                case let .terminalUnavailable(code):
                    statusView(
                        title: "当前会话无法可靠回收子进程",
                        detail: "waitpid 返回错误 \(code)。本次 App 会话已永久禁止再次启动 DSH；不会猜测 PID 或发送信号。重新打开 App 后只会按 external 服务重新探测。",
                        retry: false
                    )
                case .preparingDependencyUpdate:
                    progressView(
                        title: "正在安全停止本次 DSH",
                        detail: "进程和日志完全收敛后才会更新 DeepSeek Harness。"
                    )
                case .updatingDependency:
                    progressView(
                        title: "正在更新 DeepSeek Harness",
                        detail: "只修改已确认的全局 npm 安装，完成后会重新启动 DSH。"
                    )
                case .stopping:
                    progressView(title: "正在等待本次 DSH 退出", detail: "不会使用强制结束，也不会关闭日志读取端。")
                case .stopTimedOut:
                    errorView(title: "DSH 或日志清理仍未结束", detail: "请在退出确认中选择继续等待或取消退出。", retry: false)
                }
            }

            Group {
                if let confirmation = coordinator.quitConfirmation {
                    QuitConfirmationHUD(
                        stopsOwnedService: confirmation.stopsOwnedService,
                        onCancel: coordinator.cancelQuitConfirmation
                    )
                        .zIndex(1)
                }
            }
            .animation(
                .easeOut(duration: 0.18),
                value: coordinator.quitConfirmation?.transactionID
            )
        }
        .frame(minWidth: 880, minHeight: 560)
        .onChange(of: coordinator.quitConfirmation?.transactionID) { transactionID in
            // 自定义 HUD 位于主窗口内容层；先收起日志 sheet，避免确认提示被另一个
            // 原生 sheet 盖住而无法看见。
            if transactionID != nil {
                isShowingLogs = false
            }
        }
        .sheet(isPresented: $isShowingLogs) {
            LogSheet(entries: coordinator.logEntries)
        }
    }

    private var readyView: some View {
        VStack(spacing: 0) {
            if let container = coordinator.webContainer {
                ReadyWebView(
                    container: container,
                    terminalController: coordinator.terminalController
                )
            } else {
                progressView(title: "正在准备网页容器", detail: "不会创建第二个 WebView。")
            }
        }
    }

    private func progressView(title: String, detail: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(36)
    }

    private func errorView(title: String, detail: String, retry: Bool) -> some View {
        if retry {
            statusView(
                title: title,
                detail: detail,
                primaryTitle: "重试",
                primaryAction: { coordinator.retry() },
                retry: true
            )
        } else {
            statusView(title: title, detail: detail, retry: false)
        }
    }

    private func decisionView(
        title: String,
        detail: String,
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryTitle: String,
        secondaryAction: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 580)
            HStack {
                Button(secondaryTitle, action: secondaryAction)
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(36)
    }

    private func statusView(
        title: String,
        detail: String,
        primaryTitle: String? = nil,
        primaryAction: (() -> Void)? = nil,
        retry: Bool
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 580)
            HStack {
                if let primaryTitle, let primaryAction {
                    Button(primaryTitle, action: primaryAction)
                        .buttonStyle(.borderedProminent)
                }
                if retry && primaryTitle != "选择 dsh" {
                    Button("选择 dsh", action: coordinator.chooseDSHFile)
                }
                Button("查看本次日志") {
                    coordinator.showLogs()
                    isShowingLogs = true
                }
            }
        }
        .padding(36)
    }

    private func unknownReasonText(_ reason: ReachableUnknownReason) -> String {
        switch reason {
        case .manifestMissing: "未找到 manifest.webmanifest"
        case .manifestInvalid: "manifest 内容不匹配 DSH"
        case .manifestRedirectRejected: "manifest 重定向不在本机同源范围内"
        case .manifestRequestFailed: "manifest 请求失败"
        }
    }

    private func nonHTMLReasonText(_ reason: ReachableNonHTMLReason) -> String {
        switch reason {
        case .rootCrossOriginRedirect: "根路径重定向到了非本机同源地址。"
        case let .rootNon2xx(status): "根路径返回 HTTP \(status)。"
        case let .rootNotHTML(contentType): "根路径不是 HTML（Content-Type：\(contentType ?? "缺失")）。"
        case .rootRedirectLoop: "根路径重定向次数超过上限。"
        case .rootBodyTooLarge: "根路径响应超过探测上限。"
        case .rootInvalidResponse: "根路径返回了无效响应。"
        }
    }
}

private struct ReadyWebView: View {
    @ObservedObject var container: WebContainer
    let terminalController: DesktopTerminalController

    var body: some View {
        ZStack {
            Color(nsColor: AppLaunchSurface.color)

            TerminalDockHost(
                container: container,
                terminalController: terminalController,
                isPageLoading: container.isPageLoading
            )
                .allowsHitTesting(!container.isPageLoading)

            if container.isPageLoading {
                // 与原生 loading cover（加载遮罩）同时存在：SwiftUI 层负责可见的
                // 进度反馈，原生层负责覆盖 NSViewRepresentable 首次挂载的极短窗口。
                // 两层都不隐藏 WKWebView，因此它仍能完成导航和首帧绘制。
                ZStack {
                    Color(nsColor: AppLaunchSurface.color)
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("正在打开 DSH")
                            .font(.headline)
                        Text("正在加载本机网页…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                }
                .allowsHitTesting(false)
            }
        }
            .overlay(alignment: .bottomLeading) {
                if let notice = container.navigationMessage {
                    HStack(spacing: 8) {
                        Text(notice.text)
                        if notice.showsReloadAction {
                            Button("重新加载") {
                                container.reload()
                            }
                            .buttonStyle(.borderless)
                        }
                        if !notice.dismissesAutomatically {
                            Button {
                                container.dismissNavigationMessage()
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .help("关闭提示")
                            .accessibilityLabel("关闭提示")
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding(12)
                    .transition(.opacity)
                }
            }
    }
}

private struct LogSheet: View {
    let entries: [LogEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本次会话内存日志")
                .font(.headline)
            if entries.isEmpty {
                Text("当前没有由本 App 启动的 DSH 日志。")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                            Text("[\(entry.stream.rawValue)] \(entry.text)")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 420)
    }
}
