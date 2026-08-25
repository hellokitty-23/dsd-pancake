window.__ModuleLoader__.load({
  id: "@dsd-pancake/dsh-desktop-notifications",
  factory: () => {
    const module = { exports: {} }
    const exports = module.exports

    const bridgeName = "dsdPancakeNotifications"
    const protocolVersion = 1
    const terminalGoalPhases = new Set(["complete", "blocked"])

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
        // 浏览器版 DSH 没有原生桥，或 WebKit 在页面销毁中拒绝消息；两种情况都静默降级。
        return undefined
      }
    }

    const createNativeBridge = () => {
      let authorized = false

      const refreshAuthorization = async () => {
        let response = await post("capabilities")
        if (response?.supported !== true) {
          authorized = false
          return false
        }
        if (response.authorization === "notDetermined") {
          response = await post("requestAuthorization")
        }
        authorized = response?.authorization === "authorized"
        return authorized
      }

      return {
        initialize: refreshAuthorization,
        notify(eventID, kind) {
          if (!authorized) return
          void post("notify", { eventID, kind }).then((response) => {
            // 用户可以在系统设置中撤销权限；下一次事件立即收敛为静默状态。
            if (response?.authorization !== "authorized") authorized = false
          })
        },
      }
    }

    // FNV-1a 的结果只用于 native bridge 的去重键，不是安全用途，也不携带会话文字。
    const opaqueID = (parts) => {
      let hash = 0x811c9dc5
      for (const part of parts) {
        const text = String(part)
        for (let index = 0; index < text.length; index += 1) {
          hash ^= text.charCodeAt(index)
          hash = Math.imul(hash, 0x01000193)
        }
        hash ^= 0
        hash = Math.imul(hash, 0x01000193)
      }
      return `dsh-${(hash >>> 0).toString(36)}`
    }

    const primarySession = (summary) =>
      isRecord(summary)
      && typeof summary.id === "string"
      && summary.id.length > 0
      && summary.parentId === undefined
      && summary.origin !== "subagent"

    const goalOf = (summary) => {
      const projection = isRecord(summary.projectionValues) ? summary.projectionValues.goal : undefined
      if (!isRecord(projection) || !isRecord(projection.goal)) return undefined
      const goal = projection.goal
      if (typeof goal.id !== "string" || !Number.isInteger(goal.revision) || typeof goal.phase !== "string") return undefined
      return { id: goal.id, revision: goal.revision, phase: goal.phase }
    }

    const stateOf = (summary) => ({
      running: summary.running === true,
      goal: goalOf(summary),
      updatedAt: Number.isFinite(summary.updatedAt) ? summary.updatedAt : 0,
    })

    const apply = (ctx) => {
      const nativeBridge = createNativeBridge()
      const previous = new Map()
      let active = true
      let unsubscribe

      const notifyGoalTerminal = (summary, goal) => {
        const kind = goal.phase === "complete" ? "goal-complete" : "goal-blocked"
        nativeBridge.notify(
          opaqueID(["goal", kind, summary.id, summary.updatedAt, goal.id, goal.revision]),
          kind,
        )
      }

      const observe = () => {
        if (!active) return
        const snapshot = ctx.sessions.list.getSnapshot()
        if (!isRecord(snapshot) || !isRecord(snapshot.byId) || !Array.isArray(snapshot.ids)) return

        const seen = new Set()
        for (const id of snapshot.ids) {
          const summary = snapshot.byId[id]
          if (!primarySession(summary)) continue

          const next = stateOf(summary)
          const before = previous.get(summary.id)
          seen.add(summary.id)

          // 首次观察只建立基线，绝不为页面打开前早已结束的任务补发提醒。
          if (before !== undefined) {
            const nextGoalIsTerminal = next.goal !== undefined && terminalGoalPhases.has(next.goal.phase)
            const enteredDistinctTerminalPhase = before.goal?.id !== next.goal?.id
              || before.goal?.phase !== next.goal?.phase

            if (nextGoalIsTerminal && enteredDistinctTerminalPhase) {
              notifyGoalTerminal(summary, next.goal)
            } else if (before.running && !next.running && before.goal === undefined && next.goal === undefined) {
              // 有 goal 的会话只在 goal 进入终态时提醒，避免普通回复和完成提醒重复。
              nativeBridge.notify(opaqueID(["reply", summary.id, next.updatedAt]), "reply")
            }
          }
          previous.set(summary.id, next)
        }

        for (const id of previous.keys()) {
          if (!seen.has(id)) previous.delete(id)
        }
      }

      const startObserving = () => {
        if (!active || unsubscribe !== undefined) return
        observe()
        unsubscribe = ctx.sessions.list.subscribe(observe)
      }

      // 仅 native WebView 存在时才会触发 macOS 授权并订阅会话；即使用户用普通
      // 浏览器访问 App 已启动的同一 DSH，插件也不会读取会话摘要或产生副作用。
      void nativeBridge.initialize().then((enabled) => {
        if (enabled) startObserving()
      })
      ctx.effect(() => () => {
        active = false
        unsubscribe?.()
        previous.clear()
      }, "dsd-pancake-notifications: session lifecycle")
    }

    exports.apply = apply
    exports.inject = ["sessions"]
    return module.exports
  },
})
