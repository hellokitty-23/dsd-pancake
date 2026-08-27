import DSHDesktopCore
import WebKit

final class ChromeStyleMessageHandler: NSObject, WKScriptMessageHandler {
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
@MainActor
final class NotificationMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var container: WebContainer?

    init(container: WebContainer) {
        self.container = container
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        guard message.name == DesktopNotificationBridge.messageName else {
            replyHandler(nil, "Unexpected script message name")
            return
        }

        Task { @MainActor [weak container] in
            guard let container else {
                replyHandler(nil, "Notification bridge is unavailable")
                return
            }
            replyHandler(await container.receiveNotificationMessage(message.body, frameInfo: message.frameInfo), nil)
        }
    }
}

@MainActor
final class TerminalMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var container: WebContainer?

    init(container: WebContainer) {
        self.container = container
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        guard message.name == DesktopTerminalBridge.messageName else {
            replyHandler(nil, "Unexpected script message name")
            return
        }
        guard let container else {
            replyHandler(nil, "Terminal bridge is unavailable")
            return
        }
        replyHandler(container.receiveTerminalMessage(message.body, frameInfo: message.frameInfo), nil)
    }
}
