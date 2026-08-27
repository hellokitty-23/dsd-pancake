import Foundation

/// 原生底部 dock（停靠面板）的纯布局规则。它不持有 WebKit 或 terminal view，因而
/// 可以在无 GUI 的验证程序中覆盖窗口缩放、最小/最大高度和主内容区域的边界。
public struct TerminalDockLayout: Equatable, Sendable {
    public static let defaultPanelHeight: CGFloat = WorkspaceTerminalState.defaultPanelHeight
    public static let minimumPanelHeight: CGFloat = 160
    /// 终端面板最多占可用原生内容高度的一半。分隔线单独计算，不把它伪装成
    /// terminal 内容高度的一部分。可见线固定为 1pt；更宽的拖拽命中区仅在 AppKit
    /// 容器内实现，避免为了可操作性把视觉边界做粗。
    public static let maximumFraction: CGFloat = 0.50
    public static let dividerHeight: CGFloat = 1
    /// 网页尚未报告侧栏宽度时的保守起点。宁可暂时在主内容区留下空隙，也不覆盖
    /// 左侧工程栏；首个 Chrome surface（表面）快照到达后会立刻使用精确宽度。
    public static let fallbackSidebarWidth: CGFloat = 384
    public static let minimumContentWidth: CGFloat = 240

    public let webHeight: CGFloat
    public let panelHeight: CGFloat
    public let dividerHeight: CGFloat

    public var isExpanded: Bool { panelHeight > 0 }

    /// 右侧 DSH 对话流需要为原生 dock 留出的高度。WKWebView 仍保持全高，以让
    /// 左侧工程栏完整可用；App 私有 client plugin（客户端插件）只把这段高度放在
    /// composer footer（输入框底部扩展位）之后，因而消息和输入框会一起上移，而非
    /// 被原生终端盖住。
    public var conversationReservedHeight: CGFloat {
        guard isExpanded else { return 0 }
        return panelHeight + dividerHeight
    }

    public static func collapsed(totalHeight: CGFloat) -> TerminalDockLayout {
        TerminalDockLayout(
            webHeight: max(0, totalHeight),
            panelHeight: 0,
            dividerHeight: 0
        )
    }

    public static func expanded(totalHeight: CGFloat, requestedPanelHeight: CGFloat) -> TerminalDockLayout {
        let available = max(0, totalHeight - dividerHeight)
        let maximum = available * maximumFraction
        let minimum = min(minimumPanelHeight, maximum)
        let panelHeight = min(max(requestedPanelHeight, minimum), maximum)
        return TerminalDockLayout(
            // DSH 的侧栏和主内容都在同一个 WKWebView 中。为了让侧栏在终端打开时
            // 继续完整可见、可操作，WebView 保持全高；原生终端仅停靠在右侧内容区，
            // 右侧对话流则通过 conversationReservedHeight 预留对应空间。
            webHeight: max(0, totalHeight),
            panelHeight: panelHeight,
            dividerHeight: dividerHeight
        )
    }

    /// 面板高度在窗口缩放后仍受当前可用高度约束。窗口极小时允许低于常规 160px，
    /// 以保证 WebView 永远仍有非负可用高度。
    public static func clampedPanelHeight(_ requestedPanelHeight: CGFloat, totalHeight: CGFloat) -> CGFloat {
        expanded(totalHeight: totalHeight, requestedPanelHeight: requestedPanelHeight).panelHeight
    }

    /// 终端的水平区域从 DSH 侧栏右边开始。窗口极窄时优先保留最小主内容宽度，
    /// 而不会构造负宽度或让原生 view 越界。
    public static func contentRegion(totalWidth: CGFloat, sidebarWidth: CGFloat?) -> TerminalDockContentRegion {
        let width = max(0, totalWidth)
        let reportedSidebarWidth = sidebarWidth?.isFinite == true
            ? max(0, sidebarWidth ?? 0)
            : fallbackSidebarWidth
        let maximumLeading = max(0, width - minimumContentWidth)
        let leading = min(reportedSidebarWidth, maximumLeading)
        return TerminalDockContentRegion(
            leading: leading,
            width: max(0, width - leading)
        )
    }
}

/// 终端在原生容器中的右侧主内容区域。`leading` 始终是从左边界开始的非负距离。
public struct TerminalDockContentRegion: Equatable, Sendable {
    public let leading: CGFloat
    public let width: CGFloat
}
