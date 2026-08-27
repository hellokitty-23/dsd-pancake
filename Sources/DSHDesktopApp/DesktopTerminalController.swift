import AppKit
import Combine
import Darwin
import DSHDesktopCore
import Foundation
@preconcurrency import SwiftTerm

/// App 私有终端的唯一状态源。网页只通过严格 bridge 同步工作区；显示意图、真正的
/// terminal view、PTY、shell 生命周期和进程组清理都留在原生层。
@MainActor
final class DesktopTerminalController: NSObject, ObservableObject {
    private final class TerminalSession {
        let tab: DesktopTerminalTab
        let view: LocalProcessTerminalView
        let delegate: TerminalSessionDelegate
        let processGroupID: pid_t
        var isTerminating = false

        init(
            tab: DesktopTerminalTab,
            view: LocalProcessTerminalView,
            delegate: TerminalSessionDelegate,
            processGroupID: pid_t
        ) {
            self.tab = tab
            self.view = view
            self.delegate = delegate
            self.processGroupID = processGroupID
        }
    }

    private var state = WorkspaceTerminalState()
    private var sessions: [UUID: TerminalSession] = [:]
    private weak var dock: TerminalDockContainer?
    private var bridgeEnabled = false
    private var sidebarWidth: CGFloat?
    /// DSH 右侧对话主画布的只读颜色；`nil` 时回退到系统 terminal 背景色。
    private var mainSurfaceColor: NSColor?

    /// AppCoordinator 负责将这份极小状态同步到当前 WebKit 页面。它不包含 cwd、终端
    /// 输入或输出，避免把本机信息回传给 DSH 页面。
    var onStateChange: ((Bool, Bool) -> Void)?

    /// 只向当前 WebKit 页面同步原生 dock 的已钳制可见高度。页面端只能据此给对话
    /// 流留白，不能反向要求显示／收起 dock 或触及本机终端。
    var onConversationReservationChange: ((CGFloat) -> Void)?

    var isPanelVisible: Bool { state.isPanelVisible }
    var canToggleFromMenu: Bool { bridgeEnabled && state.activeWorkspace != nil }

    func attach(dock: TerminalDockContainer) {
        self.dock = dock
        dock.setSidebarWidth(sidebarWidth)
        dock.setMainSurfaceColor(mainSurfaceColor)
        dock.onPanelHeightChanged = { [weak self] height in
            self?.state.rememberPanelHeight(height)
        }
        dock.onConversationReservationChanged = { [weak self] height in
            self?.onConversationReservationChange?(height)
        }
        dock.onHideRequested = { [weak self] in
            self?.hide()
        }
        dock.onNewTerminalRequested = { [weak self] in
            self?.createTerminalTab()
        }
        dock.onSelectTerminalRequested = { [weak self] tabID in
            self?.selectTerminalTab(tabID)
        }
        dock.onCloseTerminalRequested = { [weak self] tabID in
            self?.closeTerminalTab(tabID)
        }
        synchronizeDock(animated: false)
    }

    /// DSH 网页仍拥有左侧工程栏；原生 dock 只拿到它的宽度来决定自己的水平
    /// 停靠区域，不读取会话文字、DOM 数据或任何工作区内容。
    func setSidebarWidth(_ width: CGFloat?) {
        let normalized = width?.isFinite == true ? max(0, width ?? 0) : nil
        guard sidebarWidth != normalized else { return }
        sidebarWidth = normalized
        dock?.setSidebarWidth(normalized)
    }

    /// 复用网页已经同步给原生标题栏的主表面色，让 native terminal 的标签栏和 shell
    /// 画布延续对话区域；网页只提供有限 RGBA 视觉值，不能影响终端行为或内容。
    func setMainSurfaceColor(_ color: NSColor?) {
        mainSurfaceColor = color
        dock?.setMainSurfaceColor(color)
        for session in sessions.values {
            session.view.nativeBackgroundColor = terminalBackgroundColor
        }
    }

    func detach(dock: TerminalDockContainer) {
        guard self.dock === dock else { return }
        self.dock = nil
    }

    /// 所有权一旦失去，立即撤销 bridge、收起面板并释放本 App 创建的全部 PTY。
    /// 外部 DSH 从不拥有这里的 terminal capability。
    func setBridgeEnabled(_ enabled: Bool) {
        guard bridgeEnabled != enabled else { return }
        bridgeEnabled = enabled
        guard !enabled else {
            publishState()
            return
        }

        let toClose = Array(sessions.values)
        sessions.removeAll()
        _ = state.closeAll()
        synchronizeDock(animated: false)
        publishState()
        Task { @MainActor [weak self, toClose] in
            guard let self else { return }
            await self.terminateAll(toClose)
        }
    }

    /// WebKit handler 在完成主 frame、origin 与严格 payload 校验后才会到达这里。
    func handle(_ action: DesktopTerminalBridgeAction) -> [String: Any] {
        guard bridgeEnabled else {
            return DesktopTerminalBridgeResponse.payload(
                supported: false,
                isOpen: false,
                workspaceAccepted: false
            )
        }

        switch action {
        case .capabilities:
            return response(workspaceAccepted: true)

        case let .syncWorkspace(request):
            guard let workspace = DesktopTerminalWorkspace(request: request) else {
                return response(workspaceAccepted: false)
            }
            state.synchronize(workspace: workspace)
            synchronizeDock(animated: false)
            publishState()
            return response(workspaceAccepted: true)

        case .clearWorkspace:
            state.clearActiveWorkspace()
            synchronizeDock(animated: true)
            publishState()
            return response(workspaceAccepted: true)
        }
    }

    /// 菜单的 ⌘J 和原生标题栏按钮汇入同一个状态机；网页 bridge 只能同步工作区，
    /// 不能要求原生层显示、隐藏或执行任何命令。
    func toggleFromMenu() {
        guard bridgeEnabled, let workspace = state.activeWorkspace else { return }
        if state.isPanelVisible {
            hide()
        } else {
            show(workspace)
        }
    }

    func hide() {
        guard state.isPanelVisible else { return }
        state.hide()
        synchronizeDock(animated: true)
        publishState()
    }

    /// 标签内的关闭只结束当前标签的 shell；同一 workspace 的其它标签和其它
    /// workspace 的 shell 均保持独立存在。
    func closeActiveTerminal() {
        guard let tabID = state.activeTabID else { return }
        closeTerminalTab(tabID)
    }

    /// 原生 `+` 只允许在 bridge 已确认、当前 DSH session 已验证 workspace 的前提下
    /// 创建 shell。网页无法伪造 tab ID 或传入任意 cwd。
    private func createTerminalTab() {
        guard bridgeEnabled, let workspace = state.activeWorkspace else { return }
        let tab = state.createTab(workspace: workspace)
        guard createSession(for: tab) != nil else {
            _ = state.close(tabID: tab.id)
            synchronizeDock(animated: true)
            publishState()
            return
        }
        synchronizeDock(animated: true)
        publishState()
    }

    private func selectTerminalTab(_ tabID: UUID) {
        guard sessions[tabID] != nil, state.select(tabID: tabID) != nil else { return }
        synchronizeDock(animated: false)
        publishState()
    }

    private func closeTerminalTab(_ tabID: UUID) {
        guard let tab = state.close(tabID: tabID) else { return }
        guard let session = sessions.removeValue(forKey: tab.id) else {
            synchronizeDock(animated: true)
            publishState()
            return
        }
        synchronizeDock(animated: true)
        publishState()
        Task { @MainActor [weak self, session] in
            await self?.terminate(session)
        }
    }

    /// App 退出前由 AppCoordinator await，保证 shell 与同一 PTY process group（进程组）
    /// 的子进程先收到终止信号，必要时再升级到 SIGKILL。
    func closeAllAndWait() async {
        let toClose = Array(sessions.values)
        sessions.removeAll()
        _ = state.closeAll()
        synchronizeDock(animated: false)
        publishState()
        await terminateAll(toClose)
    }

    private func show(_ workspace: DesktopTerminalWorkspace) {
        _ = state.show(workspace: workspace)
        guard let tab = state.activeTab else {
            synchronizeDock(animated: true)
            publishState()
            return
        }
        if sessions[tab.id] == nil, createSession(for: tab) == nil {
            _ = state.close(tabID: tab.id)
            synchronizeDock(animated: true)
            publishState()
            return
        }
        synchronizeDock(animated: true)
        publishState()
    }

    private func response(workspaceAccepted: Bool) -> [String: Any] {
        DesktopTerminalBridgeResponse.payload(
            supported: bridgeEnabled,
            isOpen: state.isPanelVisible,
            workspaceAccepted: workspaceAccepted
        )
    }

    private func createSession(for tab: DesktopTerminalTab) -> TerminalSession? {
        guard sessions[tab.id] == nil else { return sessions[tab.id] }

        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.configureNativeColors()
        terminal.nativeBackgroundColor = terminalBackgroundColor
        let delegate = TerminalSessionDelegate(tabID: tab.id, controller: self)
        terminal.processDelegate = delegate

        let shell = defaultShell()
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        terminal.startProcess(
            executable: shell,
            args: ["-l"],
            environment: terminalEnvironment(),
            execName: "-\(shellName)",
            currentDirectory: tab.workspace.path
        )

        let processGroupID = terminal.process.shellPid
        guard terminal.process.running, processGroupID > 1 else {
            terminal.terminate()
            return nil
        }

        let session = TerminalSession(
            tab: tab,
            view: terminal,
            delegate: delegate,
            processGroupID: processGroupID
        )
        sessions[tab.id] = session
        return session
    }

    private func defaultShell() -> String {
        let configured = ProcessInfo.processInfo.environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured,
           configured.hasPrefix("/"),
           FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        return FileManager.default.isExecutableFile(atPath: "/bin/zsh") ? "/bin/zsh" : "/bin/bash"
    }

    private var terminalBackgroundColor: NSColor {
        mainSurfaceColor ?? .textBackgroundColor
    }

    /// SwiftTerm 的默认环境不会继承 PATH；只显式保留 shell 正常运行所需的低风险
    /// 键，同时绝不记录任何环境变量。
    private func terminalEnvironment() -> [String] {
        var values: [String: String] = [:]
        for entry in Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true) {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                values[parts[0]] = parts[1]
            }
        }
        let inherited = ProcessInfo.processInfo.environment
        for key in ["PATH", "HOME", "TMPDIR", "SHELL", "LANG", "LC_CTYPE", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"] {
            if let value = inherited[key], !value.isEmpty {
                values[key] = value
            }
        }
        return values.keys.sorted().compactMap { key in
            values[key].map { "\(key)=\($0)" }
        }
    }

    private func synchronizeDock(animated: Bool) {
        let activeTab = state.activeTab
        let activeSession = activeTab.flatMap { sessions[$0.id] }
        let dockTabs = state.tabs(for: state.activeWorkspace).map { tab in
            TerminalDockTab(
                id: tab.id,
                title: tabTitle(tab),
                isActive: tab.id == activeTab?.id
            )
        }
        dock?.apply(
            isVisible: state.isPanelVisible,
            terminalView: activeSession?.view,
            tabs: dockTabs,
            panelHeight: state.lastNonzeroPanelHeight,
            animated: animated
        )
        if state.isPanelVisible, let terminal = activeSession?.view {
            DispatchQueue.main.async {
                terminal.window?.makeFirstResponder(terminal)
            }
        }
    }

    private func workspaceTitle(_ workspace: DesktopTerminalWorkspace) -> String {
        let title = URL(fileURLWithPath: workspace.path, isDirectory: true).lastPathComponent
        return title.isEmpty ? workspace.path : title
    }

    private func tabTitle(_ tab: DesktopTerminalTab) -> String {
        let title = workspaceTitle(tab.workspace)
        return tab.ordinal == 1 ? title : "\(title) \(tab.ordinal)"
    }

    private func publishState() {
        onStateChange?(bridgeEnabled, state.isPanelVisible)
    }

    private func terminateAll(_ sessions: [TerminalSession]) async {
        for session in sessions {
            await terminate(session)
        }
    }

    private func terminate(_ session: TerminalSession) async {
        guard !session.isTerminating else { return }
        session.isTerminating = true
        let shellPID = session.view.process.shellPid
        // `LocalProcessTerminalView.terminate()` 会关闭 PTY I/O 并取消它自己的退出
        // 监听，因此这里先精确通知整个已知 group，再由本控制器主动 waitpid 回收
        // 直接 shell。这样关闭标签和 App 退出均不会留下 zombie（僵尸进程）。
        _ = TerminalProcessGroup.send(SIGTERM, to: session.processGroupID)
        session.view.terminate()
        if await waitForProcessGroupToExit(
            session.processGroupID,
            shellPID: shellPID,
            timeoutNanoseconds: 1_000_000_000
        ) {
            return
        }
        // forkpty 的 shell 是 controlling-terminal session leader；向负 PID 发信号可同时
        // 覆盖前台 shell 和同一进程组内的子进程，不依赖网页、`ps` 输出或普通 pipe。
        _ = TerminalProcessGroup.send(SIGKILL, to: session.processGroupID)
        _ = await waitForProcessGroupToExit(
            session.processGroupID,
            shellPID: shellPID,
            timeoutNanoseconds: 1_000_000_000
        )
    }

    private func waitForProcessGroupToExit(
        _ processGroupID: pid_t,
        shellPID: pid_t,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        guard processGroupID > 1 else {
            _ = TerminalProcessGroup.reapIfExited(shellPID)
            return true
        }
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while TerminalProcessGroup.exists(processGroupID) {
            switch TerminalProcessGroup.reapIfExited(shellPID) {
            case .reaped, .noChild:
                // 已回收 shell 后再检查 group；后台子进程若仍在，循环会继续并由
                // SIGTERM/SIGKILL 清理，绝不把“shell 已退出”误当作全部结束。
                break
            case .running:
                break
            case .failed:
                // 仍继续等待已知 group 退出；不根据这个 PID 失败改去扫描或控制其它
                // 进程。deadline 到达后上层会完成自己的资源关闭。
                break
            }
            if !TerminalProcessGroup.exists(processGroupID) {
                return true
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = TerminalProcessGroup.reapIfExited(shellPID)
        return true
    }

    fileprivate func terminalProcessTerminated(
        source: TerminalView,
        tabID: UUID
    ) {
        guard let session = sessions[tabID], session.view === source else { return }
        sessions.removeValue(forKey: tabID)
        _ = state.close(tabID: tabID)
        synchronizeDock(animated: true)
        publishState()
    }
}

/// SwiftTerm 的 delegate 协议没有 actor 标注，不能直接让 `@MainActor` 控制器遵循。
/// 该代理不读取/写入终端状态，只把退出通知切回主线程，避免跨 actor 数据竞争。
private final class TerminalSessionDelegate: NSObject, LocalProcessTerminalViewDelegate {
    private let tabID: UUID
    private weak var controller: DesktopTerminalController?

    init(tabID: UUID, controller: DesktopTerminalController) {
        self.tabID = tabID
        self.controller = controller
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak controller, tabID] in
            controller?.terminalProcessTerminated(source: source, tabID: tabID)
        }
    }
}
