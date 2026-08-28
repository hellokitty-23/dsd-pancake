import Foundation

/// 更新入口和锚定浮层共用的水平布局。它只接收窗口与侧栏几何，不依赖
/// AppKit、SwiftUI 或网页节点，因此验证程序可以覆盖缩放与窄窗口边界。
public struct UpdateOverlayLayout: Equatable, Sendable {
    public static let indicatorSize = CGSize(width: 28, height: 24)
    public static let indicatorMainInset: CGFloat = 40
    public static let mainHorizontalInset: CGFloat = 16
    public static let arrowInset: CGFloat = 24
    public static let preferredWidth: CGFloat = 360
    public static let compactWidth: CGFloat = 280

    public let mainLeading: CGFloat
    public let indicatorCenterX: CGFloat
    public let surfaceOriginX: CGFloat
    public let surfaceWidth: CGFloat
    public let arrowX: CGFloat
    public let usesCompactActions: Bool
    public let arrowPointsToIndicator: Bool

    /// `minimumIndicatorCenterX` 是红绿灯右边缘之外的最小安全中心点。
    /// 正常窗口中浮层始终从主内容左边距开始，箭头固定在 24pt 并准确对准图标；
    /// 极窄窗口只优先保证内容不越过右边界，箭头允许进入降级位置。
    public static func resolve(
        totalWidth: CGFloat,
        sidebarWidth: CGFloat?,
        minimumIndicatorCenterX: CGFloat = 0
    ) -> UpdateOverlayLayout {
        let width = max(0, totalWidth)
        let content = TerminalDockLayout.contentRegion(
            totalWidth: width,
            sidebarWidth: sidebarWidth
        )
        let mainLeading = content.leading
        let indicatorCenterX = min(
            width,
            max(mainLeading + indicatorMainInset, minimumIndicatorCenterX)
        )
        let desiredOriginX = max(
            mainLeading + mainHorizontalInset,
            indicatorCenterX - arrowInset
        )
        let maximumSurfaceWidth = max(
            0,
            width - desiredOriginX - mainHorizontalInset
        )
        let surfaceWidth = min(preferredWidth, maximumSurfaceWidth)
        let rawArrowX = indicatorCenterX - desiredOriginX
        let minimumArrowX = min(arrowInset, surfaceWidth / 2)
        let maximumArrowX = max(minimumArrowX, surfaceWidth - minimumArrowX)
        let arrowX = min(max(rawArrowX, minimumArrowX), maximumArrowX)

        return UpdateOverlayLayout(
            mainLeading: mainLeading,
            indicatorCenterX: indicatorCenterX,
            surfaceOriginX: desiredOriginX,
            surfaceWidth: surfaceWidth,
            arrowX: arrowX,
            usesCompactActions: surfaceWidth < compactWidth,
            arrowPointsToIndicator: abs(arrowX - rawArrowX) < 0.5
        )
    }
}
