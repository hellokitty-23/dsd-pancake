import AppKit

enum ChromeStyleBridge {
    static let messageName = "dshDesktopChromeStyle"

    /// 只读取 DSH 页面根布局的几何和已计算的表面色。它不读取文字、会话、Cookie，
    /// 不写入 DOM，也不拦截键鼠或修改 DSH 功能。
    static let script = #"""
    (() => {
      "use strict";
      const bridgeName = "dshDesktopChromeStyle";
      if (window.__dshDesktopChromeStyleBridgeInstalled) return;
      Object.defineProperty(window, "__dshDesktopChromeStyleBridgeInstalled", {
        value: true,
        configurable: false,
        writable: false,
      });

      const messageHandler = window.webkit && window.webkit.messageHandlers
        ? window.webkit.messageHandlers[bridgeName]
        : null;
      if (!messageHandler || typeof messageHandler.postMessage !== "function") return;

      const finite = (value) => Number.isFinite(value);
      const colorPattern = /^rgba?\(\s*([0-9.]+)[,\s]+([0-9.]+)[,\s]+([0-9.]+)(?:[,\s/]+([0-9.]+))?\s*\)$/i;

      const parseColor = (value) => {
        const match = colorPattern.exec(value || "");
        if (!match) return null;
        const red = Number(match[1]);
        const green = Number(match[2]);
        const blue = Number(match[3]);
        const alpha = match[4] === undefined ? 1 : Number(match[4]);
        if (![red, green, blue, alpha].every(finite)) return null;
        if (red < 0 || red > 255 || green < 0 || green > 255 || blue < 0 || blue > 255 || alpha < 0 || alpha > 1) return null;
        return { red, green, blue, alpha };
      };

      const opaqueBackground = (element, fallback) => {
        for (let node = element; node instanceof Element; node = node.parentElement) {
          const color = parseColor(getComputedStyle(node).backgroundColor);
          if (color && color.alpha > 0.01) return color;
        }
        return fallback;
      };

      const findFrame = () => {
        const root = document.getElementById("root") || document.body;
        if (!root) return null;
        const viewportWidth = window.innerWidth;
        const viewportHeight = window.innerHeight;
        // 兼容 DSH 将根节点本身设为网格，或在根节点下再包一层的两种实现。
        for (const candidate of [root, ...root.querySelectorAll("*")]) {
          const rect = candidate.getBoundingClientRect();
          if (rect.left > 1 || rect.top > 1 || rect.width < viewportWidth - 2 || rect.height < viewportHeight - 2) continue;
          const style = getComputedStyle(candidate);
          if (style.display !== "grid") continue;
          if (candidate.children.length < 2) continue;
          const sidebar = candidate.children[0];
          const sidebarRect = sidebar.getBoundingClientRect();
          if (sidebarRect.left > 1 || sidebarRect.width <= 0 || sidebarRect.width >= viewportWidth * 0.75) continue;
          return { frame: candidate, sidebar };
        }
        return null;
      };

      let observedFrame = null;
      let observedSidebar = null;
      let lastSerialized = "";
      let scheduled = false;
      const resizeObserver = new ResizeObserver(() => schedule());

      const cachedLayout = () => {
        if (!observedFrame || !observedSidebar) return null;
        if (!observedFrame.isConnected || !observedSidebar.isConnected) return null;
        if (observedSidebar.parentElement !== observedFrame) return null;
        return { frame: observedFrame, sidebar: observedSidebar };
      };

      const invalidateLayout = () => {
        resizeObserver.disconnect();
        observedFrame = null;
        observedSidebar = null;
        lastSerialized = "";
        schedule();
      };

      const publish = () => {
        scheduled = false;
        // 首次或根布局替换时才遍历页面。侧栏拖动会触发 ResizeObserver，
        // 后续帧直接复用这两个节点，避免长会话 DOM 在拖动时被反复扫描。
        const layout = cachedLayout() || findFrame();
        if (!layout) return;

        if (layout.frame !== observedFrame || layout.sidebar !== observedSidebar) {
          resizeObserver.disconnect();
          resizeObserver.observe(layout.frame);
          resizeObserver.observe(layout.sidebar);
          observedFrame = layout.frame;
          observedSidebar = layout.sidebar;
        }

        const sidebarRect = layout.sidebar.getBoundingClientRect();
        const main = opaqueBackground(layout.frame, null);
        const sidebar = opaqueBackground(layout.sidebar, null);
        const divider = parseColor(getComputedStyle(layout.sidebar).borderRightColor);
        if (!main || !sidebar || !divider || !finite(sidebarRect.width)) return;

        const snapshot = {
          sidebarWidth: Math.max(0, Math.min(window.innerWidth, sidebarRect.width)),
          sidebar,
          main,
          divider,
        };
        const serialized = JSON.stringify(snapshot);
        if (serialized === lastSerialized) return;
        lastSerialized = serialized;
        messageHandler.postMessage(snapshot);
      };

      const schedule = () => {
        if (scheduled) return;
        scheduled = true;
        window.requestAnimationFrame(publish);
      };

      const root = document.getElementById("root");
      if (root) {
        new MutationObserver(invalidateLayout).observe(root, { childList: true });
      }
      new MutationObserver(schedule).observe(document.documentElement, {
        attributes: true,
        attributeFilter: ["class", "style", "data-theme"],
      });
      if (document.body) {
        new MutationObserver(schedule).observe(document.body, {
          attributes: true,
          attributeFilter: ["class", "style", "data-ds-dark-theme"],
        });
      }
      window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", schedule);

      let attempts = 0;
      const bootstrap = () => {
        schedule();
        if (observedFrame || attempts >= 120) return;
        attempts += 1;
        window.setTimeout(bootstrap, 250);
      };
      bootstrap();
    })();
    """#

    static func decode(_ body: Any) -> ChromeSurfaceStyle? {
        guard let dictionary = body as? [String: Any],
              let sidebarWidth = finiteNumber(dictionary["sidebarWidth"]),
              let sidebarColor = color(dictionary["sidebar"]),
              let mainColor = color(dictionary["main"]),
              let dividerColor = color(dictionary["divider"]),
              sidebarWidth >= 0,
              sidebarWidth <= 20_000 else {
            return nil
        }
        return ChromeSurfaceStyle(
            sidebarWidth: sidebarWidth,
            sidebarColor: sidebarColor,
            mainColor: mainColor,
            dividerColor: dividerColor
        )
    }

    private static func color(_ value: Any?) -> ChromeSurfaceStyle.RGBA? {
        guard let dictionary = value as? [String: Any],
              let red = finiteNumber(dictionary["red"]),
              let green = finiteNumber(dictionary["green"]),
              let blue = finiteNumber(dictionary["blue"]),
              let alpha = finiteNumber(dictionary["alpha"]),
              (0 ... 255).contains(red),
              (0 ... 255).contains(green),
              (0 ... 255).contains(blue),
              (0 ... 1).contains(alpha) else {
            return nil
        }
        return ChromeSurfaceStyle.RGBA(
            red: red / 255,
            green: green / 255,
            blue: blue / 255,
            alpha: alpha
        )
    }

    private static func finiteNumber(_ value: Any?) -> CGFloat? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        guard result.isFinite else { return nil }
        return CGFloat(result)
    }
}
