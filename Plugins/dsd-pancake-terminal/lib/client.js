window.__ModuleLoader__.load({
  id: "@dsd-pancake/dsh-desktop-terminal",
  factory: (require) => {
    const module = { exports: {} }
    const exports = module.exports

    const bridgeName = "dsdPancakeTerminal"
    const protocolVersion = 1
    const layoutEventName = "dsd-pancake-terminal-layout"
    const maximumReservationHeight = 20_000

    const isRecord = (value) => typeof value === "object" && value !== null && !Array.isArray(value)

    const bridgeHandler = () => {
      const handler = window.webkit?.messageHandlers?.[bridgeName]
      return handler && typeof handler.postMessage === "function" ? handler : undefined
    }

    const post = async (action, fields = {}) => {
      const handler = bridgeHandler()
      if (handler === undefined) return undefined
      try {
        const response = await handler.postMessage({
          version: protocolVersion,
          action,
          ...fields,
        })
        return isRecord(response) ? response : undefined
      } catch {
        // 普通浏览器没有 bridge，或 WebKit 正在销毁页面；两种情况都安全降级为 no-op。
        return undefined
      }
    }

    const currentWorkspace = (sessions) => {
      const snapshot = sessions.list.getSnapshot()
      if (!isRecord(snapshot) || typeof snapshot.current !== "string") {
        return undefined
      }

      // DSH 0.1.1-rc.2 将公开会话摘要从 `byId` 索引改为 `items` 数组；保留
      // 旧索引回退以兼容仍提供该稳定 public shape 的版本。两种路径都只读取
      // current 对应的一条摘要，不扫描历史会话或网页 DOM。
      const summary = Array.isArray(snapshot.items)
        ? snapshot.items.find((item) => isRecord(item) && item.sessionId === snapshot.current)
        : isRecord(snapshot.byId)
          ? snapshot.byId[snapshot.current]
          : undefined
      if (!isRecord(summary) || typeof summary.cwd !== "string" || summary.cwd.length === 0) {
        return undefined
      }
      return { sessionID: snapshot.current, workspacePath: summary.cwd }
    }

    // 这是原生壳单向发送的纯视觉状态，不是 WebKit bridge action。它不能打开、
    // 收起或控制终端；即使网页自行伪造事件，至多影响自己的空白高度，完全不能
    // 扩大本机权限。严格归一化也避免未知字段或异常数值进入 React style。
    const normalizedDockLayout = (value) => {
      if (
        !isRecord(value)
        || value.version !== protocolVersion
        || value.open !== true
        || typeof value.reservedHeight !== "number"
        || !Number.isFinite(value.reservedHeight)
      ) {
        return { open: false, reservedHeight: 0 }
      }
      return {
        open: true,
        reservedHeight: Math.min(Math.max(0, value.reservedHeight), maximumReservationHeight),
      }
    }

    const sameDockLayout = (left, right) => (
      left.open === right.open && left.reservedHeight === right.reservedHeight
    )

    const registerConversationReservation = (ctx) => {
      // 普通浏览器在 capability 协商前就返回，因此不会加载 React、注册 slot 或读取
      // DSH session；只有 App 私有 bridge 可用时才引入这个不可交互的布局组件。
      if (
        ctx.slots === undefined
        || typeof ctx.slots.inject !== "function"
        || typeof ctx.slots.register !== "function"
      ) {
        return
      }

      const react = require("react")
      const { jsx } = require("react/jsx-runtime")

      const useDockLayout = () => {
        const [layout, setLayout] = react.useState(() => normalizedDockLayout(
          window.__dshDesktopTerminalDockLayout,
        ))

        react.useEffect(() => {
          if (
            typeof window.addEventListener !== "function"
            || typeof window.removeEventListener !== "function"
          ) {
            return undefined
          }
          const receiveLayout = (event) => {
            const next = normalizedDockLayout(event?.detail)
            setLayout((current) => (sameDockLayout(current, next) ? current : next))
          }
          window.addEventListener(layoutEventName, receiveLayout)
          return () => {
            window.removeEventListener(layoutEventName, receiveLayout)
          }
        }, [])

        return layout
      }

      const TerminalConversationReservation = () => {
        const layout = useDockLayout()
        if (!layout.open || layout.reservedHeight <= 0) return null
        return jsx("div", {
          "aria-hidden": true,
          "data-dsd-pancake-terminal-reservation": "",
          style: {
            boxSizing: "border-box",
            flex: "none",
            height: `${String(layout.reservedHeight)}px`,
            pointerEvents: "none",
            width: "100%",
          },
        })
      }

      // composer.dock 是 DSH 公开的、位于 input card（输入卡片）之后的扩展位。
      // 占位紧跟 stats 等 footer，故其高度会把输入框和消息流一起顶到原生 dock 上方，
      // 而不是在对话上方制造空白或接管整个 conversation surface（对话表面）。
      ctx.slots.inject("conversation.composer.dock", () => ctx.slots.register({
        name: "conversation.composer.dock",
        id: "dsd-pancake-terminal-reservation",
        order: 10_000,
      }, TerminalConversationReservation))
    }

    const apply = (ctx) => {
      // 没有 App 私有 bridge 时，既不注册 slot、也不读取 DSH session/workspace；
      // 所以普通 `dsh web` 与浏览器访问完全不受此插件影响。拿到原生能力后才注册
      // 一个不可交互的 footer 高度占位，并只订阅正式 sessions.list 的 current（当前
      // 会话）项，连新会话页的空白 session 也能同步 cwd；不会读取其它会话，也不会
      // 在 DSH 中渲染终端入口、按钮或 terminal view（终端视图）。
      void post("capabilities").then((response) => {
        if (response?.supported !== true) return

        registerConversationReservation(ctx)

        let lastWorkspaceKey
        const synchronize = () => {
          const workspace = currentWorkspace(ctx.sessions)
          const workspaceKey = workspace === undefined
            ? ""
            : `${workspace.sessionID}\u0000${workspace.workspacePath}`
          if (workspaceKey === lastWorkspaceKey) return
          lastWorkspaceKey = workspaceKey
          void (workspace === undefined
            ? post("clearWorkspace")
            : post("syncWorkspace", workspace))
        }

        ctx.effect(() => {
          synchronize()
          const unsubscribe = ctx.sessions.list.subscribe(synchronize)
          return () => {
            unsubscribe()
          }
        }, "dsd-pancake-terminal: workspace sync")
      })
    }

    exports.apply = apply
    exports.inject = ["sessions", "slots"]
    return module.exports
  },
})
