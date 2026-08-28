import { pathToFileURL } from "node:url"

let definition
globalThis.window = {
  __ModuleLoader__: {
    load(value) {
      definition = value
    },
  },
}

const clientURL = pathToFileURL(
  new URL("../Plugins/dsd-pancake-shortcuts/lib/client.js", import.meta.url).pathname,
)
await import(`${clientURL.href}?verify=${Date.now()}`)

const expect = (condition, message) => {
  if (!condition) throw new Error(message)
}

expect(definition !== undefined, "快捷键插件没有注册 DSH client module")
expect(definition.id === "@dsd-pancake/dsh-desktop-shortcuts", "快捷键插件注册了错误的 module id")

const settle = () => new Promise((resolve) => setImmediate(resolve))

const createClock = () => {
  let now = 0
  let nextID = 1
  const timers = new Map()

  const setTimeout = (callback, delay) => {
    const id = nextID
    nextID += 1
    timers.set(id, { callback, at: now + Math.max(0, Number(delay) || 0) })
    return id
  }

  const clearTimeout = (id) => {
    timers.delete(id)
  }

  const advance = (milliseconds) => {
    const target = now + milliseconds
    while (true) {
      const due = [...timers.entries()]
        .filter(([, timer]) => timer.at <= target)
        .sort((left, right) => left[1].at - right[1].at || left[0] - right[0])[0]
      if (due === undefined) break
      const [id, timer] = due
      timers.delete(id)
      now = timer.at
      timer.callback()
    }
    now = target
  }

  return {
    now: () => now,
    setTimeout,
    clearTimeout,
    advance,
    pending: () => timers.size,
  }
}

const createEventWindow = (clock) => {
  const listeners = new Map()
  const listenerCapture = new Map()
  const microtasks = []
  let openEscapeSurfaceSelector
  const usesCapture = (options) => options === true || options?.capture === true
  return {
    __ModuleLoader__: { load() {} },
    document: {
      querySelectorAll(selector) {
        expect(selector.includes("[role='dialog']"), "快捷键插件没有检测 DSH 弹层")
        if (
          openEscapeSurfaceSelector === undefined
          || !selector.split(",").map((part) => part.trim()).includes(openEscapeSurfaceSelector)
        ) return []
        return [{ hidden: false, getAttribute: () => null }]
      },
    },
    performance: { now: clock.now },
    setTimeout: clock.setTimeout,
    clearTimeout: clock.clearTimeout,
    addEventListener(type, listener, options) {
      let group = listeners.get(type)
      if (group === undefined) {
        group = new Set()
        listeners.set(type, group)
      }
      group.add(listener)
      listenerCapture.set(listener, usesCapture(options))
    },
    removeEventListener(type, listener, options) {
      if (listenerCapture.get(listener) !== usesCapture(options)) return
      listeners.get(type)?.delete(listener)
      listenerCapture.delete(listener)
    },
    queueMicrotask(callback) {
      microtasks.push(callback)
    },
    emit(type, event = {}, downstream) {
      const group = [...(listeners.get(type) ?? [])]
      for (const listener of group) {
        if (listenerCapture.get(listener) === true) listener(event)
        if (event.immediatePropagationStopped === true) break
      }
      if (event.cancelBubble !== true) downstream?.(event)
      if (event.cancelBubble !== true) {
        for (const listener of group) {
          if (listenerCapture.get(listener) !== true) listener(event)
          if (event.immediatePropagationStopped === true) break
        }
      }
      while (microtasks.length > 0) microtasks.shift()()
    },
    listenerCount(type) {
      return listeners.get(type)?.size ?? 0
    },
    capturedListenerCount(type) {
      return [...(listeners.get(type) ?? [])]
        .filter((listener) => listenerCapture.get(listener) === true)
        .length
    },
    setOpenEscapeSurface(value) {
      openEscapeSurfaceSelector = value === true ? "[role='dialog']" : value || undefined
    },
  }
}

const keyEvent = (key, fields = {}) => {
  const event = {
    key,
    defaultPrevented: false,
    cancelBubble: false,
    immediatePropagationStopped: false,
    altKey: false,
    ctrlKey: false,
    metaKey: false,
    shiftKey: false,
    repeat: false,
    isComposing: false,
    prevented: 0,
    stopped: 0,
    preventDefault() {
      this.defaultPrevented = true
      this.prevented += 1
    },
    stopPropagation() {
      this.cancelBubble = true
      this.stopped += 1
    },
    stopImmediatePropagation() {
      this.cancelBubble = true
      this.immediatePropagationStopped = true
      this.stopped += 1
    },
    ...fields,
  }
  return event
}

const createHarness = ({ running = true } = {}) => {
  const clock = createClock()
  const browser = createEventWindow(clock)
  globalThis.window = browser

  let current = "session-a"
  let snapshotShape = "public"
  const summaries = {
    "session-a": { id: "session-a", running },
    "session-b": { id: "session-b", running: true },
  }
  const listListeners = new Set()
  const sessionByID = new Map()
  let cancelImplementation = async () => ({ ok: true, value: { accepted: true } })
  let cancelCalls = 0
  for (const sessionID of Object.keys(summaries)) {
    sessionByID.set(sessionID, {
      cancel() {
        cancelCalls += 1
        return cancelImplementation(sessionID)
      },
    })
  }

  let overlayComponent
  let overlayRegistrations = 0
  let overlayDisposals = 0
  const effectCleanups = []
  let listUnsubscriptions = 0

  const jsx = (type, props) => ({ type, props })
  const react = {
    useSyncExternalStore(_subscribe, getSnapshot) {
      return getSnapshot()
    },
  }
  const require = (id) => {
    if (id === "react") return react
    if (id === "react/jsx-runtime") return { jsx }
    throw new Error(`测试未提供依赖：${id}`)
  }

  const ctx = {
    sessions: {
      list: {
        getSnapshot() {
          if (snapshotShape === "items") {
            return {
              current,
              items: Object.values(summaries).map((summary) => ({
                sessionId: summary.id,
                running: summary.running,
              })),
            }
          }
          if (snapshotShape === "by-id-only") return { current, byId: summaries }
          return { current, ids: Object.keys(summaries), byId: summaries }
        },
        subscribe(listener) {
          listListeners.add(listener)
          return () => {
            if (listListeners.delete(listener)) listUnsubscriptions += 1
          }
        },
      },
      binding(sessionID) {
        const session = sessionByID.get(sessionID)
        return session === undefined ? undefined : { sessionID, session }
      },
    },
    slots: {
      inject(name, install) {
        expect(name === "shell.overlay", "状态提示没有注册到 shell.overlay")
        const dispose = install()
        return () => dispose?.()
      },
      register(options, component) {
        expect(options.name === "shell.overlay", "状态提示注册到了错误 slot")
        expect(options.id === "dsd-pancake-shortcut-status", "状态提示缺少稳定 entry id")
        overlayRegistrations += 1
        overlayComponent = component
        let disposed = false
        return () => {
          if (disposed) return
          disposed = true
          overlayDisposals += 1
        }
      },
    },
    effect(callback) {
      effectCleanups.push(callback())
    },
  }

  const apply = () => {
    // 每次 factory 都重建模块闭包，以覆盖热重载或 Loader 重实例化时的真正全局单例约束。
    const plugin = definition.factory(require)
    expect(
      JSON.stringify(plugin.inject) === JSON.stringify(["sessions", "slots"]),
      "快捷键插件没有只注入 sessions 与 slots",
    )
    plugin.apply(ctx)
  }

  const emitKey = (key, fields, downstream) => {
    const event = keyEvent(key, fields)
    browser.emit("keydown", event, downstream)
    return event
  }

  const status = () => overlayComponent?.()
  const statusKind = () => status()?.props?.["data-dsd-pancake-shortcut-status"]
  const statusText = () => status()?.props?.children

  return {
    apply,
    browser,
    clock,
    emitKey,
    status,
    statusKind,
    statusText,
    cancelCalls: () => cancelCalls,
    setCancelImplementation(value) {
      cancelImplementation = value
    },
    setOpenEscapeSurface(value) {
      browser.setOpenEscapeSurface(value)
    },
    setCurrent(sessionID) {
      current = sessionID
      for (const listener of [...listListeners]) listener()
    },
    setRunning(sessionID, value) {
      summaries[sessionID].running = value
      for (const listener of [...listListeners]) listener()
    },
    useUnsupportedItemsShape() {
      snapshotShape = "items"
      for (const listener of [...listListeners]) listener()
    },
    useUnsupportedByIDOnlyShape() {
      snapshotShape = "by-id-only"
      for (const listener of [...listListeners]) listener()
    },
    emitPointerDown() {
      browser.emit("pointerdown", {})
    },
    emitBlur() {
      browser.emit("blur", {})
    },
    dispose(index = effectCleanups.length - 1) {
      effectCleanups[index]?.()
    },
    cleanupCount: () => effectCleanups.length,
    overlayRegistrations: () => overlayRegistrations,
    overlayDisposals: () => overlayDisposals,
    listUnsubscriptions: () => listUnsubscriptions,
  }
}

// 无效 Esc 不能布防；第一下有效 Esc 只提示，不消费事件。
{
  const harness = createHarness()
  harness.apply()
  for (const fields of [
    { defaultPrevented: true },
    { altKey: true },
    { ctrlKey: true },
    { metaKey: true },
    { shiftKey: true },
    { repeat: true },
    { isComposing: true },
    { keyCode: 229 },
    { which: 229 },
  ]) {
    harness.emitKey("Escape", fields)
    expect(harness.status() === null, "被消费、带修饰、repeat 或 IME Esc 错误触发布防")
  }

  const first = harness.emitKey("Escape")
  expect(first.prevented === 0 && first.stopped === 0, "第一次 Esc 不应被插件消费")
  expect(harness.statusKind() === "armed", "第一次 Esc 没有进入布防提示")
  expect(harness.statusText() === "再按一次 Esc 停止生成", "第一次 Esc 提示文案不正确")
  expect(harness.status()?.props?.role === "status", "快捷键提示缺少 role=status")
  expect(harness.status()?.props?.style?.pointerEvents === "none", "快捷键提示错误拦截了鼠标事件")
  expect(harness.status()?.props?.style?.bottom === "24px", "快捷键提示未固定在 Web UI 底部")

  // 非 Esc、pointerdown 与 blur 都应清理；每轮重新布防后验证。
  harness.emitKey("a")
  expect(harness.status() === null, "其它键没有清除双 Esc 布防")
  harness.emitKey("Escape")
  harness.emitPointerDown()
  expect(harness.status() === null, "pointerdown 没有清除双 Esc 布防")
  harness.emitKey("Escape")
  harness.emitBlur()
  expect(harness.status() === null, "blur 没有清除双 Esc 布防")
  harness.dispose()
}

// 无效 Esc 会打断既有布防，只有连续两次有效 Esc 才能取消。
{
  const harness = createHarness()
  harness.apply()
  for (const fields of [
    { defaultPrevented: true },
    { altKey: true },
    { ctrlKey: true },
    { metaKey: true },
    { shiftKey: true },
    { repeat: true },
    { isComposing: true },
    { keyCode: 229 },
    { which: 229 },
  ]) {
    harness.emitKey("Escape")
    expect(harness.statusKind() === "armed", "有效 Esc 没有进入布防")
    harness.emitKey("Escape", fields)
    expect(harness.status() === null, "无效 Esc 没有打断既有布防")
    harness.emitKey("Escape")
    await settle()
    expect(harness.cancelCalls() === 0, "无效 Esc 被夹在两次有效 Esc 之间仍触发了取消")
    harness.emitKey("a")
  }
  harness.dispose()
}

// capture 只用于先观察按键；DSH 弹层在后续传播中消费的 Esc 不能布防或取消。
{
  const harness = createHarness()
  harness.apply()
  harness.emitKey("Escape", {}, (event) => event.preventDefault())
  expect(harness.status() === null, "DSH 弹层已消费的第一次 Esc 错误进入布防")

  harness.emitKey("Escape")
  expect(harness.statusKind() === "armed", "未消费的第一次 Esc 没有进入布防")
  harness.emitKey("Escape", {}, (event) => event.preventDefault())
  await settle()
  expect(harness.cancelCalls() === 0, "DSH 弹层消费第二次 Esc 时插件错误停止了生成")
  expect(harness.status() === null, "DSH 弹层消费 Esc 后没有清除已有布防")
  harness.dispose()
}

// DSH 也可能只停止传播而不 preventDefault；原生 cancelBubble、stopPropagation
// 与 stopImmediatePropagation 都必须在传播完成后被视为已消费。
{
  const harness = createHarness()
  harness.apply()

  harness.emitKey("Escape", {}, (event) => event.stopPropagation())
  expect(harness.status() === null, "stopPropagation 消费的第一次 Esc 错误进入布防")

  harness.emitKey("Escape")
  expect(harness.statusKind() === "armed", "传播测试中的有效 Esc 没有进入布防")
  harness.emitKey("Escape", {}, (event) => event.stopImmediatePropagation())
  await settle()
  expect(harness.cancelCalls() === 0, "stopImmediatePropagation 消费第二次 Esc 时错误停止生成")
  expect(harness.status() === null, "停止传播消费 Esc 后没有清除已有布防")

  harness.emitKey("Escape", { cancelBubble: true })
  expect(harness.status() === null, "既有 cancelBubble 的 Esc 错误进入布防")
  harness.dispose()
}

// 一些 DSH 弹层关闭时不 preventDefault；可见弹层中的 Esc 也必须打断布防。
{
  const harness = createHarness()
  harness.apply()
  harness.setOpenEscapeSurface(true)
  harness.emitKey("Escape", {}, () => harness.setOpenEscapeSurface(false))
  expect(harness.status() === null, "可见 DSH 弹层中的第一次 Esc 错误进入布防")

  harness.emitKey("Escape")
  expect(harness.statusKind() === "armed", "关闭弹层后有效 Esc 没有进入布防")
  harness.setOpenEscapeSurface(true)
  harness.emitKey("Escape")
  await settle()
  expect(harness.cancelCalls() === 0, "可见 DSH 弹层中的第二次 Esc 错误停止了生成")
  expect(harness.status() === null, "可见 DSH 弹层中的 Esc 没有清除已有布防")

  harness.setOpenEscapeSurface(false)
  harness.emitKey("Escape")
  await settle()
  expect(harness.cancelCalls() === 0, "弹层 Esc 被错误保留为双击中的一次")
  harness.emitKey("Escape", {
    target: { matches: (selector) => selector === "input" },
  })
  expect(harness.status() === null, "输入控件中的 Esc 没有打断已有布防")

  harness.setOpenEscapeSurface("[role='tree']")
  harness.emitKey("Escape")
  expect(harness.statusKind() === "armed", "静态 role=tree 错误阻止了有效 Esc")
  harness.emitKey("a")
  harness.setOpenEscapeSurface("[aria-haspopup='tree'][aria-expanded='true']")
  harness.emitKey("Escape")
  expect(harness.status() === null, "展开的 subagent tree 中 Esc 错误进入布防")
  harness.dispose()
}

// 2000ms 闭区间内第二下必须恰好取消一次；判断在传播结束后完成，不劫持 DSH 事件。
{
  const harness = createHarness()
  let resolveCancel
  harness.setCancelImplementation(() => new Promise((resolve) => {
    resolveCancel = resolve
  }))
  harness.apply()
  harness.emitKey("Escape")
  harness.clock.advance(2_000)
  const second = harness.emitKey("Escape")
  await settle()
  expect(second.prevented === 0 && second.stopped === 0, "插件错误劫持了第二次有效 Esc")
  expect(harness.cancelCalls() === 1, "2000ms 边界没有恰好调用一次 SessionFace.cancel()")
  expect(harness.status() === null, "开始取消后仍残留布防提示")

  harness.emitKey("Escape")
  harness.emitKey("Escape")
  await settle()
  expect(harness.cancelCalls() === 1, "cancel in-flight 期间重复调用了 SessionFace.cancel()")
  resolveCancel({ ok: true, value: { accepted: true } })
  await settle()
  harness.emitKey("Escape")
  harness.emitKey("Escape")
  await settle()
  expect(
    harness.cancelCalls() === 1,
    "取消 RPC 已接受但 running 尚未收敛时重复调用了 SessionFace.cancel()",
  )
  harness.setRunning("session-a", false)
  harness.setRunning("session-a", true)
  harness.emitKey("Escape")
  harness.emitKey("Escape")
  await settle()
  expect(
    harness.cancelCalls() === 2,
    "会话停止后没有解除已接受取消的 session latch（会话闩锁）",
  )
  harness.dispose()
}

// 超过窗口只会重新布防，不会取消；timer 到期也必须清空提示。
{
  const harness = createHarness()
  harness.apply()
  harness.emitKey("Escape")
  harness.clock.advance(2_001)
  expect(harness.status() === null, "双 Esc 布防超时后提示没有消失")
  const afterTimeout = harness.emitKey("Escape")
  await settle()
  expect(afterTimeout.prevented === 0, "超时后的新第一下 Esc 被错误消费")
  expect(harness.cancelCalls() === 0, "超时后的 Esc 错误触发取消")
  expect(harness.statusKind() === "armed", "超时后的 Esc 没有开始新一轮布防")
  harness.dispose()
}

// 会话切换和 running=false 都必须清空；新会话的第一下不能继承旧会话布防。
{
  const harness = createHarness()
  harness.apply()
  harness.emitKey("Escape")
  harness.setCurrent("session-b")
  expect(harness.status() === null, "切换会话没有清除旧会话布防")
  const firstOnB = harness.emitKey("Escape")
  expect(firstOnB.prevented === 0 && harness.cancelCalls() === 0, "新会话继承了旧会话的第一次 Esc")
  harness.setRunning("session-b", false)
  expect(harness.status() === null, "会话停止运行后没有清除布防")
  harness.emitKey("Escape")
  expect(harness.status() === null, "非 running 会话错误进入双 Esc 布防")
  harness.dispose()
}

// RPC 业务失败和 Promise rejection 都应解锁、短暂提示且不自动重试。
for (const failure of [
  async () => ({ ok: false, error: { code: "cancel-failed", message: "failed" } }),
  async () => { throw new Error("transport failed") },
]) {
  const harness = createHarness()
  harness.setCancelImplementation(failure)
  harness.apply()
  harness.emitKey("Escape")
  harness.emitKey("Escape")
  await settle()
  expect(harness.cancelCalls() === 1, "取消失败后发生了自动重试或未调用 cancel")
  expect(harness.statusKind() === "failure", "取消失败后没有显示短暂失败提示")
  expect(harness.statusText() === "停止失败，请重试", "取消失败提示文案不正确")
  harness.clock.advance(2_000)
  expect(harness.status() === null, "取消失败提示没有按时消失")

  // 失败已解除 in-flight 锁，用户可以重新执行完整双击。
  harness.emitKey("Escape")
  harness.emitKey("Escape")
  await settle()
  expect(harness.cancelCalls() === 2, "取消失败后 in-flight 锁没有解除")
  harness.dispose()
}

// 第二次 apply 必须替换旧监听；dispose 需要清理监听、订阅、slot 与 timer。
{
  const harness = createHarness()
  harness.apply()
  harness.emitKey("Escape")
  expect(harness.clock.pending() === 1, "布防没有建立超时 timer")
  harness.apply()
  expect(harness.browser.listenerCount("keydown") === 1, "重复 apply 安装了多套 keydown 监听")
  expect(
    harness.browser.capturedListenerCount("keydown") === 1,
    "Escape 监听没有在 capture phase 注册，可能被 DSH composer 的冒泡处理抢先消费",
  )
  expect(harness.browser.listenerCount("pointerdown") === 1, "重复 apply 安装了多套 pointerdown 监听")
  expect(
    harness.browser.capturedListenerCount("pointerdown") === 1,
    "pointerdown 没有在 capture phase 清除双 Esc 布防",
  )
  expect(harness.browser.listenerCount("blur") === 1, "重复 apply 安装了多套 blur 监听")
  expect(harness.overlayRegistrations() === 2 && harness.overlayDisposals() === 1, "单例替换没有释放旧 overlay")
  expect(harness.listUnsubscriptions() === 1, "单例替换没有取消旧会话订阅")

  harness.emitKey("Escape")
  harness.dispose(1)
  expect(harness.browser.listenerCount("keydown") === 0, "dispose 后仍残留 keydown 监听")
  expect(harness.browser.listenerCount("pointerdown") === 0, "dispose 后仍残留 pointerdown 监听")
  expect(harness.browser.listenerCount("blur") === 0, "dispose 后仍残留 blur 监听")
  expect(harness.clock.pending() === 0, "dispose 后仍残留 timer")
  expect(harness.overlayDisposals() === 2, "dispose 后没有释放当前 overlay")
  expect(harness.listUnsubscriptions() === 2, "dispose 后没有取消当前会话订阅")
  harness.emitKey("Escape")
  expect(harness.status() === null, "dispose 后仍响应 Esc 或残留状态提示")

  // Cordis 可能再次调用上一代 cleanup；必须保持幂等。
  harness.dispose(0)
  expect(harness.overlayDisposals() === 2, "旧 cleanup 重入导致 overlay 重复释放")
}

// DSH 的公开 SessionListState 是 ids/byId/current；内部 items/sessionId 形状不得
// 形成可取消会话，否则未来 manager 投影变化会绕过正式 service contract。
{
  const harness = createHarness()
  harness.apply()
  harness.useUnsupportedItemsShape()
  harness.emitKey("Escape")
  harness.emitKey("Escape")
  await settle()
  expect(harness.cancelCalls() === 0, "快捷键插件错误读取了未公开的 items/sessionId session 投影")
  expect(harness.status() === null, "unsupported session shape 错误进入双 Esc 布防")

  harness.useUnsupportedByIDOnlyShape()
  harness.emitKey("Escape")
  harness.emitKey("Escape")
  await settle()
  expect(harness.cancelCalls() === 0, "快捷键插件错误接受了缺少 ids 的不完整 SessionListState")
  expect(harness.status() === null, "不完整 SessionListState 错误进入双 Esc 布防")
  harness.dispose()
}

console.log("PASS: App 私有双 Esc 插件的弹层隔离、连续有效键过滤、2000ms 边界、取消去重、失败恢复、状态清理与单例生命周期")
