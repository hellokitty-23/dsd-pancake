import AppKit
import DSHDesktopCore

/// 壳层标题栏控件的唯一职责是展示 App 状态并把点击交回协调器。它不持有更新、
/// 终端或进程所有权，因此不能绕过现有的安全状态机。
@MainActor
final class AppTitlebarControls: NSObject {
    private weak var updateButton: NSButton?
    private weak var terminalButton: NSButton?
    private var availableUpdateCount = 0
    private var canToggleTerminal = false
    private var terminalIsVisible = false
    private let onUpdatePressed: (NSView) -> Void
    private let onTerminalToggle: () -> Void

    init(
        onUpdatePressed: @escaping (NSView) -> Void,
        onTerminalToggle: @escaping () -> Void
    ) {
        self.onUpdatePressed = onUpdatePressed
        self.onTerminalToggle = onTerminalToggle
        super.init()
    }

    func install(in window: NSWindow) {
        installUpdateControl(in: window)
        installTerminalControl(in: window)
        renderUpdateControl()
        renderTerminalControl()
    }

    func setUpdateAvailability(_ availability: UpdateAvailability) {
        availableUpdateCount = availability.count
        renderUpdateControl()
    }

    func presentAvailableUpdatesFromMenu() {
        guard UpdateIndicatorPresentation.isVisible(forAvailableUpdateCount: availableUpdateCount),
              let button = updateButton else {
            return
        }
        onUpdatePressed(button)
    }

    func updateTerminalState(canToggle: Bool, isVisible: Bool) {
        canToggleTerminal = canToggle
        terminalIsVisible = isVisible
        renderTerminalControl()
    }

    /// 更新状态属于壳层而非网页。左侧 accessory 的透明占位宽度将按钮放在侧栏右缘
    /// 附近，同时保留红绿灯的系统安全区域；它不会占用 DSH 顶部 header 的布局。
    private func installUpdateControl(in window: NSWindow) {
        let button = NSButton(frame: NSRect(x: 224, y: 2, width: 28, height: 24))
        button.bezelStyle = .toolbar
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = NSImage(
            systemSymbolName: "arrow.down.circle",
            accessibilityDescription: "打开可选更新"
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        button.target = self
        button.action = #selector(showAvailableUpdates(_:))

        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        holder.addSubview(button)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .left
        accessory.view = holder
        window.addTitlebarAccessoryViewController(accessory)
        updateButton = button
    }

    /// 终端按钮属于 AppKit 壳层，而不是 DSH 页面。它沿用原生标题栏右侧 accessory
    /// 布局，因此不会随 DSH header 重绘、主题或插件插槽变化而移动。
    private func installTerminalControl(in window: NSWindow) {
        let label = "显示/隐藏底部终端 ⌘J"
        let button = NSButton(frame: NSRect(x: 4, y: 2, width: 28, height: 24))
        button.setButtonType(.toggle)
        button.bezelStyle = .toolbar
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: label
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        button.target = self
        button.action = #selector(toggleTerminalPanel(_:))
        button.toolTip = label
        button.setAccessibilityLabel(label)

        // `.right` accessory 的容器仍贴着标题栏右缘；保留约 20pt 的右侧留白，使
        // 图标落在窗口圆角内侧而非贴边，同时不影响原生点击区域或快捷键。
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 52, height: 28))
        holder.addSubview(button)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        accessory.view = holder
        window.addTitlebarAccessoryViewController(accessory)
        terminalButton = button
    }

    private func renderUpdateControl() {
        guard let button = updateButton else { return }
        let count = availableUpdateCount
        let isVisible = UpdateIndicatorPresentation.isVisible(forAvailableUpdateCount: count)
        button.isHidden = !isVisible
        button.isEnabled = isVisible
        button.contentTintColor = count > 0 ? .controlAccentColor : .secondaryLabelColor
        let label = UpdateIndicatorPresentation.label(forAvailableUpdateCount: count) ?? "无可用更新"
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityValue(count > 0 ? "可用" : "已检查")
    }

    private func renderTerminalControl() {
        guard let button = terminalButton else { return }
        button.isEnabled = canToggleTerminal
        button.state = terminalIsVisible ? .on : .off
        button.contentTintColor = terminalIsVisible ? .controlAccentColor : .secondaryLabelColor
        button.toolTip = canToggleTerminal
            ? "显示/隐藏底部终端 ⌘J"
            : "当前会话没有有效工作区，暂时无法打开底部终端"
        button.setAccessibilityValue(terminalIsVisible ? "已显示" : "已隐藏")
    }

    @objc private func showAvailableUpdates(_ sender: NSButton) {
        guard UpdateIndicatorPresentation.isVisible(forAvailableUpdateCount: availableUpdateCount) else {
            return
        }
        onUpdatePressed(sender)
    }

    @objc private func toggleTerminalPanel(_ sender: NSButton) {
        onTerminalToggle()
    }
}
