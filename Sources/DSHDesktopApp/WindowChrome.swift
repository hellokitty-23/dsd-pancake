import AppKit

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
}

/// 全尺寸原生背景只负责标题栏区域。SwiftUI 内容仍固定在
/// `safeAreaLayoutGuide`（安全内容区域）内，因此红绿灯不会压住 DSH 网页。
@MainActor
final class WindowChromeContainer: NSView {
    private let backdropView = WindowChromeBackdropView()
    private weak var hostedView: NSView?

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

    func apply(style: ChromeSurfaceStyle?) {
        backdropView.style = style
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
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        guard let style, bounds.width > 0 else { return }

        style.mainColor.nsColor.setFill()
        bounds.fill()

        let sidebarWidth = min(max(style.sidebarWidth, 0), bounds.width)
        guard sidebarWidth > 0 else { return }

        style.sidebarColor.nsColor.setFill()
        NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height).fill()

        guard sidebarWidth < bounds.width else { return }
        let scale = window?.backingScaleFactor ?? 1
        let dividerWidth = 1 / scale
        style.dividerColor.nsColor.setFill()
        NSRect(
            x: max(0, sidebarWidth - dividerWidth),
            y: 0,
            width: dividerWidth,
            height: bounds.height
        ).fill()
    }
}
