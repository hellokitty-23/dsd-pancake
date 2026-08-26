import Foundation

/// 一个真实终端标签的稳定身份。每个标签都会在 App 层拥有自己的 PTY（伪终端）和 shell，
/// 即使它们指向同一个 workspace（工作区）也绝不共享输入、输出或进程组。
public struct DesktopTerminalTab: Hashable, Identifiable, Sendable {
    public let id: UUID
    public let workspace: DesktopTerminalWorkspace
    public let ordinal: Int

    public init(id: UUID = UUID(), workspace: DesktopTerminalWorkspace, ordinal: Int) {
        self.id = id
        self.workspace = workspace
        self.ordinal = ordinal
    }
}

/// 与具体 terminal emulator（终端模拟器）无关的工作区终端状态。
///
/// 这个小状态机只记录标签身份、可见性和本次运行的面板高度；真实的 PTY 与 NSView 由
/// App target 持有。一个 workspace 可以有多个独立标签；不同 workspace 始终隔离。
public struct WorkspaceTerminalState: Equatable, Sendable {
    public enum Activation: Equatable, Sendable {
        case created
        case reused
    }

    public static let defaultPanelHeight: CGFloat = 280

    /// 当前 DSH session 已验证的工作区。这不是“最后创建终端”的工作区，也不会携带
    /// 回网页；它只决定原生 dock 此刻允许显示和创建哪个 workspace 的标签。
    public private(set) var activeWorkspace: DesktopTerminalWorkspace?
    public private(set) var isPanelVisible = false
    public private(set) var tabs: [DesktopTerminalTab] = []
    public private(set) var activeTabID: UUID?
    public private(set) var lastNonzeroPanelHeight: CGFloat = defaultPanelHeight

    private var nextOrdinalByWorkspace: [DesktopTerminalWorkspace: Int] = [:]
    private var lastSelectedTabIDByWorkspace: [DesktopTerminalWorkspace: UUID] = [:]

    public init() {}

    public var activeTab: DesktopTerminalTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    public var knownWorkspaces: Set<DesktopTerminalWorkspace> {
        Set(tabs.map(\.workspace))
    }

    public func tabs(for workspace: DesktopTerminalWorkspace?) -> [DesktopTerminalTab] {
        guard let workspace else { return [] }
        return tabs.filter { $0.workspace == workspace }
    }

    /// 仅同步当前 DSH session 的工作区，不创建 shell。若面板正在显示另一个工作区，
    /// 立即收起，绝不把旧终端误显示在新会话下。回到已有 workspace 时会恢复其最近
    /// 使用的标签选择，但仍需用户显式展开面板。
    public mutating func synchronize(workspace: DesktopTerminalWorkspace) {
        let didChangeWorkspace = activeWorkspace != workspace
        activeWorkspace = workspace
        guard didChangeWorkspace else {
            if activeTab == nil {
                activeTabID = preferredTabID(for: workspace)
            }
            return
        }

        activeTabID = preferredTabID(for: workspace)
        isPanelVisible = false
    }

    /// 当前 DSH 会话没有可用工作区时，撤销“当前”身份并收起面板，但不结束已经
    /// 创建的 shell。用户回到原工作区后仍可复用其标签。
    public mutating func clearActiveWorkspace() {
        activeWorkspace = nil
        activeTabID = nil
        isPanelVisible = false
    }

    /// 展开当前 workspace 的最近标签。尚无标签时才创建第一条 shell 身份；调用方
    /// 随后据此创建对应的真实 PTY。
    @discardableResult
    public mutating func show(workspace: DesktopTerminalWorkspace) -> Activation {
        activeWorkspace = workspace
        if let selected = activeTab, selected.workspace == workspace {
            isPanelVisible = true
            return .reused
        }
        if let tabID = preferredTabID(for: workspace) {
            activeTabID = tabID
            isPanelVisible = true
            return .reused
        }

        _ = createTab(workspace: workspace)
        return .created
    }

    /// `+` 创建一个与当前所有标签完全独立的新 shell 身份。ordinal（序号）只用于
    /// 人类可读的标签标题，关闭后不会回收，避免用户误认旧 shell 被复活。
    @discardableResult
    public mutating func createTab(workspace: DesktopTerminalWorkspace) -> DesktopTerminalTab {
        activeWorkspace = workspace
        let ordinal = nextOrdinalByWorkspace[workspace, default: 0] + 1
        nextOrdinalByWorkspace[workspace] = ordinal
        let tab = DesktopTerminalTab(workspace: workspace, ordinal: ordinal)
        tabs.append(tab)
        activeTabID = tab.id
        lastSelectedTabIDByWorkspace[workspace] = tab.id
        isPanelVisible = true
        return tab
    }

    /// 只能选择当前 DSH workspace 的标签，防止过期 UI 事件把其它工作区的 PTY 显示
    /// 在当前会话之下。
    @discardableResult
    public mutating func select(tabID: UUID) -> DesktopTerminalTab? {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              tab.workspace == activeWorkspace else {
            return nil
        }
        activeTabID = tab.id
        lastSelectedTabIDByWorkspace[tab.workspace] = tab.id
        isPanelVisible = true
        return tab
    }

    public mutating func hide() {
        isPanelVisible = false
    }

    /// 关闭标签只移除这一个 shell 身份。若关闭的是正在查看的标签，同一 workspace
    /// 仍有其它标签时自动选择最后一个；没有时才收起 dock。
    @discardableResult
    public mutating func closeActiveTab() -> DesktopTerminalTab? {
        guard let activeTabID else { return nil }
        return close(tabID: activeTabID)
    }

    @discardableResult
    public mutating func close(tabID: UUID) -> DesktopTerminalTab? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        let removed = tabs.remove(at: index)
        let replacementTabID = tabs.last(where: { $0.workspace == removed.workspace })?.id
        if lastSelectedTabIDByWorkspace[removed.workspace] == removed.id {
            lastSelectedTabIDByWorkspace[removed.workspace] = replacementTabID
        }
        guard activeTabID == removed.id else { return removed }

        if activeWorkspace == removed.workspace {
            activeTabID = replacementTabID
            lastSelectedTabIDByWorkspace[removed.workspace] = replacementTabID
            isPanelVisible = activeTabID != nil
        } else {
            activeTabID = nil
            isPanelVisible = false
        }
        return removed
    }

    /// 兼容需要按 workspace 成组回收的调用方。该操作会关闭该 workspace 的全部
    /// 标签；常规用户操作应使用 `close(tabID:)`，以避免误关同一工作区的其它 shell。
    public mutating func close(workspace: DesktopTerminalWorkspace) {
        let removedIDs = Set(tabs.filter { $0.workspace == workspace }.map(\.id))
        guard !removedIDs.isEmpty else { return }
        tabs.removeAll { removedIDs.contains($0.id) }
        lastSelectedTabIDByWorkspace[workspace] = nil
        if activeWorkspace == workspace {
            activeTabID = nil
            isPanelVisible = false
        }
    }

    public mutating func closeAll() -> Set<DesktopTerminalWorkspace> {
        let workspaces = knownWorkspaces
        tabs.removeAll()
        activeWorkspace = nil
        activeTabID = nil
        isPanelVisible = false
        nextOrdinalByWorkspace.removeAll()
        lastSelectedTabIDByWorkspace.removeAll()
        return workspaces
    }

    public mutating func rememberPanelHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        lastNonzeroPanelHeight = height
    }

    private func preferredTabID(for workspace: DesktopTerminalWorkspace) -> UUID? {
        if let tabID = lastSelectedTabIDByWorkspace[workspace],
           tabs.contains(where: { $0.id == tabID && $0.workspace == workspace }) {
            return tabID
        }
        return tabs.last(where: { $0.workspace == workspace })?.id
    }
}
