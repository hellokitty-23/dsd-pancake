import AppKit
import DSHDesktopCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private let preferences = UserPreferences()
    private let dshUpdateService = DSHUpdateService()
    private var completionNotificationModeMenuItems: [DesktopNotificationDeliveryMode: NSMenuItem] = [:]
    private var checkDSHUpdatesMenuItem: NSMenuItem?
    private var dshUpdateTask: Task<Void, Never>?

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
        let checkDSHUpdatesItem = NSMenuItem(
            title: "检查 DeepSeek Harness 更新…",
            action: #selector(checkForDSHUpdates(_:)),
            keyEquivalent: ""
        )
        checkDSHUpdatesItem.target = self
        checkDSHUpdatesMenuItem = checkDSHUpdatesItem
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
        appMenu.addItem(checkDSHUpdatesItem)
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
        if dshUpdateTask != nil {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "DeepSeek Harness 更新流程尚未结束"
            alert.informativeText = "请等待检查或更新完成后再退出 DSD Pancake，避免中断 npm。"
            alert.addButton(withTitle: "知道了")
            if let window = coordinator?.alertHostWindow, window.attachedSheet == nil {
                alert.beginSheetModal(for: window)
            }
            return .terminateCancel
        }
        return coordinator?.applicationShouldTerminate() ?? .terminateNow
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

    @objc private func checkForDSHUpdates(_ sender: NSMenuItem) {
        guard dshUpdateTask == nil else { return }
        sender.isEnabled = false
        sender.title = "正在检查 DeepSeek Harness 更新…"
        dshUpdateTask = Task { @MainActor [weak self] in
            await self?.runDSHUpdateFlow()
        }
    }

    private func runDSHUpdateFlow() async {
        defer {
            checkDSHUpdatesMenuItem?.title = "检查 DeepSeek Harness 更新…"
            checkDSHUpdatesMenuItem?.isEnabled = true
            dshUpdateTask = nil
        }

        guard let coordinator else {
            await presentUpdateAlert(
                title: "DSD Pancake 尚未准备好",
                message: "主窗口完成启动后再检查 DeepSeek Harness 更新。",
                style: .warning
            )
            return
        }
        guard let executable = DSHLocator().locate(lastChosenPath: preferences.selectedDSHPath) else {
            await presentUpdateAlert(
                title: "未找到可执行的 dsh",
                message: "请先安装 DSH，或在主窗口中选择当前已安装的 dsh 可执行文件。",
                style: .warning
            )
            return
        }

        do {
            let check = try await dshUpdateService.check(executable: executable)
            switch check.disposition {
            case .upToDate:
                await presentUpdateAlert(
                    title: "DeepSeek Harness 已是最新版本",
                    message: "当前版本和 npm latest（最新发行标签）均为 \(check.currentVersion)。"
                )
            case .newerThanLatest:
                await presentUpdateAlert(
                    title: "当前版本比 npm latest 更新",
                    message: "当前版本：\(check.currentVersion)\n"
                        + "npm latest：\(check.latestVersion)\n\n"
                        + "不会自动降级或覆盖当前安装。"
                )
            case .updateAvailable:
                let response = await presentUpdateAlert(
                    title: "发现 DeepSeek Harness 更新",
                    message: "当前版本：\(check.currentVersion)\n"
                        + "最新版本：\(check.latestVersion)\n\n"
                        + "更新会正常停止由 DSD Pancake 创建的 DSH，然后执行：\n"
                        + "可执行文件：\(check.npmExecutable.path)\n"
                        + "参数：\(DSHUpdateService.updateArguments.joined(separator: " "))\n\n"
                        + "DSH 仍处于开发者预览阶段，更新后 App 会重新启动并检查兼容性。",
                    style: .warning,
                    primaryButton: "更新",
                    secondaryButton: "取消"
                )
                guard response == .alertFirstButtonReturn else { return }

                switch await coordinator.prepareForDSHUpdate() {
                case .ready:
                    break
                case .externalServiceActive:
                    await presentUpdateAlert(
                        title: "检测到外部 DSH 服务",
                        message: "127.0.0.1:3080 上的服务不能确认由本次 App 创建。为避免修改正在运行的外部 DSH，请先自行停止该服务，再重新检查更新。",
                        style: .warning
                    )
                    return
                case let .busy(message):
                    await presentUpdateAlert(title: "现在不能更新", message: message, style: .warning)
                    return
                case .stopTimedOut:
                    await presentUpdateAlert(
                        title: "等待 DSH 停止超时",
                        message: "不会强制结束进程，也没有执行 npm 更新。请等待日志清理完成后重试。",
                        style: .warning
                    )
                    return
                }

                checkDSHUpdatesMenuItem?.title = "正在更新 DeepSeek Harness…"
                do {
                    let result = try await dshUpdateService.update(using: check)
                    coordinator.finishDSHUpdateAndRestart()
                    await presentUpdateAlert(
                        title: "DeepSeek Harness 更新完成",
                        message: "\(result.previousVersion) → \(result.installedVersion)\n\n"
                            + "DSD Pancake 正在重新启动本次 DSH 服务。"
                    )
                } catch {
                    coordinator.finishDSHUpdateAndRestart()
                    throw error
                }
            }
        } catch is CancellationError {
            coordinator.finishDSHUpdateAndRestart()
        } catch {
            await presentUpdateAlert(
                title: "无法更新 DeepSeek Harness",
                message: error.localizedDescription,
                style: .critical
            )
        }
    }

    @discardableResult
    private func presentUpdateAlert(
        title: String,
        message: String,
        style: NSAlert.Style = .informational,
        primaryButton: String = "好",
        secondaryButton: String? = nil
    ) async -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: primaryButton)
        if let secondaryButton {
            alert.addButton(withTitle: secondaryButton)
        }
        guard let window = coordinator?.alertHostWindow ?? NSApp.mainWindow,
              window.attachedSheet == nil else {
            return .abort
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
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
