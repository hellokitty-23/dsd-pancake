window.__ModuleLoader__.load({
  id: "@dsd-pancake/dsh-desktop-shortcuts",
  factory: (require) => {
    const module = { exports: {} }
    const exports = module.exports

    const armWindowMilliseconds = 2_000
    const failureHintMilliseconds = 2_000
    const singletonKey = Symbol.for("@dsd-pancake/dsh-desktop-shortcuts:dispose")
    const hiddenStatus = Object.freeze({ kind: "hidden", message: "" })
    const escapeSurfaceSelector = [
      "dialog[open]",
      "[aria-modal='true']",
      "[role='dialog']",
      "[role='alertdialog']",
      "[role='menu']",
      "[role='listbox']",
      "[aria-haspopup='dialog'][aria-expanded='true']",
      "[aria-haspopup='menu'][aria-expanded='true']",
      "[aria-haspopup='listbox'][aria-expanded='true']",
      "[aria-haspopup='tree'][aria-expanded='true']",
      "button[aria-expanded='true'] + ul[aria-label]",
    ].join(",")

    const isRecord = (value) => typeof value === "object" && value !== null && !Array.isArray(value)

    const createStatusStore = () => {
      let snapshot = hiddenStatus
      const listeners = new Set()
      const publish = (next) => {
        snapshot = next
        for (const listener of listeners) listener()
      }
      return {
        getSnapshot: () => snapshot,
        subscribe(listener) {
          listeners.add(listener)
          return () => listeners.delete(listener)
        },
        show(kind, message) {
          publish({ kind, message })
        },
        clear() {
          if (snapshot !== hiddenStatus) publish(hiddenStatus)
        },
        dispose() {
          snapshot = hiddenStatus
          listeners.clear()
        },
      }
    }

    const registerStatusOverlay = (ctx, status) => {
      if (
        !isRecord(ctx.slots)
        || typeof ctx.slots.inject !== "function"
        || typeof ctx.slots.register !== "function"
      ) {
        return () => {}
      }

      const react = require("react")
      const { jsx } = require("react/jsx-runtime")

      const ShortcutStatus = () => {
        const current = react.useSyncExternalStore(
          status.subscribe,
          status.getSnapshot,
          status.getSnapshot,
        )
        if (current.kind === "hidden") return null
        return jsx("div", {
          role: "status",
          "aria-live": "polite",
          "aria-atomic": true,
          "data-dsd-pancake-shortcut-status": current.kind,
          style: {
            position: "absolute",
            bottom: "24px",
            left: "50%",
            transform: "translateX(-50%)",
            zIndex: 1,
            boxSizing: "border-box",
            maxWidth: "min(520px, calc(100% - 32px))",
            padding: "7px 12px",
            border: "1px solid var(--dsw-alias-border-l2-darkmode-thin)",
            borderRadius: "10px",
            background: "var(--dsw-alias-button-floating-fill)",
            boxShadow: "var(--dsw-shadow-lv2)",
            color: current.kind === "failure"
              ? "var(--dsw-alias-state-error-primary)"
              : "var(--dsw-alias-label-primary)",
            font: "var(--dsw-font-xs-13)",
            lineHeight: "20px",
            overflow: "hidden",
            pointerEvents: "none",
            textAlign: "center",
            textOverflow: "ellipsis",
            whiteSpace: "nowrap",
          },
          children: current.message,
        })
      }

      return ctx.slots.inject("shell.overlay", () => ctx.slots.register({
        name: "shell.overlay",
        id: "dsd-pancake-shortcut-status",
        order: 10_000,
        label: "DSD Pancake shortcut status",
      }, ShortcutStatus))
    }

    const summaryFor = (snapshot, sessionID) => {
      if (
        !isRecord(snapshot)
        || typeof sessionID !== "string"
        || !Array.isArray(snapshot.ids)
        || !snapshot.ids.includes(sessionID)
        || !isRecord(snapshot.byId)
      ) return undefined
      return snapshot.byId[sessionID]
    }

    const currentState = (sessions) => {
      const snapshot = sessions.list.getSnapshot()
      const sessionID = isRecord(snapshot) && typeof snapshot.current === "string"
        ? snapshot.current
        : undefined
      const summary = summaryFor(snapshot, sessionID)
      return {
        sessionID,
        running: isRecord(summary) && summary.running === true,
      }
    }

    const cancellableCurrentSession = (sessions) => {
      const state = currentState(sessions)
      if (state.sessionID === undefined || !state.running) return undefined
      const binding = sessions.binding(state.sessionID)
      if (!isRecord(binding) || !isRecord(binding.session) || typeof binding.session.cancel !== "function") {
        return undefined
      }
      return { sessionID: state.sessionID, session: binding.session }
    }

    const hasOpenEscapeSurface = () => {
      const document = window.document
      if (typeof document?.querySelectorAll !== "function") return false
      return [...document.querySelectorAll(escapeSurfaceSelector)].some((element) => (
        element?.hidden !== true
        && element?.getAttribute?.("aria-hidden") !== "true"
      ))
    }

    const hasEscapeEditingTarget = (event) => (
      typeof event?.target?.matches === "function" && event.target.matches("input")
    )

    const escapeWasConsumed = (event) => (
      event?.defaultPrevented === true || event?.cancelBubble === true
    )

    const installDoubleEscape = (ctx, status) => {
      let active = true
      let armedSessionID
      let armedAt = 0
      let armTimer
      let failureTimer
      let observedSessionID = currentState(ctx.sessions).sessionID
      const cancellingSessions = new Set()

      const now = () => (
        typeof window.performance?.now === "function" ? window.performance.now() : Date.now()
      )

      const clearTimer = (timer) => {
        if (timer !== undefined) window.clearTimeout(timer)
      }

      const clearArm = () => {
        clearTimer(armTimer)
        armTimer = undefined
        armedSessionID = undefined
        armedAt = 0
        if (status.getSnapshot().kind === "armed") status.clear()
      }

      const clearFailure = () => {
        clearTimer(failureTimer)
        failureTimer = undefined
        if (status.getSnapshot().kind === "failure") status.clear()
      }

      const reset = () => {
        clearArm()
        clearFailure()
      }

      const showFailure = (sessionID) => {
        const state = currentState(ctx.sessions)
        if (!active || state.sessionID !== sessionID || !state.running) return
        clearFailure()
        status.show("failure", "停止失败，请重试")
        failureTimer = window.setTimeout(() => {
          failureTimer = undefined
          if (status.getSnapshot().kind === "failure") status.clear()
        }, failureHintMilliseconds)
      }

      const arm = (sessionID) => {
        reset()
        armedSessionID = sessionID
        armedAt = now()
        status.show("armed", "再按一次 Esc 停止生成")
        // 延后一毫秒清理，使 `elapsed === 2000` 的第二次 Esc 仍符合闭区间约定。
        armTimer = window.setTimeout(() => {
          armTimer = undefined
          if (armedSessionID !== sessionID) return
          armedSessionID = undefined
          armedAt = 0
          if (status.getSnapshot().kind === "armed") status.clear()
        }, armWindowMilliseconds + 1)
      }

      const requestCancel = (target) => {
        const { sessionID, session } = target
        if (cancellingSessions.has(sessionID)) return
        cancellingSessions.add(sessionID)
        void Promise.resolve()
          .then(() => session.cancel())
          .then((result) => {
            if (!isRecord(result) || result.ok !== true) {
              cancellingSessions.delete(sessionID)
              showFailure(sessionID)
            }
          })
          .catch(() => {
            cancellingSessions.delete(sessionID)
            showFailure(sessionID)
          })
      }

      const onKeyDown = (event) => {
        if (!active) return
        if (event?.key !== "Escape") {
          if (event?.key !== undefined) reset()
          return
        }
        if (escapeWasConsumed(event)) {
          reset()
          return
        }
        // DSH 有些弹层只在 Escape handler 中关闭自身，并不会调用 preventDefault。
        // 必须在 capture phase、弹层尚未卸载时识别，避免把关闭弹层算作第一次或第二次 Esc。
        if (hasOpenEscapeSurface() || hasEscapeEditingTarget(event)) {
          reset()
          return
        }
        if (
          event.altKey === true
          || event.ctrlKey === true
          || event.metaKey === true
          || event.shiftKey === true
          || event.repeat === true
          || event.isComposing === true
          || event.keyCode === 229
          || event.which === 229
        ) {
          reset()
          return
        }

        // 在 capture phase 先看到事件，等 DSH 的 target/bubble handlers 都完成后，
        // 只把仍未被消费的 Escape 计入双击。这样 composer 可以正常工作；
        // preventDefault 的处理器与上面的可见弹层检测共同隔离 DSH 自己的 Escape 行为。
        const afterPropagation = () => {
          if (!active) return
          if (escapeWasConsumed(event)) {
            reset()
            return
          }

          const target = cancellableCurrentSession(ctx.sessions)
          if (target === undefined) {
            reset()
            return
          }
          if (cancellingSessions.has(target.sessionID)) return

          const elapsed = now() - armedAt
          if (
            armedSessionID === target.sessionID
            && elapsed >= 0
            && elapsed <= armWindowMilliseconds
          ) {
            clearArm()
            requestCancel(target)
            return
          }
          arm(target.sessionID)
        }
        if (typeof window.queueMicrotask === "function") window.queueMicrotask(afterPropagation)
        else void Promise.resolve().then(afterPropagation)
      }

      const onPointerDown = () => reset()
      const onBlur = () => reset()
      const synchronizeSession = () => {
        const snapshot = ctx.sessions.list.getSnapshot()
        for (const sessionID of cancellingSessions) {
          const summary = summaryFor(snapshot, sessionID)
          if (!isRecord(summary) || summary.running !== true) {
            cancellingSessions.delete(sessionID)
          }
        }
        const state = currentState(ctx.sessions)
        if (state.sessionID !== observedSessionID) {
          observedSessionID = state.sessionID
          reset()
          return
        }
        if (!state.running) reset()
      }

      // DSH 的 composer 会在 React 冒泡阶段处理 Escape，并可能设置
      // defaultPrevented。快捷键先在捕获阶段记录弹层状态，再于传播完成后判断；
      // 两次有效 Escape 都不劫持原事件，只复用同一条 cancel 路径。
      window.addEventListener("keydown", onKeyDown, true)
      window.addEventListener("pointerdown", onPointerDown, true)
      window.addEventListener("blur", onBlur, false)
      const unsubscribe = ctx.sessions.list.subscribe(synchronizeSession)

      let disposed = false
      return () => {
        if (disposed) return
        disposed = true
        active = false
        reset()
        cancellingSessions.clear()
        unsubscribe()
        window.removeEventListener("keydown", onKeyDown, true)
        window.removeEventListener("pointerdown", onPointerDown, true)
        window.removeEventListener("blur", onBlur, false)
      }
    }

    const apply = (ctx) => {
      if (
        !isRecord(ctx.sessions)
        || !isRecord(ctx.sessions.list)
        || typeof ctx.sessions.list.getSnapshot !== "function"
        || typeof ctx.sessions.list.subscribe !== "function"
        || typeof ctx.sessions.binding !== "function"
        || typeof ctx.effect !== "function"
        || typeof window.addEventListener !== "function"
        || typeof window.removeEventListener !== "function"
        || typeof window.setTimeout !== "function"
        || typeof window.clearTimeout !== "function"
      ) {
        return
      }

      ctx.effect(() => {
        const previous = window[singletonKey]
        if (typeof previous === "function") previous()

        const status = createStatusStore()
        const disposeOverlay = registerStatusOverlay(ctx, status)
        const disposeShortcut = installDoubleEscape(ctx, status)
        let disposed = false
        const dispose = () => {
          if (disposed) return
          disposed = true
          disposeShortcut()
          disposeOverlay?.()
          status.dispose()
          if (window[singletonKey] === dispose) delete window[singletonKey]
        }
        window[singletonKey] = dispose
        return dispose
      }, "dsd-pancake-shortcuts: double Escape lifecycle")
    }

    exports.apply = apply
    exports.inject = ["sessions", "slots"]
    return module.exports
  },
})
