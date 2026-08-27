import AppKit
import DSHDesktopCore
import SwiftUI
import WebKit

/// 只供原生 dock 渲染的标签摘要；不会传入 WKWebView 或网页 bridge。
struct TerminalDockTab: Equatable, Identifiable {
    let id: UUID
    let title: String
    let isActive: Bool
}

/// 原生的底部 dock。DSH 的侧栏和主内容同属一个 WKWebView，因而不能只缩短右半
/// 网页而同时保持左栏完整可交互。这里保持 WKWebView 全高，并把原生终端严格裁切
/// 在右侧主内容区域；它不会占用、遮住或替换左侧工程栏。
@MainActor
final class TerminalDockContainer: NSView {
    var onPanelHeightChanged: ((CGFloat) -> Void)?
    /// 仅同步可见 dock 的几何高度给 WebKit 内的 App 私有布局插件。它不含工作区、
    /// 命令或终端内容；左侧工程栏仍由全高 WebView 自己绘制。
    var onConversationReservationChanged: ((CGFloat) -> Void)?
    var onHideRequested: (() -> Void)?
    var onNewTerminalRequested: (() -> Void)?
    var onSelectTerminalRequested: ((UUID) -> Void)?
    var onCloseTerminalRequested: ((UUID) -> Void)?

    private let webView: WKWebView
    /// 不能把 WKWebView 本身设为 hidden：WebKit 可能因此延迟首帧，导致启动等待
    /// 与网页绘制互相阻塞。这个不透明覆盖层只遮挡视觉输出，网页继续正常加载。
    private let loadingCover = NSView()
    private let terminalPanel = TerminalPanelView()
    private let divider = TerminalDockDividerView()
    private var isPanelVisible = false
    private var requestedPanelHeight = TerminalDockLayout.defaultPanelHeight
    private var isAnimatingLayout = false
    private var dragStartPanelHeight: CGFloat = 0
    private var sidebarWidth: CGFloat?
    private var lastPublishedConversationReservation: CGFloat?

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        wantsLayer = true

        webView.removeFromSuperview()
        addSubview(webView)
        loadingCover.wantsLayer = true
        loadingCover.layer?.backgroundColor = AppLaunchSurface.color.cgColor
        addSubview(loadingCover)
        addSubview(terminalPanel)
        addSubview(divider)
        terminalPanel.isHidden = true
        divider.isHidden = true
        divider.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(handleDividerPan(_:))))
        terminalPanel.onHideRequested = { [weak self] in
            self?.onHideRequested?()
        }
        terminalPanel.onNewTerminalRequested = { [weak self] in
            self?.onNewTerminalRequested?()
        }
        terminalPanel.onSelectTerminalRequested = { [weak self] tabID in
            self?.onSelectTerminalRequested?(tabID)
        }
        terminalPanel.onCloseTerminalRequested = { [weak self] tabID in
            self?.onCloseTerminalRequested?(tabID)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        loadingCover.frame = bounds
        guard !isAnimatingLayout else { return }
        applyFrames(TerminalDockLayoutForCurrentBounds(), animated: false)
    }

    /// 可见分隔线只有 1pt，但仍保留相邻的透明拖拽热区。这样终端像从对话下方自然
    /// 延展出来，同时不牺牲鼠标调整高度的可用性。
    override func hitTest(_ point: NSPoint) -> NSView? {
        if isPanelVisible,
           !divider.isHidden,
           dividerDragHitFrame.contains(point) {
            return divider
        }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isPanelVisible, !divider.isHidden else { return }
        addCursorRect(dividerDragHitFrame, cursor: .resizeUpDown)
    }

    func apply(
        isVisible: Bool,
        terminalView: NSView?,
        tabs: [TerminalDockTab],
        panelHeight: CGFloat,
        animated: Bool
    ) {
        requestedPanelHeight = panelHeight
        terminalPanel.setTerminalView(terminalView, tabs: tabs)
        let wasVisible = isPanelVisible
        isPanelVisible = isVisible
        let layout = TerminalDockLayoutForCurrentBounds()

        if isVisible {
            terminalPanel.isHidden = false
            divider.isHidden = false
            if !wasVisible {
                terminalPanel.alphaValue = 0
                divider.alphaValue = 0
            }
            applyFrames(layout, animated: animated)
            animateAlpha(showing: true, animated: animated)
        } else {
            guard wasVisible else {
                applyFrames(layout, animated: false)
                return
            }
            applyFrames(layout, animated: animated)
            animateAlpha(showing: false, animated: animated)
        }
    }

    /// `nil` 表示网页尚未报告布局，此时使用布局规则中的保守回退宽度，避免首帧
    /// 将面板铺到左侧工程栏上。
    func setSidebarWidth(_ width: CGFloat?) {
        let normalized = width?.isFinite == true ? max(0, width ?? 0) : nil
        guard sidebarWidth != normalized else { return }
        sidebarWidth = normalized
        guard !isAnimatingLayout else { return }
        applyFrames(TerminalDockLayoutForCurrentBounds(), animated: false)
    }

    /// 终端属于 DSH 右侧主内容区，因此它的画布与标签栏都复用同一主表面色，而不是
    /// 采用系统 text background（文本背景）形成偏灰的第二层。
    func setMainSurfaceColor(_ color: NSColor?) {
        terminalPanel.setMainSurfaceColor(color)
    }

    /// SwiftUI 遮罩的首次挂载与 `NSViewRepresentable`（原生视图包装器）不同步时，
    /// 此原生覆盖层仍可挡住 WebKit 的默认白色首帧。它不隐藏 WebView，避免阻塞网页
    /// 的导航与渲染。
    func setLoadingCoverVisible(_ visible: Bool) {
        loadingCover.frame = bounds
        loadingCover.isHidden = !visible
    }

    private func TerminalDockLayoutForCurrentBounds() -> TerminalDockLayout {
        if isPanelVisible {
            let clamped = TerminalDockLayout.clampedPanelHeight(
                requestedPanelHeight,
                totalHeight: bounds.height
            )
            if clamped > 0 {
                requestedPanelHeight = clamped
            }
            return TerminalDockLayout.expanded(
                totalHeight: bounds.height,
                requestedPanelHeight: requestedPanelHeight
            )
        }
        return TerminalDockLayout.collapsed(totalHeight: bounds.height)
    }

    private func applyFrames(_ layout: TerminalDockLayout, animated: Bool) {
        publishConversationReservation(layout.conversationReservedHeight)
        let webFrame = bounds
        let contentRegion = TerminalDockLayout.contentRegion(
            totalWidth: bounds.width,
            sidebarWidth: sidebarWidth
        )
        let contentX = bounds.minX + contentRegion.leading
        let dividerFrame = NSRect(
            x: contentX,
            y: bounds.minY + layout.panelHeight,
            width: contentRegion.width,
            height: layout.dividerHeight
        )
        let panelFrame = NSRect(
            x: contentX,
            y: bounds.minY,
            width: contentRegion.width,
            height: layout.panelHeight
        )

        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reducesMotion, window != nil else {
            webView.frame = webFrame
            divider.frame = dividerFrame
            terminalPanel.frame = panelFrame
            window?.invalidateCursorRects(for: self)
            return
        }

        isAnimatingLayout = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            // 左栏仍由同一个 WKWebView 负责绘制和接收事件，因此不动画或裁剪
            // WebView；只让右侧原生 dock 在自己的区域内进出。
            webView.frame = webFrame
            divider.animator().frame = dividerFrame
            terminalPanel.animator().frame = panelFrame
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isAnimatingLayout = false
                self.needsLayout = true
                self.window?.invalidateCursorRects(for: self)
            }
        }
    }

    private var dividerDragHitFrame: NSRect {
        divider.frame
            .insetBy(dx: 0, dy: -TerminalDockDividerView.dragHitInset)
            .intersection(bounds)
    }

    private func publishConversationReservation(_ height: CGFloat) {
        let normalized = height.isFinite ? max(0, height) : 0
        guard lastPublishedConversationReservation != normalized else { return }
        lastPublishedConversationReservation = normalized
        onConversationReservationChanged?(normalized)
    }

    private func animateAlpha(showing: Bool, animated: Bool) {
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reducesMotion, window != nil else {
            terminalPanel.alphaValue = showing ? 1 : 0
            divider.alphaValue = showing ? 1 : 0
            if !showing {
                terminalPanel.isHidden = true
                divider.isHidden = true
            }
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            terminalPanel.animator().alphaValue = showing ? 1 : 0
            divider.animator().alphaValue = showing ? 1 : 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !showing, !self.isPanelVisible else { return }
                self.terminalPanel.isHidden = true
                self.divider.isHidden = true
            }
        }
    }

    @objc private func handleDividerPan(_ recognizer: NSPanGestureRecognizer) {
        guard isPanelVisible else { return }
        switch recognizer.state {
        case .began:
            layer?.removeAllAnimations()
            webView.layer?.removeAllAnimations()
            divider.layer?.removeAllAnimations()
            terminalPanel.layer?.removeAllAnimations()
            isAnimatingLayout = false
            dragStartPanelHeight = TerminalDockLayoutForCurrentBounds().panelHeight

        case .changed:
            let translation = recognizer.translation(in: self)
            let proposed = dragStartPanelHeight + translation.y
            let clamped = TerminalDockLayout.clampedPanelHeight(proposed, totalHeight: bounds.height)
            requestedPanelHeight = clamped
            onPanelHeightChanged?(clamped)
            applyFrames(TerminalDockLayoutForCurrentBounds(), animated: false)

        case .ended, .cancelled, .failed:
            let height = TerminalDockLayoutForCurrentBounds().panelHeight
            requestedPanelHeight = height
            onPanelHeightChanged?(height)

        default:
            break
        }
    }
}

private final class TerminalDockDividerView: NSView {
    static let dragHitInset: CGFloat = 4

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}

private final class TerminalPanelView: NSView {
    var onHideRequested: (() -> Void)?
    var onNewTerminalRequested: (() -> Void)?
    var onSelectTerminalRequested: ((UUID) -> Void)?
    var onCloseTerminalRequested: ((UUID) -> Void)?

    private let headerHeight: CGFloat = 38
    private let header = NSView()
    private let tabScrollView = NSScrollView()
    private let tabStrip = NSView()
    private let newTabButton = NSButton()
    private let hideButton = NSButton()
    private let terminalContent = NSView()
    private let emptyLabel = NSTextField(labelWithString: "正在准备终端…")
    private weak var currentTerminalView: NSView?
    private var mainSurfaceColor: NSColor?
    private var tabViews: [UUID: TerminalTabView] = [:]
    private var tabOrder: [UUID] = []
    private var pendingActiveTabID: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        header.wantsLayer = true
        terminalContent.wantsLayer = true
        applyMainSurfaceColor()

        // 标签栏与 terminal 内容继承同一层背景，不用单独材质把它们切成两个面板。
        addSubview(header)

        configureTabScrollView()
        header.addSubview(tabScrollView)

        let newTabLabel = "新建终端标签（当前工作区）"
        newTabButton.bezelStyle = .toolbar
        newTabButton.imagePosition = .imageOnly
        newTabButton.imageScaling = .scaleProportionallyDown
        newTabButton.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: newTabLabel
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        newTabButton.target = self
        newTabButton.action = #selector(createTerminal(_:))
        newTabButton.toolTip = newTabLabel
        newTabButton.setAccessibilityLabel(newTabLabel)
        tabStrip.addSubview(newTabButton)

        addSubview(terminalContent)

        let hideLabel = "收起底部终端"
        hideButton.bezelStyle = .toolbar
        hideButton.imagePosition = .imageOnly
        hideButton.imageScaling = .scaleProportionallyDown
        hideButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: hideLabel
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        hideButton.target = self
        hideButton.action = #selector(hidePanel(_:))
        hideButton.toolTip = hideLabel
        hideButton.setAccessibilityLabel(hideLabel)
        header.addSubview(hideButton)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        terminalContent.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: terminalContent.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: terminalContent.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyMainSurfaceColor()
    }

    override func layout() {
        super.layout()
        let resolvedHeaderHeight = min(headerHeight, bounds.height)
        header.frame = NSRect(
            x: bounds.minX,
            y: max(bounds.minY, bounds.maxY - resolvedHeaderHeight),
            width: bounds.width,
            height: resolvedHeaderHeight
        )

        let hideButtonSize: CGFloat = 28
        hideButton.frame = NSRect(
            x: max(0, header.bounds.width - hideButtonSize - 8),
            y: max(0, (header.bounds.height - hideButtonSize) / 2),
            width: hideButtonSize,
            height: hideButtonSize
        )
        let tabHeight: CGFloat = 28
        let tabViewport = NSRect(
            x: 8,
            y: max(0, (header.bounds.height - tabHeight) / 2),
            width: max(0, hideButton.frame.minX - 16),
            height: tabHeight
        )
        tabScrollView.frame = tabViewport
        layoutTabStrip(availableWidth: tabViewport.width, tabHeight: tabHeight)

        // 标签栏仅负责归属与切换；内容从其下方直接延续，避免形成一个独立的 header
        // 卡片或多余留白。
        terminalContent.frame = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: max(0, bounds.height - resolvedHeaderHeight)
        )
        currentTerminalView?.frame = terminalContent.bounds

        scrollPendingActiveTabIntoView()
    }

    func setTerminalView(_ view: NSView?, tabs: [TerminalDockTab]) {
        updateTabs(tabs)
        guard currentTerminalView !== view else {
            emptyLabel.isHidden = view != nil
            return
        }
        currentTerminalView?.removeFromSuperview()
        currentTerminalView = view
        guard let view else {
            emptyLabel.isHidden = false
            return
        }
        emptyLabel.isHidden = true
        view.removeFromSuperview()
        view.frame = terminalContent.bounds
        view.autoresizingMask = [.width, .height]
        terminalContent.addSubview(view)
    }

    func setMainSurfaceColor(_ color: NSColor?) {
        mainSurfaceColor = color
        applyMainSurfaceColor()
    }

    private func applyMainSurfaceColor() {
        let color = mainSurfaceColor ?? .textBackgroundColor
        layer?.backgroundColor = color.cgColor
        header.layer?.backgroundColor = color.cgColor
        terminalContent.layer?.backgroundColor = color.cgColor
    }

    private func configureTabScrollView() {
        tabScrollView.drawsBackground = false
        tabScrollView.borderType = .noBorder
        tabScrollView.hasHorizontalScroller = false
        tabScrollView.hasVerticalScroller = false
        tabScrollView.autohidesScrollers = true
        tabScrollView.scrollerStyle = .overlay
        tabScrollView.contentView.drawsBackground = false
        tabScrollView.documentView = tabStrip
    }

    private func updateTabs(_ tabs: [TerminalDockTab]) {
        let incomingIDs = Set(tabs.map(\.id))
        let removedIDs = tabViews.keys.filter { !incomingIDs.contains($0) }
        for id in removedIDs {
            tabViews.removeValue(forKey: id)?.removeFromSuperview()
        }

        for tab in tabs {
            let tabView: TerminalTabView
            if let existing = tabViews[tab.id] {
                tabView = existing
            } else {
                tabView = TerminalTabView()
                tabView.onSelectRequested = { [weak self] tabID in
                    self?.onSelectTerminalRequested?(tabID)
                }
                tabView.onCloseRequested = { [weak self] tabID in
                    self?.onCloseTerminalRequested?(tabID)
                }
                tabViews[tab.id] = tabView
                tabStrip.addSubview(tabView)
            }
            tabView.configure(tab)
        }
        tabOrder = tabs.map(\.id)
        pendingActiveTabID = tabs.first(where: \.isActive)?.id
        needsLayout = true
    }

    private func layoutTabStrip(availableWidth: CGFloat, tabHeight: CGFloat) {
        let spacing: CGFloat = 4
        let addButtonSize: CGFloat = 28
        var x: CGFloat = 0
        for id in tabOrder {
            guard let tabView = tabViews[id] else { continue }
            let width = tabView.preferredWidth
            tabView.frame = NSRect(x: x, y: 0, width: width, height: tabHeight)
            x += width + spacing
        }
        newTabButton.frame = NSRect(x: x, y: 0, width: addButtonSize, height: tabHeight)
        x += addButtonSize
        tabStrip.frame = NSRect(x: 0, y: 0, width: max(availableWidth, x), height: tabHeight)
    }

    private func scrollPendingActiveTabIntoView() {
        guard let pendingActiveTabID else { return }
        self.pendingActiveTabID = nil
        guard let tabView = tabViews[pendingActiveTabID] else { return }
        tabStrip.scrollToVisible(tabView.frame.insetBy(dx: -8, dy: 0))
    }

    @objc private func createTerminal(_ sender: NSButton) {
        onNewTerminalRequested?()
    }

    @objc private func hidePanel(_ sender: NSButton) {
        onHideRequested?()
    }
}

/// 原生标签栏中的一个真实终端。点击标签切换同 workspace 的独立 PTY；标签内 `×`
/// 只结束该 PTY，最右侧独立 `×` 则只收起整个 dock。
private final class TerminalTabView: NSView {
    var onSelectRequested: ((UUID) -> Void)?
    var onCloseRequested: ((UUID) -> Void)?

    private let terminalImage = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "终端")
    private let closeButton = NSButton()
    private var tabID: UUID?
    private var isActive = false
    private var isPressed = false

    var preferredWidth: CGFloat {
        let naturalWidth = titleLabel.intrinsicContentSize.width + 14 + 8 + 24 + 22
        return min(280, max(132, naturalWidth))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        terminalImage.image = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: "终端"
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        terminalImage.imageScaling = .scaleProportionallyDown
        terminalImage.setAccessibilityElement(false)
        addSubview(terminalImage)

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.usesSingleLineMode = true
        titleLabel.setAccessibilityElement(false)
        addSubview(titleLabel)

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "关闭终端标签"
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        closeButton.target = self
        closeButton.action = #selector(closeTerminal(_:))
        addSubview(closeButton)

        configure(TerminalDockTab(id: UUID(), title: "终端", isActive: true))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func layout() {
        super.layout()
        let horizontalInset: CGFloat = 10
        let iconSize: CGFloat = 14
        let closeSize: CGFloat = 24
        terminalImage.frame = NSRect(
            x: horizontalInset,
            y: max(0, (bounds.height - iconSize) / 2),
            width: iconSize,
            height: iconSize
        )

        let titleX = terminalImage.frame.maxX + 8
        let closeX = bounds.maxX - closeSize - 3
        closeButton.frame = NSRect(
            x: closeX,
            y: max(0, (bounds.height - closeSize) / 2),
            width: closeSize,
            height: closeSize
        )
        titleLabel.frame = NSRect(
            x: titleX,
            y: max(0, (bounds.height - titleLabel.intrinsicContentSize.height) / 2),
            width: max(0, closeX - titleX - 5),
            height: titleLabel.intrinsicContentSize.height
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard !closeButton.frame.contains(location) else {
            super.mouseDown(with: event)
            return
        }
        isPressed = true
        updateAppearance()
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let shouldSelect = isPressed && bounds.contains(location)
        isPressed = false
        updateAppearance()
        if shouldSelect, let tabID {
            onSelectRequested?(tabID)
        }
    }

    func configure(_ tab: TerminalDockTab) {
        tabID = tab.id
        isActive = tab.isActive
        titleLabel.stringValue = tab.title
        let tabLabel = tab.isActive ? "当前终端标签：\(tab.title)" : "终端标签：\(tab.title)"
        setAccessibilityLabel(tabLabel)
        toolTip = tab.isActive ? "当前终端：\(tab.title)" : "切换到终端：\(tab.title)"
        let closeLabel = "关闭终端标签 \(tab.title)（结束 shell）"
        closeButton.toolTip = closeLabel
        closeButton.setAccessibilityLabel(closeLabel)
        updateAppearance()
        needsLayout = true
    }

    private func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let isEmphasized = isActive || isPressed
        let background: NSColor
        if isEmphasized {
            background = isDark
                ? NSColor(calibratedWhite: 1, alpha: 0.10)
                : NSColor(calibratedWhite: 0, alpha: 0.08)
        } else {
            background = .clear
        }
        layer?.backgroundColor = background.cgColor
        layer?.borderWidth = isEmphasized ? 0.5 : 0
        layer?.borderColor = isEmphasized
            ? NSColor.separatorColor.withAlphaComponent(0.45).cgColor
            : NSColor.clear.cgColor
        titleLabel.textColor = isActive ? .labelColor : .secondaryLabelColor
        terminalImage.contentTintColor = isActive ? .labelColor : .secondaryLabelColor
        closeButton.contentTintColor = isActive ? .secondaryLabelColor : .tertiaryLabelColor
    }

    @objc private func closeTerminal(_ sender: NSButton) {
        guard let tabID else { return }
        onCloseRequested?(tabID)
    }
}

/// SwiftUI 外层只持有该原生 dock；重新渲染不会新建或替换 WebContainer 所持有的
/// WKWebView，从而保留 DSH 页面和会话状态。
struct TerminalDockHost: NSViewRepresentable {
    let container: WebContainer
    let terminalController: DesktopTerminalController
    /// `NSViewRepresentable` 不能只依赖 `WebContainer` 的对象身份判断刷新；加载状态
    /// 必须作为值类型输入传入，才能保证原生遮罩在网页首帧完成后立刻撤掉。
    let isPageLoading: Bool

    func makeNSView(context: Context) -> TerminalDockContainer {
        let dock = TerminalDockContainer(webView: container.webView)
        dock.setLoadingCoverVisible(isPageLoading)
        terminalController.attach(dock: dock)
        return dock
    }

    func updateNSView(_ dock: TerminalDockContainer, context: Context) {
        dock.setLoadingCoverVisible(isPageLoading)
        terminalController.attach(dock: dock)
    }

    static func dismantleNSView(_ dock: TerminalDockContainer, coordinator: ()) {
        // WebView 本身由 WebContainer 持有；拆卸临时 SwiftUI host 时不终止 shell。
    }
}
