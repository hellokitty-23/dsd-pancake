import { pathToFileURL } from "node:url"

const expect = (condition, message) => {
  if (!condition) throw new Error(message)
}

const settle = () => new Promise((resolve) => setImmediate(resolve))

const clientURL = pathToFileURL(
  new URL("../Plugins/dsd-pancake-terminal/lib/client.js", import.meta.url).pathname,
)

let definition
const sent = []
const eventListeners = new Map()
let effectCleanup
let stateValue
let effectInstalled = false
const react = {
  useState(initial) {
    if (stateValue === undefined) {
      stateValue = typeof initial === "function" ? initial() : initial
    }
    return [stateValue, (next) => {
      stateValue = typeof next === "function" ? next(stateValue) : next
    }]
  },
  useEffect(effect) {
    if (effectInstalled) return
    effectInstalled = true
    effectCleanup = effect()
  },
}
const jsx = (type, props) => ({ type, props })

globalThis.window = {
  __ModuleLoader__: {
    load(value) {
      definition = value
    },
  },
  webkit: {
    messageHandlers: {
      dsdPancakeTerminal: {
        async postMessage(payload) {
          sent.push(payload)
          if (payload.action === "capabilities") {
            return { version: 1, supported: true, open: false, workspaceAccepted: true }
          }
          if (payload.action === "syncWorkspace" || payload.action === "clearWorkspace") {
            return { version: 1, supported: true, open: false, workspaceAccepted: true }
          }
          throw new Error(`unexpected action ${payload.action}`)
        },
      },
    },
  },
  __dshDesktopTerminalDockLayout: {
    version: 1,
    open: true,
    reservedHeight: 285,
  },
  addEventListener(name, callback) {
    const callbacks = eventListeners.get(name) ?? []
    callbacks.push(callback)
    eventListeners.set(name, callbacks)
  },
  removeEventListener(name, callback) {
    eventListeners.set(name, (eventListeners.get(name) ?? []).filter((item) => item !== callback))
  },
}

await import(`${clientURL.href}?native=${Date.now()}`)
expect(definition !== undefined, "终端插件没有注册 DSH client module")

const plugin = definition.factory((name) => {
  if (name === "react") return react
  if (name === "react/jsx-runtime") return { jsx }
  throw new Error(`终端插件请求了未知依赖：${name}`)
})
let pluginCleanup
let injectedSlot
let registration
let snapshot = {
  current: "session-42",
  // DSH 0.1.1-rc.2 的公开 sessions.list snapshot：current 配合 items，
  // 每项使用 sessionId。此形态必须能令原生终端入口获得当前工作区。
  items: [
    { sessionId: "session-42", cwd: "/tmp/dsd-pancake-workspace" },
  ],
}
let sessionReads = 0
let subscriber
plugin.apply({
  sessions: {
    list: {
      getSnapshot() {
        sessionReads += 1
        return snapshot
      },
      subscribe(callback) {
        subscriber = callback
        return () => {
          subscriber = undefined
        }
      },
    },
  },
  effect(callback) {
    pluginCleanup = callback()
  },
  slots: {
    inject(name, callback) {
      injectedSlot = name
      return callback()
    },
    register(config, component) {
      registration = { config, component }
      return () => {}
    },
  },
})
await settle()

expect(sent[0]?.action === "capabilities", "终端插件没有先协商原生能力")
const sync = sent.find((payload) => payload.action === "syncWorkspace")
expect(sync !== undefined, "终端插件没有通过正式 session service 同步 workspace")
expect(
  JSON.stringify(sync) === JSON.stringify({
    version: 1,
    action: "syncWorkspace",
    sessionID: "session-42",
    workspacePath: "/tmp/dsd-pancake-workspace",
  }),
  "终端 workspace 同步携带了多余字段或错误字段",
)
expect(sessionReads > 0 && subscriber !== undefined, "工作区同步没有订阅正式 session service")
expect(injectedSlot === "conversation.composer.dock", "终端插件没有使用 DSH 正式 composer footer slot")
expect(
  JSON.stringify(registration?.config) === JSON.stringify({
    name: "conversation.composer.dock",
    id: "dsd-pancake-terminal-reservation",
    order: 10_000,
  }),
  "终端布局插件注册了错误的 slot 或非预期元数据",
)
const visibleReservation = registration?.component({})
expect(
  visibleReservation?.props?.["aria-hidden"] === true
    && visibleReservation.props?.["data-dsd-pancake-terminal-reservation"] === ""
    && visibleReservation.props?.style?.height === "285px"
    && visibleReservation.props?.style?.pointerEvents === "none",
  "终端布局占位没有以不可交互的固定高度渲染",
)
const layoutListeners = eventListeners.get("dsd-pancake-terminal-layout") ?? []
expect(layoutListeners.length === 1, "终端布局占位没有订阅原生单向布局事件")
layoutListeners[0]({ detail: { version: 1, open: false, reservedHeight: 0 } })
expect(registration?.component({}) === null, "收起原生 dock 后终端布局占位没有清除")

snapshot = {
  current: "session-99",
  items: [
    { sessionId: "session-42", cwd: "/tmp/dsd-pancake-workspace" },
    { sessionId: "session-99", cwd: "/tmp/dsd-pancake-new-workspace" },
  ],
}
subscriber?.()
await settle()
const switched = sent.filter((payload) => payload.action === "syncWorkspace").at(-1)
expect(
  JSON.stringify(switched) === JSON.stringify({
    version: 1,
    action: "syncWorkspace",
    sessionID: "session-99",
    workspacePath: "/tmp/dsd-pancake-new-workspace",
  }),
  "切换当前 session 时没有只同步新的 current workspace",
)

snapshot = { current: undefined, items: [{ sessionId: "session-42" }] }
subscriber?.()
await settle()
const clear = sent.find((payload) => payload.action === "clearWorkspace")
expect(
  JSON.stringify(clear) === JSON.stringify({ version: 1, action: "clearWorkspace" }),
  "没有 workspace 时没有精确撤销原生终端入口",
)

// 对旧版公开快照仍保持只读兼容：用 byId 索引时也必须精确同步 current，而不能
// 因 DSH 版本差异让壳层按钮永久保持禁用。
snapshot = {
  current: "legacy-session",
  ids: ["legacy-session"],
  byId: {
    "legacy-session": { id: "legacy-session", cwd: "/tmp/dsd-pancake-legacy-workspace" },
  },
}
subscriber?.()
await settle()
const legacySync = sent.filter((payload) => payload.action === "syncWorkspace").at(-1)
expect(
  JSON.stringify(legacySync) === JSON.stringify({
    version: 1,
    action: "syncWorkspace",
    sessionID: "legacy-session",
    workspacePath: "/tmp/dsd-pancake-legacy-workspace",
  }),
  "旧版 byId session snapshot 没有兼容同步 current workspace",
)
expect(!sent.some((payload) => ["show", "hide", "toggle"].includes(payload.action)), "DSH 插件越权请求了原生面板显示状态")
pluginCleanup?.()
effectCleanup?.()

let browserDefinition
let browserSessionReads = 0
globalThis.window = {
  __ModuleLoader__: {
    load(value) {
      browserDefinition = value
    },
  },
}
await import(`${clientURL.href}?browser=${Date.now()}`)
const browserPlugin = browserDefinition.factory((name) => {
  if (name === "react" || name === "react/jsx-runtime") {
    throw new Error("普通浏览器不应加载终端 UI 依赖")
  }
  throw new Error(`普通浏览器不应请求依赖：${name}`)
})
let browserEffectCalled = false
let browserSlotTouched = false
browserPlugin.apply({
  sessions: {
    list: {
      getSnapshot() {
        browserSessionReads += 1
        throw new Error("普通浏览器不应读取 session/workspace")
      },
      subscribe() {
        throw new Error("普通浏览器不应订阅 session/workspace")
      },
    },
  },
  effect() {
    browserEffectCalled = true
  },
  slots: {
    inject() {
      browserSlotTouched = true
      throw new Error("普通浏览器不应注册终端布局 slot")
    },
    register() {
      browserSlotTouched = true
      throw new Error("普通浏览器不应注册终端布局 slot")
    },
  },
})
await settle()
expect(
  !browserEffectCalled && browserSessionReads === 0 && !browserSlotTouched,
  "没有原生 bridge 时终端插件没有安全 no-op",
)

console.log("PASS: App 私有终端插件只同步 current workspace，并用正式 composer footer slot 为原生 dock 留白")
