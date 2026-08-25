import { pathToFileURL } from "node:url"

let definition
const sent = []

globalThis.window = {
  __ModuleLoader__: {
    load(value) {
      definition = value
    },
  },
  webkit: {
    messageHandlers: {
      dsdPancakeNotifications: {
        async postMessage(payload) {
          sent.push(payload)
          if (payload.action === "capabilities") {
            return {
              version: 1,
              supported: true,
              authorization: "notDetermined",
            }
          }
          if (payload.action === "requestAuthorization") {
            return {
              version: 1,
              supported: true,
              authorization: "authorized",
            }
          }
          return {
            version: 1,
            supported: true,
            authorization: "authorized",
            accepted: true,
          }
        },
      },
    },
  },
}

const clientURL = pathToFileURL(
  new URL("../Plugins/dsd-pancake-notifications/lib/client.js", import.meta.url).pathname,
)
await import(`${clientURL.href}?verify=${Date.now()}`)

if (definition === undefined) {
  throw new Error("提醒插件没有注册 DSH client module")
}

const plugin = definition.factory()
let snapshot = {
  ids: ["reply", "goal", "subagent"],
  byId: {
    reply: { id: "reply", running: true, updatedAt: 1 },
    goal: {
      id: "goal",
      running: true,
      updatedAt: 1,
      projectionValues: {
        goal: {
          goal: { id: "goal-1", revision: 1, phase: "active" },
        },
      },
    },
    subagent: { id: "subagent", origin: "subagent", running: true, updatedAt: 1 },
  },
}

let listener
let cleanup
let unsubscribed = false
plugin.apply({
  sessions: {
    list: {
      getSnapshot: () => snapshot,
      subscribe(callback) {
        listener = callback
        return () => {
          unsubscribed = true
        }
      },
    },
  },
  effect(callback) {
    cleanup = callback()
  },
})

const settle = () => new Promise((resolve) => setImmediate(resolve))
await settle()

const expect = (condition, message) => {
  if (!condition) throw new Error(message)
}

expect(sent.length === 2, "首次观察只能协商原生桥与通知授权，不应补发历史通知")
expect(sent[0]?.action === "capabilities", "没有先协商原生桥能力")
expect(sent[1]?.action === "requestAuthorization", "未确定授权时没有请求系统授权")

snapshot = {
  ...snapshot,
  byId: {
    ...snapshot.byId,
    reply: { ...snapshot.byId.reply, running: false, updatedAt: 2 },
    subagent: { ...snapshot.byId.subagent, running: false, updatedAt: 2 },
  },
}
listener()
await settle()

const reply = sent.find((payload) => payload.action === "notify" && payload.kind === "reply")
expect(reply !== undefined, "顶层普通会话完成时没有发送 reply 提醒")
expect(/^dsh-[a-z0-9]+$/.test(reply.eventID), "reply 提醒携带了非不透明事件 ID")
expect(
  sent.filter((payload) => payload.action === "notify" && payload.kind === "reply").length === 1,
  "subagent 或重复状态错误触发了 reply 提醒",
)

snapshot = {
  ...snapshot,
  byId: {
    ...snapshot.byId,
    goal: {
      ...snapshot.byId.goal,
      running: false,
      updatedAt: 3,
      projectionValues: {
        goal: {
          goal: { id: "goal-1", revision: 2, phase: "blocked" },
        },
      },
    },
  },
}
listener()
await settle()

const blockedGoal = sent.find((payload) => payload.action === "notify" && payload.kind === "goal-blocked")
expect(blockedGoal !== undefined, "goal 进入 blocked 时没有发送受阻提醒")
expect(/^dsh-[a-z0-9]+$/.test(blockedGoal.eventID), "受阻提醒携带了非不透明事件 ID")

snapshot = {
  ...snapshot,
  byId: {
    ...snapshot.byId,
    goal: {
      ...snapshot.byId.goal,
      updatedAt: 4,
      projectionValues: {
        goal: {
          goal: { id: "goal-1", revision: 3, phase: "complete" },
        },
      },
    },
  },
}
listener()
await settle()

const completedGoal = sent.find((payload) => payload.action === "notify" && payload.kind === "goal-complete")
expect(completedGoal !== undefined, "goal 从 blocked 进入 complete 时没有发送完成提醒")
expect(/^dsh-[a-z0-9]+$/.test(completedGoal.eventID), "完成提醒携带了非不透明事件 ID")
expect(
  sent.filter((payload) => payload.action === "notify").length === 3,
  "goal 状态变化错误叠加了普通 reply 提醒或重复提醒",
)

cleanup()
expect(unsubscribed, "插件 dispose 后没有取消会话订阅")

let browserDefinition
let browserSnapshotReads = 0
globalThis.window = {
  __ModuleLoader__: {
    load(value) {
      browserDefinition = value
    },
  },
}
await import(`${clientURL.href}?browser=${Date.now()}`)
const browserPlugin = browserDefinition.factory()
browserPlugin.apply({
  sessions: {
    list: {
      getSnapshot() {
        browserSnapshotReads += 1
        return snapshot
      },
      subscribe() {
        throw new Error("普通浏览器不应订阅会话")
      },
    },
  },
  effect(callback) {
    cleanup = callback()
  },
})
await settle()
expect(browserSnapshotReads === 0, "普通浏览器错误读取了会话摘要")
cleanup()

console.log("PASS: App 私有提醒插件的基线、授权、reply、goal、subagent 与普通浏览器 no-op 过滤")
