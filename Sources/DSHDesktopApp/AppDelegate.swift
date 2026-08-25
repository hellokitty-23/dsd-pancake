import AppKit
import DSHDesktopCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private let preferences = UserPreferences()
    private var completionNotificationModeMenuItems: [DesktopNotificationDeliveryMode: NSMenuItem] = [:]

    func applicationWillFinishLaunching(_ notification: Notification) {
        installDockIcon()
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "DSD Pancake")
        let aboutItem = NSMenuItem(
            title: "关于 DSD Pancake",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        let completionNotificationsItem = NSMenuItem(
            title: "完成提醒",
            action: nil,
            keyEquivalent: ""
        )
        let completionNotificationsMenu = NSMenu(title: "完成提醒")
        let selectedNotificationMode = preferences.completionNotificationMode
        for mode in DesktopNotificationDeliveryMode.allCases {
            let modeItem = NSMenuItem(
                title: completionNotificationModeTitle(for: mode),
                action: #selector(selectCompletionNotificationMode(_:)),
                keyEquivalent: ""
            )
            modeItem.target = self
            modeItem.representedObject = mode.rawValue
            modeItem.state = mode == selectedNotificationMode ? .on : .off
            completionNotificationModeMenuItems[mode] = modeItem
            completionNotificationsMenu.addItem(modeItem)
        }
        completionNotificationsItem.submenu = completionNotificationsMenu
        let quitItem = NSMenuItem(
            title: "退出 DSD Pancake",
            action: #selector(requestQuit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = StandardEditMenu.makeMenu()
        mainMenu.addItem(editMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        let closeItem = NSMenuItem(
            title: "关闭窗口",
            action: #selector(closeMainWindow(_:)),
            keyEquivalent: "w"
        )
        closeItem.target = self
        fileMenu.addItem(closeItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let messageMenuItem = NSMenuItem()
        let messageMenu = NSMenu(title: "消息")
        messageMenu.addItem(completionNotificationsItem)
        messageMenuItem.submenu = messageMenu
        mainMenu.addItem(messageMenuItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "io.github.hellokitty-23.dsd-pancake"
        do {
            guard let lock = try SingleInstanceLock.acquire(bundleIdentifier: bundleIdentifier) else {
                activateExistingInstance(bundleIdentifier: bundleIdentifier)
                NSApp.terminate(nil)
                return
            }

            let coordinator = AppCoordinator(
                bundleIdentifier: bundleIdentifier,
                instanceLock: lock,
                preferences: preferences
            )
            self.coordinator = coordinator
            coordinator.installMainWindow()
            coordinator.prepareNotificationAuthorization()
            coordinator.beginStartup()
        } catch {
            presentFatalError(error.localizedDescription)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.restoreMainWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        coordinator?.applicationShouldTerminate() ?? .terminateNow
    }

    /// 首次 `⌘Q` 仍交给 AppKit 发起正常退出；当 AppKit 已处于 `.terminateLater`
    /// 的异步退出事务中，第二次 `⌘Q` 则必须直接交给协调器确认，不能再依赖
    /// `applicationShouldTerminate` 被重复调用。
    @objc private func requestQuit(_ sender: Any?) {
        if coordinator?.consumePendingQuitCommand() == true {
            return
        }
        NSApp.terminate(sender)
    }

    /// 这是 App 自己的投递偏好，不是 macOS 系统授权。切换后立即更新新事件的
    /// 投递规则；不重启 DSH，也不清除系统里已经允许的通知权限。
    @objc private func selectCompletionNotificationMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = DesktopNotificationDeliveryMode(rawValue: rawValue) else {
            return
        }
        preferences.completionNotificationMode = mode
        for (candidate, item) in completionNotificationModeMenuItems {
            item.state = candidate == mode ? .on : .off
        }
    }

    private func completionNotificationModeTitle(for mode: DesktopNotificationDeliveryMode) -> String {
        switch mode {
        case .never:
            "永不"
        case .whenUnfocused:
            "仅在未聚焦时"
        case .always:
            "一律"
        }
    }

    private func activateExistingInstance(bundleIdentifier: String) {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != currentPID })?
            .activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    @objc private func closeMainWindow(_ sender: Any?) {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(sender)
    }

    /// `PancakeAppIcon` 保持为 bundle 身份图标，供 Finder 与原生通知读取；Dock 单独用
    /// `DockIcon`，这样小尺寸提醒图标的留白不会影响正在运行 App 的可见大小。
    private func installDockIcon() {
        guard let iconURL = Bundle.main.url(forResource: "DockIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else {
            return
        }
        NSApp.applicationIconImage = icon
    }

    private func presentFatalError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "无法启动 DSD Pancake"
        alert.informativeText = message
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
