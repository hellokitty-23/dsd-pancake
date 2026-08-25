import AppKit
import DSHDesktopCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "DSD Pancake")
        let quitItem = NSMenuItem(
            title: "退出 DSD Pancake",
            action: #selector(requestQuit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
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
        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "io.github.dshdesktop"
        do {
            guard let lock = try SingleInstanceLock.acquire(bundleIdentifier: bundleIdentifier) else {
                activateExistingInstance(bundleIdentifier: bundleIdentifier)
                NSApp.terminate(nil)
                return
            }

            let coordinator = AppCoordinator(bundleIdentifier: bundleIdentifier, instanceLock: lock)
            self.coordinator = coordinator
            coordinator.installMainWindow()
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

    private func activateExistingInstance(bundleIdentifier: String) {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != currentPID })?
            .activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    @objc private func closeMainWindow(_ sender: Any?) {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(sender)
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
