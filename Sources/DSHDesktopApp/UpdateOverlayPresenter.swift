import AppKit
import Combine
import DSHDesktopCore
import SwiftUI

/// 只负责把更新 surface（表面）附着到主窗口，并管理锚定布局、焦点和关闭手势。
/// 它不读取更新版本，不创建下载 Task，也不访问网络或磁盘。
@MainActor
final class UpdateOverlayPresenter: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var surfaceWidth = UpdateOverlayLayout.preferredWidth
    @Published private(set) var arrowX = UpdateOverlayLayout.arrowInset
    @Published private(set) var usesCompactActions = false

    private weak var chrome: WindowChromeContainer?
    private weak var anchorView: NSView?
    private weak var surfaceHost: NSHostingView<UpdateOverlayView>?
    private let observerBag = UpdatePresentationObserverBag()
    private var layoutScheduled = false
    private var isDismissBlocked: (() -> Bool)?
    private var onWillDismiss: (() -> Void)?

    func present(
        relativeTo button: NSView,
        rootView: UpdateOverlayView,
        isDismissBlocked: @escaping () -> Bool,
        onWillDismiss: @escaping () -> Void
    ) {
        guard let chrome = chromeContainer(containing: button) else { return }
        self.isDismissBlocked = isDismissBlocked
        self.onWillDismiss = onWillDismiss
        attachIfNeeded(to: chrome, anchor: button, rootView: rootView)
        isPresented = true
        surfaceHost?.isHidden = false
        installPresentationObservers(for: chrome.window)
        scheduleLayout()
        focusFirstActionWhenReady()
    }

    func scheduleLayout() {
        guard isPresented, !layoutScheduled else { return }
        layoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutScheduled = false
            self.layoutSurface()
        }
    }

    func dismiss(restoreFocus: Bool = true) {
        guard isPresented, isDismissBlocked?() != true else { return }
        onWillDismiss?()
        isPresented = false
        surfaceHost?.isHidden = true
        removePresentationObservers()
        if restoreFocus, let anchorView, !anchorView.isHidden {
            anchorView.window?.makeFirstResponder(anchorView)
        }
        isDismissBlocked = nil
        onWillDismiss = nil
    }

    private func attachIfNeeded(
        to chrome: WindowChromeContainer,
        anchor: NSView,
        rootView: UpdateOverlayView
    ) {
        anchorView = anchor
        guard self.chrome !== chrome || surfaceHost == nil else { return }

        self.chrome?.onGeometryChange = nil
        surfaceHost?.removeFromSuperview()
        self.chrome = chrome

        let host = NSHostingView(rootView: rootView)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.isHidden = true
        chrome.installUpdateSurface(host)
        surfaceHost = host
        chrome.onGeometryChange = { [weak self] in
            self?.scheduleLayout()
        }
    }

    private func chromeContainer(containing view: NSView) -> WindowChromeContainer? {
        var candidate: NSView? = view
        while let current = candidate {
            if let chrome = current as? WindowChromeContainer {
                return chrome
            }
            candidate = current.superview
        }
        return nil
    }

    private func layoutSurface() {
        guard isPresented,
              let chrome,
              let anchorView,
              let surfaceHost else {
            return
        }
        chrome.layoutSubtreeIfNeeded()
        guard !anchorView.isHidden,
              anchorView.window === chrome.window else {
            dismiss()
            return
        }

        let geometry = chrome.updateLayout
        guard geometry.surfaceWidth > 0 else {
            dismiss()
            return
        }
        if surfaceWidth != geometry.surfaceWidth
            || arrowX != geometry.arrowX
            || usesCompactActions != geometry.usesCompactActions {
            surfaceWidth = geometry.surfaceWidth
            arrowX = geometry.arrowX
            usesCompactActions = geometry.usesCompactActions
            scheduleLayout()
            return
        }

        surfaceHost.frame.size.width = geometry.surfaceWidth
        surfaceHost.layoutSubtreeIfNeeded()
        let height = max(1, ceil(surfaceHost.fittingSize.height))
        let anchorFrame = anchorView.convert(anchorView.bounds, to: chrome)
        let maximumY = anchorFrame.minY - 8
        let originY = max(16, maximumY - height)
        surfaceHost.frame = NSRect(
            x: geometry.surfaceOriginX,
            y: originY,
            width: geometry.surfaceWidth,
            height: height
        ).integral
    }

    private func installPresentationObservers(for window: NSWindow?) {
        removePresentationObservers()
        observerBag.localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            let shouldConsume = MainActor.assumeIsolated {
                self?.shouldConsumeLocalEvent(event) ?? false
            }
            return shouldConsume ? nil : event
        }
        let center = NotificationCenter.default
        observerBag.notificationTokens.append(
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.dismiss() }
            }
        )
        observerBag.notificationTokens.append(
            center.addObserver(
                forName: NSWindow.willEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.dismiss() }
            }
        )
    }

    private func removePresentationObservers() {
        if let localEventMonitor = observerBag.localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            observerBag.localEventMonitor = nil
        }
        for token in observerBag.notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerBag.notificationTokens.removeAll()
    }

    private func shouldConsumeLocalEvent(_ event: NSEvent) -> Bool {
        guard isPresented else { return false }
        if event.type == .keyDown, event.keyCode == 53 {
            dismiss()
            // 浮层可见时 Esc 始终由原生壳消费，不能泄漏到网页双 Esc 插件。
            return true
        }
        guard event.type == .leftMouseDown || event.type == .rightMouseDown,
              isDismissBlocked?() != true else {
            return false
        }
        guard let chrome else {
            dismiss()
            return false
        }
        guard event.window === chrome.window else {
            dismiss()
            return false
        }
        let point = chrome.convert(event.locationInWindow, from: nil)
        let surfaceContainsPoint = surfaceHost?.frame.contains(point) == true
        let anchorContainsPoint = anchorView.map {
            $0.convert($0.bounds, to: chrome).contains(point)
        } == true
        if !surfaceContainsPoint, !anchorContainsPoint {
            // 只关闭浮层，保留这次点击给底层 DSH。
            dismiss(restoreFocus: false)
        }
        return false
    }

    private func focusFirstActionWhenReady() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPresented, let surfaceHost = self.surfaceHost else { return }
            self.layoutSurface()
            if let button = self.firstEnabledButton(in: surfaceHost) {
                button.window?.makeFirstResponder(button)
            }
        }
    }

    private func firstEnabledButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.isEnabled, !button.isHidden {
            return button
        }
        for subview in view.subviews {
            if let button = firstEnabledButton(in: subview) {
                return button
            }
        }
        return nil
    }
}

/// Objective-C monitor/token 没有声明 `Sendable`；资源袋仅由 MainActor presenter 使用，
/// deinit 负责最后兜底释放。
private final class UpdatePresentationObserverBag: @unchecked Sendable {
    var localEventMonitor: Any?
    var notificationTokens: [NSObjectProtocol] = []

    deinit {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
