import AppKit
import DSHDesktopCore

/// 从网页仅同步出来的视觉表面：侧栏宽度、侧栏底色、主区域底色与分隔线颜色。
/// 不包含网页文字、会话、账号或任何功能状态。
struct ChromeSurfaceStyle: Equatable {
    struct RGBA: Equatable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        fileprivate var nsColor: NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
    }

    let sidebarWidth: CGFloat
    let sidebarColor: RGBA
    let mainColor: RGBA
    let dividerColor: RGBA

    /// 仅供原生壳层复用的右侧主画布色。它来自现有的只读 chrome bridge（视觉桥），
    /// 不增加网页读取范围，也不携带会话、路径或任何业务数据。
    var mainSurfaceColor: NSColor {
        mainColor.nsColor
    }
}

/// 全尺寸原生背景只负责标题栏区域。SwiftUI 内容仍固定在
/// `safeAreaLayoutGuide`（安全内容区域）内，因此红绿灯不会压住 DSH 网页。
@MainActor
final class WindowChromeContainer: NSView {
    private let backdropView = WindowChromeBackdropView()
    private weak var hostedView: NSView?
    private weak var updateIndicatorView: NSView?
    private var chromeStyle: ChromeSurfaceStyle?

    /// 更新浮层监听这一回调后，只重算自身 frame；网页和标题栏背景不经由它
    /// 反向读取任何更新状态。
    var onGeometryChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdropView)
        NSLayoutConstraint.activate([
            backdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func install(hostingView: NSView, safeAreaLayoutGuide: NSLayoutGuide) {
        precondition(hostedView == nil, "主窗口内容只能安装一次")
        hostedView = hostingView
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            hostingView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
        ])
    }

    func installUpdateIndicator(_ view: NSView) {
        precondition(updateIndicatorView == nil, "更新入口只能安装一次")
        updateIndicatorView = view
        addSubview(view)
        needsLayout = true
    }

    func installUpdateSurface(_ view: NSView) {
        if view.superview !== self {
            view.removeFromSuperview()
            addSubview(view, positioned: .above, relativeTo: updateIndicatorView)
        }
    }

    var updateLayout: UpdateOverlayLayout {
        UpdateOverlayLayout.resolve(
            totalWidth: bounds.width,
            sidebarWidth: chromeStyle?.sidebarWidth,
            minimumIndicatorCenterX: minimumIndicatorCenterX
        )
    }

    override func layout() {
        super.layout()
        guard let indicator = updateIndicatorView else {
            onGeometryChange?()
            return
        }
        let geometry = updateLayout
        let size = UpdateOverlayLayout.indicatorSize
        indicator.frame = NSRect(
            x: geometry.indicatorCenterX - size.width / 2,
            y: titlebarCenterY - size.height / 2,
            width: size.width,
            height: size.height
        ).integral
        onGeometryChange?()
    }

    func apply(style: ChromeSurfaceStyle?) {
        chromeStyle = style
        backdropView.style = style
        needsLayout = true
    }

    private var minimumIndicatorCenterX: CGFloat {
        guard let window else { return 0 }
        let trafficLights = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton),
        ].compactMap { $0 }
        let trailing = trafficLights.map { button in
            button.convert(button.bounds, to: self).maxX
        }.max() ?? 0
        return trailing + 24
    }

    private var titlebarCenterY: CGFloat {
        guard let window,
              let closeButton = window.standardWindowButton(.closeButton) else {
            return bounds.maxY - 14
        }
        return closeButton.convert(closeButton.bounds, to: self).midY
    }
}

@MainActor
private final class WindowChromeBackdropView: NSView {
    var style: ChromeSurfaceStyle? {
        didSet {
            guard style != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isOpaque: Bool {
        true
    }

    /// `.fullSizeContentView` 让这层背景占据原生标题栏区域，因此鼠标事件不会再
    /// 自动落到 AppKit 的标题栏视图。这里恢复标题栏的两项标准行为：单击拖动
    /// 窗口，双击执行系统“点按标题栏两下”偏好。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else {
            super.mouseDown(with: event)
            return
        }

        if event.clickCount == 2 {
            performTitlebarDoubleClickAction(on: window)
            return
        }

        window.performDrag(with: event)
    }

    private func performTitlebarDoubleClickAction(on window: NSWindow) {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            window.performMiniaturize(nil)
        case "None":
            break
        case "Maximize", "Fill", "Zoom":
            window.performZoom(nil)
        default:
            // 兼容旧版 macOS 只保存布尔偏好的情况；没有明确关闭时沿用标题栏
            // 的传统 zoom（缩放至系统建议尺寸）行为。
            if defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") {
                window.performMiniaturize(nil)
            } else {
                window.performZoom(nil)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        AppLaunchSurface.color.setFill()
        bounds.fill()

        guard let style, bounds.width > 0 else { return }

        style.mainColor.nsColor.setFill()
        bounds.fill()

        // 左侧栏不能从标题栏下方才开始，否则在红绿灯右侧会形成一条横向“壳子”
        // 与侧栏竖边相交的台阶。这里让侧栏表面和它的 1 physical pixel（物理像素）
        // 分隔线贯穿原生标题栏；网页内容区则从安全内容区域开始，两者在同一条竖线
        // 上无缝相接。不会额外绘制横向分层线。
        let sidebarWidth = min(max(style.sidebarWidth, 0), bounds.width)
        guard sidebarWidth > 0 else { return }

        style.sidebarColor.nsColor.setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: sidebarWidth, height: bounds.height).fill()

        guard sidebarWidth < bounds.width else { return }
        let scale = window?.backingScaleFactor ?? 1
        let dividerWidth = 1 / scale
        style.dividerColor.nsColor.setFill()
        NSRect(
            x: bounds.minX + sidebarWidth - dividerWidth,
            y: bounds.minY,
            width: dividerWidth,
            height: bounds.height
        ).fill()
    }
}
