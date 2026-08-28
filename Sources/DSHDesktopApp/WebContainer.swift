import AppKit
import Combine
import DSHDesktopCore
import SwiftUI
import WebKit

/// 原生壳层的导航反馈；成功提示短暂显示，真正需要恢复的网页错误才提供重新加载。
struct NavigationNotice: Equatable {
    let id = UUID()
    let text: String
    let dismissesAutomatically: Bool
    let showsReloadAction: Bool
}

/// 一个会话只创建一个 WKWebView，避免在状态切换或窗口恢复时丢失 DSH 的页面状态。
@MainActor
final class WebContainer: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var navigationMessage: NavigationNotice?
    @Published private(set) var isPageLoading = true

    let webView: WKWebView

    /// 仅用于同步标题栏视觉数据；页面尚未就绪或不支持时为 `nil`，原生层自动回退。
    var onChromeStyleChange: ((ChromeSurfaceStyle?) -> Void)? {
        didSet {
            onChromeStyleChange?(chromeStyle)
        }
    }

    private let navigationPolicy = WebNavigationPolicy()
    private let userContentController: WKUserContentController
    private let notificationCoordinator: NotificationCoordinator
    private let terminalController: DesktopTerminalController
    private var chromeStyleMessageHandler: ChromeStyleMessageHandler?
    private var notificationMessageHandler: NotificationMessageHandler?
    private var terminalMessageHandler: TerminalMessageHandler?
    private var navigationMessageDismissalTask: Task<Void, Never>?
    private var notificationBridgeEnabled = false
    private var terminalBridgeEnabled = false
    private var terminalConversationReservation: CGFloat = 0
    /// `didFinish` 只表示导航结束，不保证 DSH 的 CSS 与根布局已经完成首帧绘制。
    /// 在收到 Chrome bridge 的有效视觉数据前持续保留启动层，避免 WebKit 白帧。
    private var didFinishCurrentNavigation = false
    private var presentationFallbackTask: Task<Void, Never>?
    private var chromeStyle: ChromeSurfaceStyle? {
        didSet {
            guard chromeStyle != oldValue else { return }
            onChromeStyleChange?(chromeStyle)
        }
    }

    init(
        notificationCoordinator: NotificationCoordinator,
        terminalController: DesktopTerminalController
    ) {
        self.notificationCoordinator = notificationCoordinator
        self.terminalController = terminalController
        let configuration = WKWebViewConfiguration()
        userContentController = WKUserContentController()
        configuration.userContentController = userContentController
        // 默认 data store 是持久化存储。唯一的页面桥只读取布局宽度与已计算背景色，
        // 不读取文字、会话、Cookie，也不写入 DOM 或改变 DSH 功能。
        configuration.websiteDataStore = AppRuntimeConfiguration.current.usesPersistentWebDataStore
            ? .default()
            : .nonPersistent()
        precondition(
            configuration.websiteDataStore.isPersistent
                == AppRuntimeConfiguration.current.usesPersistentWebDataStore,
            "WebKit 数据存储必须与正式／隔离 Test App 身份一致"
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        let messageHandler = ChromeStyleMessageHandler(container: self)
        chromeStyleMessageHandler = messageHandler
        userContentController.add(messageHandler, name: ChromeStyleBridge.messageName)

        let notificationHandler = NotificationMessageHandler(container: self)
        notificationMessageHandler = notificationHandler
        userContentController.addScriptMessageHandler(
            notificationHandler,
            contentWorld: .page,
            name: DesktopNotificationBridge.messageName
        )

        let terminalHandler = TerminalMessageHandler(container: self)
        terminalMessageHandler = terminalHandler
        userContentController.addScriptMessageHandler(
            terminalHandler,
            contentWorld: .page,
            name: DesktopTerminalBridge.messageName
        )
        userContentController.addUserScript(
            WKUserScript(
                source: ChromeStyleBridge.script,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        // WebKit 在首个页面提交前默认绘制纯白。先给它与原生窗口一致的深色底色，
        // 再在页面完成真实首帧后揭示，避免启动时出现白屏闪烁。
        webView.underPageBackgroundColor = AppLaunchSurface.color
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    /// 是否启用由 AppCoordinator 的 DSH 所有权与 `--patch` 启动结果决定。handler
    /// 固定注册但默认拒绝，避免已存在的网页服务意外获得原生通知能力。
    func setNotificationBridgeEnabled(_ enabled: Bool) {
        notificationBridgeEnabled = enabled
    }

    /// 终端 bridge 只由 AppCoordinator 在“本次 App 创建的 DSH 已验证归属且私有 patch
    /// 已准备”时开启。handler 虽已注册，但关闭状态不处理任何能力请求。
    func setTerminalBridgeEnabled(_ enabled: Bool) {
        guard terminalBridgeEnabled != enabled else { return }
        terminalBridgeEnabled = enabled
        if enabled {
            publishTerminalConversationReservation()
        } else {
            setTerminalConversationReservation(0)
        }
    }

    /// 原生 dock 的实际高度由 `TerminalDockContainer` 在每次展开、收起、窗口缩放或
    /// 分隔线拖动后给出。它是单向、纯视觉状态：只允许 App 私有插件将右侧对话流
    /// 顶起，不会增加网页到原生层的任何能力。
    func setTerminalConversationReservation(_ height: CGFloat) {
        let normalized: CGFloat
        if terminalBridgeEnabled, height.isFinite, height > 0 {
            // 防御 WebKit 的意外大数；正常值已在 TerminalDockLayout 中受窗口高度钳制。
            normalized = min(height, 20_000)
        } else {
            normalized = 0
        }
        guard terminalConversationReservation != normalized else { return }
        terminalConversationReservation = normalized
        publishTerminalConversationReservation()
    }

    func loadLocalService() {
        var request = URLRequest(url: LocalService.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        beginPageLoad()
        webView.load(request)
        dismissNavigationMessage()
    }

    func reload() {
        beginPageLoad()
        webView.reload()
        dismissNavigationMessage()
    }

    func dismissNavigationMessage() {
        replaceNavigationMessage(with: nil)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        beginPageLoad()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        didFinishCurrentNavigation = true
        revealPageAfterFirstPaintIfReady()
        schedulePresentationFallback()
        publishTerminalConversationReservation()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            showPersistentNavigationMessage("已阻止没有地址的页面跳转。")
            decisionHandler(.cancel)
            return
        }

        let isNewWindowRequest = navigationAction.targetFrame == nil
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let isUserInitiated = navigationAction.navigationType == .linkActivated
        let decision = navigationPolicy.decision(
            for: url,
            isMainFrame: isMainFrame,
            isUserInitiated: isUserInitiated
        )

        switch decision {
        case .allowInWebView:
            if isNewWindowRequest {
                // 同源 target=_blank 在现有 WebView 中打开，绝不创建第二个窗口。
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }

        case .openInDefaultBrowser:
            openInDefaultBrowser(url)
            decisionHandler(.cancel)

        case let .cancelAndExplain(message):
            showPersistentNavigationMessage(message)
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // 理论上 target=_blank 已由 navigation delegate 处理；这里保持无新窗口兜底。
        guard let url = navigationAction.request.url else { return nil }
        let isUserInitiated = navigationAction.navigationType == .linkActivated
        switch navigationPolicy.decision(for: url, isMainFrame: true, isUserInitiated: isUserInitiated) {
        case .allowInWebView:
            webView.load(navigationAction.request)
        case .openInDefaultBrowser:
            openInDefaultBrowser(url)
        case let .cancelAndExplain(message):
            showPersistentNavigationMessage(message)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        presentationFallbackTask?.cancel()
        presentationFallbackTask = nil
        isPageLoading = false
        showPersistentNavigationMessage("页面加载失败：\(error.localizedDescription)", showsReloadAction: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        presentationFallbackTask?.cancel()
        presentationFallbackTask = nil
        isPageLoading = false
        showPersistentNavigationMessage("页面加载中断：\(error.localizedDescription)", showsReloadAction: true)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        presentationFallbackTask?.cancel()
        presentationFallbackTask = nil
        isPageLoading = false
        resetChromeStyle()
        showPersistentNavigationMessage("网页进程已结束；可使用“重新加载”恢复。", showsReloadAction: true)
    }

    /// 仅由同模块的 WebKit Chrome handler 调用；解码失败不会改变原生样式。
    func receiveChromeStyleMessage(_ body: Any) {
        guard let style = ChromeStyleBridge.decode(body) else { return }
        chromeStyle = style
        revealPageAfterFirstPaintIfReady()
    }

    private func beginPageLoad() {
        presentationFallbackTask?.cancel()
        presentationFallbackTask = nil
        didFinishCurrentNavigation = false
        isPageLoading = true
        resetChromeStyle()
    }

    /// Chrome bridge 在 `requestAnimationFrame`（下一帧绘制前回调）中读取布局和颜色，
    /// 收到有效数据即代表 DSH 已经拥有可展示的表面。此时再显示 WKWebView，可避免
    /// `didFinish` 之后 CSS 或前端 hydration（客户端初始化）尚未完成的闪帧。
    private func revealPageAfterFirstPaintIfReady() {
        guard didFinishCurrentNavigation, chromeStyle != nil else { return }
        presentationFallbackTask?.cancel()
        presentationFallbackTask = nil
        isPageLoading = false
    }

    /// 个别异常页面可能无法提供 Chrome bridge；保留有限后备，避免加载层永久停留。
    /// 正常 DSH 启动由上面的 bridge 路径立即揭示，不会走此分支。
    private func schedulePresentationFallback() {
        guard isPageLoading, presentationFallbackTask == nil else { return }
        presentationFallbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 600_000_000)
            } catch {
                return
            }
            guard let self, self.didFinishCurrentNavigation else { return }
            self.presentationFallbackTask = nil
            self.isPageLoading = false
        }
    }

    /// 仅由同模块的 WebKit 通知 handler 调用；能力与 origin 准入保留在这里。
    func receiveNotificationMessage(
        _ body: Any,
        frameInfo: WKFrameInfo
    ) async -> [String: Any]? {
        guard let action = DesktopNotificationBridgeAdmission.decode(
            body,
            bridgeEnabled: notificationBridgeEnabled,
            isMainFrame: frameInfo.isMainFrame,
            originScheme: frameInfo.securityOrigin.protocol,
            originHost: frameInfo.securityOrigin.host,
            originPort: frameInfo.securityOrigin.port
        ) else {
            return nil
        }
        return await notificationCoordinator.handle(action)
    }

    /// 仅由同模块的 WebKit 终端 handler 调用；严格 admission（准入）仍在这里完成。
    func receiveTerminalMessage(
        _ body: Any,
        frameInfo: WKFrameInfo
    ) -> [String: Any]? {
        guard let action = DesktopTerminalBridgeAdmission.decode(
            body,
            bridgeEnabled: terminalBridgeEnabled,
            isMainFrame: frameInfo.isMainFrame,
            originScheme: frameInfo.securityOrigin.protocol,
            originHost: frameInfo.securityOrigin.host,
            originPort: frameInfo.securityOrigin.port
        ) else { return nil }
        return terminalController.handle(action)
    }

    private func resetChromeStyle() {
        chromeStyle = nil
    }

    /// 页面加载早于或晚于原生 dock 都是合法状态，所以同时保留最后值并在 didFinish
    /// 重发。这里不扫描或改写 DSH DOM；客户端插件只读取这个版本化事件，并在正式
    /// composer footer slot 中渲染一个不可交互的高度占位。
    private func publishTerminalConversationReservation() {
        let height = terminalBridgeEnabled ? terminalConversationReservation : 0
        let heightLiteral = String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            height
        )
        let openLiteral = height > 0 ? "true" : "false"
        let script = """
        (() => {
          const detail = Object.freeze({
            version: 1,
            open: \(openLiteral),
            reservedHeight: \(heightLiteral),
          });
          window.__dshDesktopTerminalDockLayout = detail;
          window.dispatchEvent(new CustomEvent("dsd-pancake-terminal-layout", { detail }));
        })();
        """
        webView.evaluateJavaScript(script) { _, _ in
            // 在页面提交前或网页进程退出时，WebKit 可以拒绝这一次纯视觉推送；
            // didFinish 会使用已保存的最新值重发，不需要记录网页错误或重试循环。
        }
    }

    private func openInDefaultBrowser(_ url: URL) {
        guard NSWorkspace.shared.open(url) else {
            showPersistentNavigationMessage("无法在默认浏览器打开该外部链接。")
            return
        }
        showTransientNavigationMessage("已在默认浏览器打开你点击的外部链接。")
    }

    private func showTransientNavigationMessage(_ text: String) {
        let notice = NavigationNotice(
            text: text,
            dismissesAutomatically: true,
            showsReloadAction: false
        )
        replaceNavigationMessage(with: notice)

        navigationMessageDismissalTask = Task { @MainActor [weak self, noticeID = notice.id] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }

            guard let self, self.navigationMessage?.id == noticeID else { return }
            self.dismissNavigationMessage()
        }
    }

    private func showPersistentNavigationMessage(_ text: String, showsReloadAction: Bool = false) {
        replaceNavigationMessage(
            with: NavigationNotice(
                text: text,
                dismissesAutomatically: false,
                showsReloadAction: showsReloadAction
            )
        )
    }

    private func replaceNavigationMessage(with message: NavigationNotice?) {
        navigationMessageDismissalTask?.cancel()
        navigationMessageDismissalTask = nil
        withAnimation(.easeOut(duration: 0.18)) {
            navigationMessage = message
        }
    }
}
