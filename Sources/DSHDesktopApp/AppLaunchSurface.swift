import AppKit

/// 页面尚未产生真实主题色时使用的中性启动底色。
///
/// 这不是应用的强制主题：`ChromeStyleBridge`（网页视觉桥）一旦收到 DSH 已计算的
/// 表面色，就会立即以网页实际颜色替换它。固定为深色仅用于避免 WKWebView 在首帧
/// 使用默认白色，从而在深色 DSH 页面前产生闪白。
enum AppLaunchSurface {
    static let color = NSColor(
        srgbRed: 22 / 255,
        green: 22 / 255,
        blue: 22 / 255,
        alpha: 1
    )
}
