import AppKit

/// 只提供 macOS 标准编辑动作的菜单。target 保持为 `nil`，由 AppKit responder
/// chain（响应链）将操作路由到当前的 `WKWebView` 或原生文本输入控件。
@MainActor
public enum StandardEditMenu {
    public static func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "编辑")
        menu.addItem(responderItem(title: "撤销", action: "undo:", keyEquivalent: "z"))
        menu.addItem(
            responderItem(
                title: "重做",
                action: "redo:",
                keyEquivalent: "z",
                modifiers: [.command, .shift]
            )
        )
        menu.addItem(.separator())
        menu.addItem(responderItem(title: "剪切", action: "cut:", keyEquivalent: "x"))
        menu.addItem(responderItem(title: "拷贝", action: "copy:", keyEquivalent: "c"))
        menu.addItem(responderItem(title: "粘贴", action: "paste:", keyEquivalent: "v"))
        menu.addItem(.separator())
        menu.addItem(responderItem(title: "全选", action: "selectAll:", keyEquivalent: "a"))
        return menu
    }

    private static func responderItem(
        title: String,
        action: String,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        // 不设置 target：AppKit 通过当前 first responder（首响应对象）处理命令。
        return item
    }
}
