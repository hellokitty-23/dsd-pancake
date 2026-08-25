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
    private var chromeStyleMessageHandler: ChromeStyleMessageHandler?
    private var navigationMessageDismissalTask: Task<Void, Never>?
    private var chromeStyle: ChromeSurfaceStyle? {
        didSet {
            guard chromeStyle != oldValue else { return }
            onChromeStyleChange?(chromeStyle)
        }
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        userContentController = WKUserContentController()
        configuration.userContentController = userContentController
        // 默认 data store 是持久化存储。唯一的页面桥只读取布局宽度与已计算背景色，
        // 不读取文字、会话、Cookie，也不写入 DOM 或改变 DSH 功能。
        configuration.websiteDataStore = .default()
        precondition(configuration.websiteDataStore.isPersistent, "DSD Pancake 必须使用持久 WKWebsiteDataStore")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        let messageHandler = ChromeStyleMessageHandler(container: self)
        chromeStyleMessageHandler = messageHandler
        userContentController.add(messageHandler, name: ChromeStyleBridge.messageName)
        userContentController.addUserScript(
            WKUserScript(
                source: ChromeStyleBridge.script,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        // WebKit 在首个页面提交前默认绘制纯白。先给它与原生窗口一致的底色，
        // 再由 SwiftUI 的加载层遮住尚未完成的页面，避免启动时出现白屏闪烁。
        webView.underPageBackgroundColor = .windowBackgroundColor
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func loadLocalService() {
        var request = URLRequest(url: LocalService.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        isPageLoading = true
        resetChromeStyle()
        webView.load(request)
        dismissNavigationMessage()
    }

    func reload() {
        isPageLoading = true
        resetChromeStyle()
        webView.reload()
        dismissNavigationMessage()
    }

    func dismissNavigationMessage() {
        replaceNavigationMessage(with: nil)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        isPageLoading = true
        resetChromeStyle()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        isPageLoading = false
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
        isPageLoading = false
        showPersistentNavigationMessage("页面加载失败：\(error.localizedDescription)", showsReloadAction: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        isPageLoading = false
        showPersistentNavigationMessage("页面加载中断：\(error.localizedDescription)", showsReloadAction: true)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isPageLoading = false
        resetChromeStyle()
        showPersistentNavigationMessage("网页进程已结束；可使用“重新加载”恢复。", showsReloadAction: true)
    }

    fileprivate func receiveChromeStyleMessage(_ body: Any) {
        guard let style = ChromeStyleBridge.decode(body) else { return }
        chromeStyle = style
    }

    private func resetChromeStyle() {
        chromeStyle = nil
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

private final class ChromeStyleMessageHandler: NSObject, WKScriptMessageHandler {
    weak var container: WebContainer?

    init(container: WebContainer) {
        self.container = container
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == ChromeStyleBridge.messageName else { return }
        Task { @MainActor [weak container] in
            container?.receiveChromeStyleMessage(message.body)
        }
    }
}

private enum ChromeStyleBridge {
    static let messageName = "dshDesktopChromeStyle"

    /// 只读取 DSH 页面根布局的几何和已计算的表面色。它不读取文字、会话、Cookie，
    /// 不写入 DOM，也不拦截键鼠或修改 DSH 功能。
    static let script = #"""
    (() => {
      "use strict";
      const bridgeName = "dshDesktopChromeStyle";
      if (window.__dshDesktopChromeStyleBridgeInstalled) return;
      Object.defineProperty(window, "__dshDesktopChromeStyleBridgeInstalled", {
        value: true,
        configurable: false,
        writable: false,
      });

      const messageHandler = window.webkit && window.webkit.messageHandlers
        ? window.webkit.messageHandlers[bridgeName]
        : null;
      if (!messageHandler || typeof messageHandler.postMessage !== "function") return;

      const finite = (value) => Number.isFinite(value);
      const colorPattern = /^rgba?\(\s*([0-9.]+)[,\s]+([0-9.]+)[,\s]+([0-9.]+)(?:[,\s/]+([0-9.]+))?\s*\)$/i;

      const parseColor = (value) => {
        const match = colorPattern.exec(value || "");
        if (!match) return null;
        const red = Number(match[1]);
        const green = Number(match[2]);
        const blue = Number(match[3]);
        const alpha = match[4] === undefined ? 1 : Number(match[4]);
        if (![red, green, blue, alpha].every(finite)) return null;
        if (red < 0 || red > 255 || green < 0 || green > 255 || blue < 0 || blue > 255 || alpha < 0 || alpha > 1) return null;
        return { red, green, blue, alpha };
      };

      const opaqueBackground = (element, fallback) => {
        for (let node = element; node instanceof Element; node = node.parentElement) {
          const color = parseColor(getComputedStyle(node).backgroundColor);
          if (color && color.alpha > 0.01) return color;
        }
        return fallback;
      };

      const findFrame = () => {
        const root = document.getElementById("root") || document.body;
        if (!root) return null;
        const viewportWidth = window.innerWidth;
        const viewportHeight = window.innerHeight;
        // 兼容 DSH 将根节点本身设为网格，或在根节点下再包一层的两种实现。
        for (const candidate of [root, ...root.querySelectorAll("*")]) {
          const rect = candidate.getBoundingClientRect();
          if (rect.left > 1 || rect.top > 1 || rect.width < viewportWidth - 2 || rect.height < viewportHeight - 2) continue;
          const style = getComputedStyle(candidate);
          if (style.display !== "grid") continue;
          if (candidate.children.length < 2) continue;
          const sidebar = candidate.children[0];
          const sidebarRect = sidebar.getBoundingClientRect();
          if (sidebarRect.left > 1 || sidebarRect.width <= 0 || sidebarRect.width >= viewportWidth * 0.75) continue;
          return { frame: candidate, sidebar };
        }
        return null;
      };

      let observedFrame = null;
      let observedSidebar = null;
      let lastSerialized = "";
      let scheduled = false;
      const resizeObserver = new ResizeObserver(() => schedule());

      const cachedLayout = () => {
        if (!observedFrame || !observedSidebar) return null;
        if (!observedFrame.isConnected || !observedSidebar.isConnected) return null;
        if (observedSidebar.parentElement !== observedFrame) return null;
        return { frame: observedFrame, sidebar: observedSidebar };
      };

      const invalidateLayout = () => {
        resizeObserver.disconnect();
        observedFrame = null;
        observedSidebar = null;
        lastSerialized = "";
        schedule();
      };

      const publish = () => {
        scheduled = false;
        // 首次或根布局替换时才遍历页面。侧栏拖动会触发 ResizeObserver，
        // 后续帧直接复用这两个节点，避免长会话 DOM 在拖动时被反复扫描。
        const layout = cachedLayout() || findFrame();
        if (!layout) return;

        if (layout.frame !== observedFrame || layout.sidebar !== observedSidebar) {
          resizeObserver.disconnect();
          resizeObserver.observe(layout.frame);
          resizeObserver.observe(layout.sidebar);
          observedFrame = layout.frame;
          observedSidebar = layout.sidebar;
        }

        const sidebarRect = layout.sidebar.getBoundingClientRect();
        const main = opaqueBackground(layout.frame, null);
        const sidebar = opaqueBackground(layout.sidebar, null);
        const divider = parseColor(getComputedStyle(layout.sidebar).borderRightColor);
        if (!main || !sidebar || !divider || !finite(sidebarRect.width)) return;

        const snapshot = {
          sidebarWidth: Math.max(0, Math.min(window.innerWidth, sidebarRect.width)),
          sidebar,
          main,
          divider,
        };
        const serialized = JSON.stringify(snapshot);
        if (serialized === lastSerialized) return;
        lastSerialized = serialized;
        messageHandler.postMessage(snapshot);
      };

      const schedule = () => {
        if (scheduled) return;
        scheduled = true;
        window.requestAnimationFrame(publish);
      };

      const root = document.getElementById("root");
      if (root) {
        new MutationObserver(invalidateLayout).observe(root, { childList: true });
      }
      new MutationObserver(schedule).observe(document.documentElement, {
        attributes: true,
        attributeFilter: ["class", "style", "data-theme"],
      });
      if (document.body) {
        new MutationObserver(schedule).observe(document.body, {
          attributes: true,
          attributeFilter: ["class", "style", "data-ds-dark-theme"],
        });
      }
      window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", schedule);

      let attempts = 0;
      const bootstrap = () => {
        schedule();
        if (observedFrame || attempts >= 120) return;
        attempts += 1;
        window.setTimeout(bootstrap, 250);
      };
      bootstrap();
    })();
    """#

    static func decode(_ body: Any) -> ChromeSurfaceStyle? {
        guard let dictionary = body as? [String: Any],
              let sidebarWidth = finiteNumber(dictionary["sidebarWidth"]),
              let sidebarColor = color(dictionary["sidebar"]),
              let mainColor = color(dictionary["main"]),
              let dividerColor = color(dictionary["divider"]),
              sidebarWidth >= 0,
              sidebarWidth <= 20_000 else {
            return nil
        }
        return ChromeSurfaceStyle(
            sidebarWidth: sidebarWidth,
            sidebarColor: sidebarColor,
            mainColor: mainColor,
            dividerColor: dividerColor
        )
    }

    private static func color(_ value: Any?) -> ChromeSurfaceStyle.RGBA? {
        guard let dictionary = value as? [String: Any],
              let red = finiteNumber(dictionary["red"]),
              let green = finiteNumber(dictionary["green"]),
              let blue = finiteNumber(dictionary["blue"]),
              let alpha = finiteNumber(dictionary["alpha"]),
              (0 ... 255).contains(red),
              (0 ... 255).contains(green),
              (0 ... 255).contains(blue),
              (0 ... 1).contains(alpha) else {
            return nil
        }
        return ChromeSurfaceStyle.RGBA(
            red: red / 255,
            green: green / 255,
            blue: blue / 255,
            alpha: alpha
        )
    }

    private static func finiteNumber(_ value: Any?) -> CGFloat? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        guard result.isFinite else { return nil }
        return CGFloat(result)
    }
}

struct WebContainerHost: NSViewRepresentable {
    let container: WebContainer

    func makeNSView(context: Context) -> WKWebView {
        container.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // WebView 的导航和状态由 WebContainer 管理，更新时不替换实例。
    }
}
