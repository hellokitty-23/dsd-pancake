import { readFile } from "node:fs/promises"
import { pathToFileURL } from "node:url"

import {
  OfficialChatView,
  OfficialHeader,
  OfficialToolCallTree,
  atomicEntry,
  cordisDeepSelect,
  cordisDetailEntry,
  cordisInject,
  cordisRunEntry,
  cordisStore,
  findElement,
  findElements,
  jsx,
  materialize,
  officialHeaderEntry,
  officialParentInject,
  officialToolviewEntries,
  officialViewEntry,
  registeredPlugin,
  textOf,
  useOperationFoldingDefinition,
} from "./operation-folding-harness.mjs"
import {
  PrototypeChatNodeStore,
  assistantNode,
  ownerFor,
  passiveNode,
  running,
  settled,
  snapshotFor,
  toolNode,
} from "./operation-folding-fixtures.mjs"

const expect = (condition, message) => {
  if (!condition) throw new Error(message)
}

const clientPath = new URL("../Plugins/dsd-pancake-operation-folding/lib/client.js", import.meta.url)
const clientURL = pathToFileURL(clientPath.pathname)

let definition
globalThis.window = {
  __ModuleLoader__: {
    load(value) {
      definition = value
    },
  },
}

await import(`${clientURL.href}?operation-folding=${String(Date.now())}`)
expect(definition !== undefined, "操作折叠插件没有注册 DSH client module")
expect(
  definition.id === "@dsd-pancake/dsh-desktop-operation-folding",
  "操作折叠插件注册了错误的 client module id",
)
useOperationFoldingDefinition(definition)

const first = registeredPlugin()
expect(first.plugin.inject?.[0] === "slots", "操作折叠插件没有声明 slots 注入")
expect(!first.slotAPIKeys.includes("isLive"), "verifier 不应伪造未公开的 slots.isLive")
expect(
  JSON.stringify(first.injectedSlots.slice(0, 4))
    === JSON.stringify([
      "conversation.view",
      "conversation.session.header",
      "conversation.chat.node",
      "tool.call.toolview",
    ]),
  "操作折叠插件没有嵌套监听正式 view、header、chat node 与 atomic child slot",
)
expect(first.parent !== undefined, "兼容的正式 slot 存在时，操作折叠插件没有注册")

// 正式 SlotCore 在 register 后才于 microtask flush 时读取 listeners；插件的
// source subscriptions 虽然晚于首轮 root shadow 注册，仍会收到一次合并通知。
const firstRegistrationCount = first.registrations.length
await first.flushMutations()
expect(
  first.notificationCallbackCount("conversation.view") === 1
    && first.notificationCallbackCount("conversation.session.header") === 1,
  "首轮 register 后同 turn 建立的 root subscriptions 没有各收到一次合并通知",
)
expect(
  first.registrations.length === firstRegistrationCount,
  "首轮自身 root shadow 通知绕过 candidate fingerprint 触发了自激重建",
)

const lateSubscriberGate = registeredPlugin()
await lateSubscriberGate.flushMutations()
let lateSubscriberCalls = 0
lateSubscriberGate.registerForTest({
  name: "conversation.session.header.actions",
  id: "late-subscriber-probe",
  order: 0,
  priority: 0,
}, () => null)
lateSubscriberGate.subscribeForTest(
  "conversation.session.header.actions",
  () => { lateSubscriberCalls += 1 },
)
await lateSubscriberGate.flushMutations()
expect(
  lateSubscriberCalls === 1,
  "register 先发生、同 turn 后 subscribe 时没有收到一次合并通知",
)

const listCellRules = registeredPlugin()
listCellRules.registerForTest({
  name: "conversation.view",
  id: "chat",
  order: 20,
  priority: -2,
}, () => null)
const lowerPriorityChat = listCellRules.rawEntriesForTest("conversation.view").find((entry) => (
  entry.config?.id === "chat" && entry.config?.priority === -2
))
let duplicateListCellRejected = false
try {
  listCellRules.registerForTest({
    name: "conversation.view",
    id: "chat",
    priority: -2,
  }, () => null)
} catch {
  duplicateListCellRejected = true
}
expect(
  duplicateListCellRejected,
  "list cell 应允许同 id 不同 priority，但拒绝同 id + 同 priority",
)
listCellRules.registerForTest({
  name: "conversation.view",
  id: "ordered-sibling",
  order: -10,
  priority: -2,
}, () => null)
const orderedSibling = listCellRules.rawEntriesForTest("conversation.view").find((entry) => (
  entry.config?.id === "ordered-sibling"
))
const rawListEntries = listCellRules.rawEntriesForTest("conversation.view")
expect(
  rawListEntries.indexOf(orderedSibling) < rawListEntries.indexOf(lowerPriorityChat),
  "list raw ledger 没有在同 priority 下继续按 order 排序",
)
expect(
  listCellRules.winningEntriesForTest("conversation.view")[0] === orderedSibling
    && listCellRules.winningEntriesForTest("conversation.view")[1] === lowerPriorityChat,
  "list entriesOfSlot 没有沿 priority/order ledger 顺序选出每个 id 的 winner",
)
const viewShadow = first.activeRecords("conversation.view")[0]
const headerShadow = first.activeRecords("conversation.session.header")[0]
expect(viewShadow?.config.id === "chat", "操作折叠插件没有 shadow 官方 chat view cell")
expect(viewShadow.config.priority === -1, "chat view shadow 没有使用 source priority - 1")
expect(headerShadow?.config.priority === -1, "header shadow 没有使用 source priority - 1")
expect(first.parent.config.inject === officialParentInject, "父 shadow 没有复用官方 inject")
expect(first.parent.config.locale === "conversation", "父 shadow 没有复用官方 locale")
expect(
  Object.keys(first.parent.config.children ?? {}).every((name) => name.startsWith("dsd-pancake.operation.alias")),
  "tool-call mirror 没有声明 App 私有 child alias",
)
expect(
  first.parent.config.children?.["tool.call.toolview"] === undefined,
  "tool-call mirror 不应重复声明官方 tool.call.toolview",
)

const privateNames = [...first.declarations.keys()].filter((name) => name.startsWith("dsd-pancake.operation"))
expect(new Set(privateNames).size === privateNames.length, "递归 private alias 名称发生冲突")
expect(
  first.registrations.every((record) => (
    record.config.children === undefined
    || Object.keys(record.config.children).every((name) => name.startsWith("dsd-pancake.operation"))
  )),
  "private mirror 重复声明了官方 child slot 名称",
)
const officialToolKeys = new Set(officialToolviewEntries.map((entry) => entry.options.key))
const topMirrors = first.registrations.filter((entry) => (
  !entry.disposed
  && entry.config.name.startsWith("dsd-pancake.operation.alias")
  && officialToolKeys.has(entry.config.key)
))
expect(topMirrors.length === officialToolviewEntries.length, "没有镜像全部 winning atomic tool views")
const mirroredCordis = topMirrors.find((entry) => entry.config.key === "cordis_run")
expect(mirroredCordis !== undefined, "cordis_run 没有进入 private top alias")
expect(mirroredCordis.config.inject === cordisInject, "cordis_run 镜像丢失 inject")
expect(mirroredCordis.config.locale === "cordis", "cordis_run 镜像丢失 locale")
expect(mirroredCordis.config.store === cordisStore, "cordis_run 镜像丢失 store")
expect(
  Object.keys(mirroredCordis.config.children).every((name) => name !== "cordis.run.detail"),
  "cordis_run 镜像仍直接声明官方 child slot",
)
expect(
  first.registrations.some((entry) => entry.config.select === cordisDeepSelect),
  "递归 chain descendant 镜像丢失 select",
)

const sharedRead = settled("call-read", "read", { path: "README.md" }, 2)
const writeRoot = running(
  "call-write",
  "write",
  { path: ".ccswitchgpt/runtime/b0-a-diag.cjs" },
  10,
  [sharedRead],
)
const bashRoot = settled(
  "call-bash",
  "bash",
  { command: "npm test" },
  12,
  false,
  [sharedRead, settled("call-grep", "grep", { pattern: "failure" }, 11, true)],
)
const duplicateBashRoot = settled("call-bash", "bash", { command: "npm test" }, 13)
const unknownRoot = running("call-question", "ask_user_question", { question: "继续吗？" }, 14)
const writeNode = toolNode("node-write", 7, writeRoot, 1)
const bashNode = toolNode("node-bash", 7, bashRoot, 2)
const duplicateNode = toolNode("node-bash-duplicate", 7, duplicateBashRoot, 3)
const unknownNode = toolNode("node-question", 7, unknownRoot, 4)
const hiddenNode = {
  ...toolNode("node-hidden", 7, settled("call-hidden", "write", { path: "hidden.txt" }, 15), 5),
  visibility: "hidden",
}
let snapshot = snapshotFor([[7, [writeNode, bashNode, duplicateNode, unknownNode, hiddenNode]]])

let chatView = first.renderView(ownerFor(writeNode, snapshot, "session-a"))
const collapsedOfficialView = findElement(
  chatView,
  (element) => element.props?.["data-official-order"] !== undefined,
)
expect(
  collapsedOfficialView?.props?.["data-official-order"] === "node-write,node-question,node-hidden",
  "折叠态没有在 ChatView 前投影 order，非 anchor flowItem 仍会占用 column gap",
)
expect(
  collapsedOfficialView.props["data-order-reference"] !== snapshot.chat.order,
  "折叠态仍把原始 order 引用交给 ChatView",
)
const renderedHeader = first.renderHeader({
  views: {
    list: () => [
      { id: "chat", label: "shadow winner" },
      { id: "chat", label: "native raw" },
    ],
    subscribe: () => () => {},
    version: () => 0,
  },
})
const officialHeader = findElement(renderedHeader, (element) => element.type === "official-header")
expect(officialHeader?.props?.["data-header-tabs"] === "chat", "header 没有去除 shadow 导致的重复 chat tab")
expect(
  officialHeader.props["data-header-labels"] === "shadow winner",
  "header 去重采用了 raw first，而不是 conversation.view 的真实 winner",
)

let anchor = first.renderParent(ownerFor(writeNode, snapshot, "session-a"))
let summary = findElement(anchor, (element) => element.props?.["data-dsd-pancake-operation-summary"] === "")
const current = findElement(anchor, (element) => element.props?.["data-dsd-pancake-current-operation"] === "")
expect(anchor?.props?.["data-dsd-pancake-operation-group"] === "", "首个可折叠工具没有成为摘要 anchor")
expect(textOf(current) === "✎ 当前：Write · .ccswitchgpt/runtime/b0-a-diag.cjs", "当前操作没有置顶")
expect(summary?.type === "button" && summary.props.type === "button", "摘要整行不是原生 button")
expect(summary.props["aria-expanded"] === false, "新会话没有默认折叠")
expect(summary.props["aria-label"] === "展开当前会话已折叠的 4 项操作", "折叠摘要缺少可访问名称")
expect(
  textOf(summary) === "▸ 已折叠 4 项操作 · Read 1 · Bash 1 · Grep 1 · Write 1 · 失败 1",
  "摘要统计、callId 去重或失败计数不正确",
)
expect(
  findElement(summary, (element) => textOf(element) === "失败 1")?.props?.style?.color
    === "var(--dsw-alias-state-error-primary)",
  "失败数量大于零时没有使用错误色",
)
expect(first.renderParent(ownerFor(bashNode, snapshot, "session-a")) !== null, "非 anchor renderer 不应靠返回 null 隐藏")
expect(first.renderParent(ownerFor(duplicateNode, snapshot, "session-a")) !== null, "重复 callId renderer 不应靠返回 null 隐藏")

const rawUnknown = first.renderParentRaw(ownerFor(unknownNode, snapshot, "session-a"))
expect(rawUnknown?.type === OfficialToolCallTree, "non-foldable 路径没有 JSX 委托官方父 ToolCallTree")
const unknownCard = materialize(rawUnknown)
expect(
  findElement(unknownCard, (element) => element.props?.["data-official-tool"] === "ask_user_question")
    !== undefined,
  "ask_user_question 没有经过 private alias dispatch 到原生 renderer",
)
expect(
  findElement(unknownCard, (element) => element.props?.["data-official-parent"] === "") !== undefined,
  "non-foldable 路径丢失官方父布局",
)

const cordisRoot = running("call-cordis", "cordis_run", { target: "sample" }, 18)
const cordisNode = toolNode("node-cordis", 10, cordisRoot, 1)
const cordisCard = first.renderParent(ownerFor(
  cordisNode,
  snapshotFor([[10, [cordisNode]]]),
  "session-a",
))
expect(
  findElement(cordisCard, (element) => element.props?.["data-official-tool"] === "cordis_run")
    ?.props?.["data-injected-value"] === "native-inject",
  "cordis_run 没有保留原生 inject",
)
expect(
  findElement(cordisCard, (element) => element.props?.["data-cordis-detail"] === "call-cordis")
    !== undefined,
  "cordis_run 没有通过第一层 private child alias",
)
expect(
  findElement(cordisCard, (element) => element.props?.["data-cordis-deep"] === "call-cordis")
    !== undefined,
  "递归 Cordis chain child 没有通过第二层 private alias",
)
expect(
  first.slotDispatches.every((dispatch) => (
    dispatch.name === "conversation.view"
    || dispatch.name === "conversation.session.header"
    || dispatch.name.startsWith("dsd-pancake.operation")
  )),
  "wrapper 把 source 的官方 child name 直接交给了 SlotCore",
)
expect(
  first.jsxDelegations.some((delegation) => (
    delegation.record === mirroredCordis && delegation.delegatedType === cordisRunEntry.component
  )),
  "mirror wrapper 没有用 JSX/createElement 委托 source component",
)

summary.props.onClick()
chatView = first.renderView(ownerFor(writeNode, snapshot, "session-a"))
const expandedOfficialView = findElement(
  chatView,
  (element) => element.props?.["data-official-order"] !== undefined,
)
expect(
  expandedOfficialView?.props?.["data-official-order"]
    === "node-write,node-bash,node-bash-duplicate,node-question,node-hidden",
  "展开态没有恢复完整 order 与原始顺序",
)
expect(
  expandedOfficialView.props["data-order-reference"] === snapshot.chat.order,
  "展开态没有把原始 order 引用交还原生 ChatView",
)
const rawExpanded = first.renderParentRaw(ownerFor(writeNode, snapshot, "session-a", {
  selectedCallId: "call-write",
}))
expect(
  findElement(rawExpanded, (element) => element.type === OfficialToolCallTree) !== undefined,
  "expanded anchor 没有 JSX 委托官方父 ToolCallTree",
)
anchor = materialize(rawExpanded)
summary = findElement(anchor, (element) => element.props?.["data-dsd-pancake-operation-summary"] === "")
expect(summary.props["aria-expanded"] === true, "点击摘要后没有展开")
expect(
  findElement(anchor, (element) => element.props?.["data-chat-call-id"] === "call-write")
    ?.props?.["data-selected"] === true,
  "展开路径没有保留官方 selected call 状态",
)
expect(first.renderParent(ownerFor(bashNode, snapshot, "session-a")) !== null, "展开后后续工具没有恢复")

const laterRead = running("call-later", "read", { path: "Sources/App.swift" }, 30)
const laterNode = toolNode("node-later", 7, laterRead, 5)
snapshot = snapshotFor([[7, [writeNode, bashNode, duplicateNode, unknownNode, laterNode]]])
expect(first.renderParent(ownerFor(laterNode, snapshot, "session-a")) !== null, "展开后新操作没有直接展开")
anchor = first.renderParent(ownerFor(writeNode, snapshot, "session-a"))
expect(
  textOf(findElement(anchor, (element) => element.props?.["data-dsd-pancake-current-operation"] === ""))
    === "✎ 当前：Read · Sources/App.swift",
  "后续运行操作没有更新置顶行",
)
expect(
  findElement(
    first.renderParent(ownerFor(writeNode, snapshot, "session-b")),
    (element) => element.props?.["data-dsd-pancake-operation-summary"] === "",
  ).props["aria-expanded"] === false,
  "会话 A 的展开状态污染了会话 B",
)
summary = findElement(
  first.renderParent(ownerFor(writeNode, snapshot, "session-a")),
  (element) => element.props?.["data-dsd-pancake-operation-summary"] === "",
)
summary.props.onClick()
chatView = first.renderView(ownerFor(writeNode, snapshot, "session-a"))
expect(
  findElement(chatView, (element) => element.props?.["data-official-order"] !== undefined)
    ?.props?.["data-official-order"] === "node-write,node-question",
  "再次点击后没有恢复 order 投影折叠",
)

const thinkPlugin = registeredPlugin()
const thinkOld = assistantNode("think-old", 40, [
  { kind: "reasoning", text: "旧推理开头\n旧推理结尾" },
], "settled", 0)
const thinkToolA = toolNode(
  "think-tool-a",
  40,
  running("think-call-a", "read", { path: "Sources/A.swift" }, 1),
  1,
)
const thinkMixed = assistantNode("think-mixed", 40, [
  { kind: "text", text: "保留正文" },
  { kind: "reasoning", text: "同一步早期 reasoning" },
  { kind: "reasoning", text: "流式推理开头\n  最新有效内容  \n" },
  { kind: "image", attachment: { id: "image-a" } },
  { kind: "other", block: { future: true } },
  { kind: "tool-call", callId: "inline-tool", name: "read", argsRaw: "{}" },
], "running", 2)
const thinkContext = passiveNode("think-context", "context", 40, 3)
const thinkToolB = toolNode(
  "think-tool-b",
  40,
  settled("think-call-b", "bash", { command: "swift test" }, 4),
  4,
)
const thinkEmptyTail = assistantNode("think-empty-tail", 40, [
  { kind: "reasoning", text: " \n\t " },
], "running", 5)
const thinkRetry = passiveNode("think-retry", "model-retry", 40, 6)
const thinkError = passiveNode("think-error", "turn-error", 40, 7)
const thinkHidden = {
  ...assistantNode("think-hidden", 40, [
    { kind: "reasoning", text: "隐藏节点不应成为最新" },
  ], "settled", 8),
  visibility: "hidden",
}
let thinkSnapshot = snapshotFor([[40, [
  thinkOld,
  thinkToolA,
  thinkMixed,
  thinkContext,
  thinkToolB,
  thinkEmptyTail,
  thinkRetry,
  thinkError,
  thinkHidden,
]]])
const rawThinkOrder = thinkSnapshot.chat.order
const rawThinkNodes = thinkSnapshot.chat.nodes
const rawMixedBlocks = thinkMixed.data.blocks

let thinkView = thinkPlugin.renderView(ownerFor(thinkOld, thinkSnapshot, "think-session"))
let thinkOfficialView = findElement(
  thinkView,
  (element) => element.props?.["data-official-order"] !== undefined,
)
expect(
  thinkOfficialView?.props?.["data-official-order"]
    === "think-tool-a,think-mixed,think-context,think-retry,think-error,think-hidden",
  "Think 与工具折叠没有共同移除旧 reasoning、空流式节点和第二个折叠工具",
)
expect(
  thinkSnapshot.chat.order === rawThinkOrder
    && thinkSnapshot.chat.nodes === rawThinkNodes
    && thinkMixed.data.blocks === rawMixedBlocks
    && thinkMixed.data.blocks.some((block) => block.kind === "reasoning"),
  "Think 投影修改了原始 snapshot、node store 或 blocks",
)

const prototypeThinkPlugin = registeredPlugin()
const prototypeStore = new PrototypeChatNodeStore(rawThinkNodes.values())
const prototypeSnapshot = {
  ...thinkSnapshot,
  chat: {
    ...thinkSnapshot.chat,
    nodes: prototypeStore,
  },
}
expect(
  !Object.hasOwn(prototypeStore, "get") && !Object.hasOwn(prototypeStore, "values"),
  "原型 node store 夹具错误地把 get/values 建成了实例字段",
)
let prototypeThinkView = prototypeThinkPlugin.renderView(ownerFor(
  thinkOld,
  prototypeSnapshot,
  "prototype-think-session",
))
let prototypeOfficialView = findElement(
  prototypeThinkView,
  (element) => element.props?.["data-official-order"] !== undefined,
)
expect(
  prototypeOfficialView?.props?.["data-official-order"]
    === "think-tool-a,think-mixed,think-context,think-retry,think-error,think-hidden"
    && prototypeOfficialView.props["data-value-block-kinds"].includes(
      "think-mixed:text+image+other+tool-call",
    )
    && !prototypeOfficialView.props["data-value-block-kinds"].includes(
      "think-mixed:text+reasoning",
    ),
  "只读 Think overlay 没有保留原型 node store 的 get/values 合约或正确投影 values()",
)
expect(
  prototypeStore.get("think-mixed") === thinkMixed
    && prototypeStore.values().includes(thinkOld)
    && thinkMixed.data.blocks === rawMixedBlocks,
  "只读 Think overlay 修改了原型 node store 或原始节点",
)
findElement(
  prototypeThinkView,
  (element) => element.props?.["data-dsd-pancake-operation-summary"] === "",
).props.onClick()
prototypeThinkView = prototypeThinkPlugin.renderView(ownerFor(
  thinkOld,
  prototypeSnapshot,
  "prototype-think-session",
))
prototypeOfficialView = findElement(
  prototypeThinkView,
  (element) => element.props?.["data-official-order"] !== undefined,
)
expect(
  prototypeOfficialView.props["data-official-order"].includes("think-tool-b")
    && !prototypeOfficialView.props["data-official-order"].includes("think-old")
    && prototypeOfficialView.props["data-value-block-kinds"].includes(
      "think-mixed:text+image+other+tool-call",
    )
    && !prototypeOfficialView.props["data-value-block-kinds"].includes(
      "think-mixed:text+reasoning",
    ),
  "工具展开时没有继续应用原型 node store 上的 Think 投影",
)
let thinkSummaries = findElements(
  thinkView,
  (element) => element.props?.["data-dsd-pancake-think-summary"] === "",
)
expect(thinkSummaries.length === 1, "同一 turn 没有只保留一个 Think 摘要")
let thinkSummary = thinkSummaries[0]
expect(
  thinkSummary.type === "button"
    && thinkSummary.props.type === "button"
    && thinkSummary.props["aria-expanded"] === false,
  "Think 摘要没有使用支持 Enter/Space 的原生 button 或没有默认折叠",
)
expect(
  thinkSummary.props["aria-label"] === "展开最新 Think：最新有效内容"
    && textOf(thinkSummary).includes("Think·最新有效内容"),
  "Think 摘要没有使用最后一个非空文本行或错误显示了数量",
)
expect(
  findElement(thinkView, (element) => element.props?.["data-dsd-pancake-think-body"] === "")
    === undefined,
  "Think 默认折叠时仍渲染了全文",
)
const thinkSummaryFlow = findElements(thinkView, (element) => element.type === "official-flow-item")
  .find((element) => findElement(
    element,
    (child) => child.props?.["data-dsd-pancake-think-summary"] === "",
  ) !== undefined)
const projectedMixed = findElements(
  thinkSummaryFlow,
  (element) => element.props?.["data-assistant-node"] === "think-mixed",
)
expect(
  projectedMixed.map((element) => element.props["data-block-kinds"]).join(",")
    === "text,image,other,tool-call",
  "mixed assistant-step 没有只剔除 reasoning 并保留 text/image/unknown/tool-call",
)
expect(
  findElement(thinkSummaryFlow, (element) => element.type === "official-text") !== undefined
    && findElement(thinkSummaryFlow, (element) => element.type === "official-image") !== undefined
    && findElement(thinkSummaryFlow, (element) => element.type === "official-unknown") !== undefined
    && findElement(thinkSummaryFlow, (element) => element.type === "official-reasoning") === undefined,
  "Think 投影丢失 mixed blocks 或把旧 reasoning 交回官方 renderer",
)
const mixedVisibleOrder = findElements(thinkSummaryFlow, (element) => (
  element.type === "official-text"
  || element.type === "official-image"
  || element.type === "official-unknown"
  || element.props?.["data-dsd-pancake-think-summary"] === ""
)).map((element) => (
  element.props?.["data-dsd-pancake-think-summary"] === "" ? "think" : element.type
))
expect(
  mixedVisibleOrder.join(",") === "official-text,think,official-image,official-unknown",
  "Think 摘要没有在最新 reasoning 的原位置就地替换，mixed block 可见顺序被改写",
)
expect(
  thinkSummaryFlow?.props?.["data-flow-key"] === "think-mixed",
  "Think 摘要没有锚定到当前最新的非空 reasoning 节点",
)

thinkSummary.props.onClick()
thinkView = thinkPlugin.renderView(ownerFor(thinkOld, thinkSnapshot, "think-session"))
thinkSummary = findElement(
  thinkView,
  (element) => element.props?.["data-dsd-pancake-think-summary"] === "",
)
expect(thinkSummary.props["aria-expanded"] === true, "点击 Think 摘要后没有展开")
expect(
  textOf(findElement(
    thinkView,
    (element) => element.props?.["data-dsd-pancake-think-body"] === "",
  )) === "流式推理开头\n  最新有效内容  \n",
  "Think 展开后没有显示最新 reasoning 的完整原文",
)
expect(
  findElement(
    thinkPlugin.renderView(ownerFor(thinkOld, thinkSnapshot, "think-session-other")),
    (element) => element.props?.["data-dsd-pancake-think-summary"] === "",
  ).props["aria-expanded"] === false,
  "Think 展开状态污染了其他 session",
)

const thinkLatest = assistantNode("think-latest", 40, [
  { kind: "reasoning", text: "完成阶段\n最新落点" },
], "settled", 9)
const thinkLatestEmpty = assistantNode("think-latest-empty", 40, [
  { kind: "reasoning", text: "\n  " },
], "settled", 10)
thinkSnapshot = snapshotFor([[40, [
  thinkOld,
  thinkToolA,
  thinkMixed,
  thinkContext,
  thinkToolB,
  thinkEmptyTail,
  thinkRetry,
  thinkError,
  thinkHidden,
  thinkLatest,
  thinkLatestEmpty,
]]])
thinkView = thinkPlugin.renderView(ownerFor(thinkLatest, thinkSnapshot, "think-session"))
thinkSummaries = findElements(
  thinkView,
  (element) => element.props?.["data-dsd-pancake-think-summary"] === "",
)
expect(
  thinkSummaries.length === 1
    && thinkSummaries[0].props["aria-expanded"] === true
    && thinkSummaries[0].props["aria-label"] === "收起最新 Think：最新落点",
  "新 reasoning 到达后没有移动唯一摘要或保留 session+turn 展开态",
)
const movedThinkFlow = findElements(thinkView, (element) => element.type === "official-flow-item")
  .find((element) => findElement(
    element,
    (child) => child.props?.["data-dsd-pancake-think-summary"] === "",
  ) !== undefined)
expect(
  movedThinkFlow?.props?.["data-flow-key"] === "think-latest",
  "尾部空占位覆盖了最近的非空 Think 或摘要没有移动到新节点",
)
expect(
  textOf(findElement(
    thinkView,
    (element) => element.props?.["data-dsd-pancake-think-body"] === "",
  )) === "完成阶段\n最新落点",
  "锚点移动后展开正文没有更新到最新 reasoning",
)

const toolSummaryWhileThinking = findElement(
  thinkView,
  (element) => element.props?.["data-dsd-pancake-operation-summary"] === "",
)
toolSummaryWhileThinking.props.onClick()
thinkView = thinkPlugin.renderView(ownerFor(thinkLatest, thinkSnapshot, "think-session"))
thinkOfficialView = findElement(
  thinkView,
  (element) => element.props?.["data-official-order"] !== undefined,
)
expect(
  thinkOfficialView.props["data-official-order"].includes("think-tool-b")
    && !thinkOfficialView.props["data-official-order"].includes("think-old")
    && !thinkOfficialView.props["data-official-order"].includes("think-empty-tail")
    && !thinkOfficialView.props["data-official-order"].includes("think-latest-empty")
    && findElements(
      thinkView,
      (element) => element.props?.["data-dsd-pancake-think-summary"] === "",
    ).length === 1,
  "工具展开恢复了旧 Think、空白节点或影响了 Think 唯一摘要",
)

const interruptedThink = assistantNode("think-interrupted", 41, [
  { kind: "reasoning", text: "中断前分析\n中断前最后内容" },
], "interrupted", 0)
const interruptedSnapshot = snapshotFor([[41, [interruptedThink]]])
const interruptedView = thinkPlugin.renderView(ownerFor(
  interruptedThink,
  interruptedSnapshot,
  "think-session",
))
expect(
  findElement(
    interruptedView,
    (element) => element.props?.["data-dsd-pancake-think-summary"] === "",
  )?.props?.["aria-expanded"] === false
    && findElement(interruptedView, (element) => element.type === "official-stopped") !== undefined,
  "Think 展开态污染同 session 的其他 turn，或 interrupted 已停止标记被投影丢失",
)

// 展开状态只能跟随仍存活的 session/turn：turn 从 snapshot 消失时仅清理该
// Think，工具的每会话偏好仍保留；session removed 与插件 shutdown 清空全部状态。
const expansionLifecycle = registeredPlugin()
const lifecycleThink = assistantNode("lifecycle-think", 60, [
  { kind: "reasoning", text: "生命周期推理\n生命周期最新" },
], "settled", 0)
const lifecycleTool = toolNode(
  "lifecycle-tool",
  60,
  running("lifecycle-call", "read", { path: "Sources/Lifecycle.swift" }, 1),
  1,
)
const lifecycleSnapshot = snapshotFor([[60, [lifecycleThink, lifecycleTool]]])
let lifecycleView = expansionLifecycle.renderView(ownerFor(
  lifecycleThink,
  lifecycleSnapshot,
  "expansion-lifecycle-session",
))
findElement(
  lifecycleView,
  (element) => element.props?.["data-dsd-pancake-think-summary"] === "",
).props.onClick()
findElement(
  lifecycleView,
  (element) => element.props?.["data-dsd-pancake-operation-summary"] === "",
).props.onClick()

const nextLifecycleTool = toolNode(
  "lifecycle-tool-next",
  61,
  running("lifecycle-call-next", "bash", { command: "swift test" }, 2),
  0,
)
const nextLifecycleSnapshot = snapshotFor([[61, [nextLifecycleTool]]])
const nextLifecycleView = expansionLifecycle.renderView(ownerFor(
  nextLifecycleTool,
  nextLifecycleSnapshot,
  "expansion-lifecycle-session",
))
expect(
  findElement(
    nextLifecycleView,
    (element) => element.props?.["data-dsd-pancake-operation-summary"] === "",
  ).props["aria-expanded"] === true,
  "turn 消失时错误清除了同一 session 的工具展开偏好",
)
lifecycleView = expansionLifecycle.renderView(ownerFor(
  lifecycleThink,
  lifecycleSnapshot,
  "expansion-lifecycle-session",
))
expect(
  findElement(
    lifecycleView,
    (element) => element.props?.["data-dsd-pancake-think-summary"] === "",
  ).props["aria-expanded"] === false,
  "已从 snapshot 消失的 turn 再出现时继承了陈旧 Think 展开状态",
)

expansionLifecycle.renderView(ownerFor(
  lifecycleThink,
  { ...lifecycleSnapshot, removed: true },
  "expansion-lifecycle-session",
))
lifecycleView = expansionLifecycle.renderView(ownerFor(
  lifecycleThink,
  lifecycleSnapshot,
  "expansion-lifecycle-session",
))
expect(
  findElement(
    lifecycleView,
    (element) => element.props?.["data-dsd-pancake-operation-summary"] === "",
  ).props["aria-expanded"] === false,
  "session removed 后仍继承陈旧工具展开状态",
)
findElement(
  lifecycleView,
  (element) => element.props?.["data-dsd-pancake-operation-summary"] === "",
).props.onClick()
findElement(
  lifecycleView,
  (element) => element.props?.["data-dsd-pancake-think-summary"] === "",
).props.onClick()
expansionLifecycle.dispose()
const afterExpansionShutdown = registeredPlugin()
const afterShutdownView = afterExpansionShutdown.renderView(ownerFor(
  lifecycleThink,
  lifecycleSnapshot,
  "expansion-lifecycle-session",
))
expect(
  findElement(
    afterShutdownView,
    (element) => element.props?.["data-dsd-pancake-operation-summary"] === "",
  ).props["aria-expanded"] === false
    && findElement(
      afterShutdownView,
      (element) => element.props?.["data-dsd-pancake-think-summary"] === "",
    ).props["aria-expanded"] === false,
  "插件 shutdown 后仍保留工具或 Think 展开状态",
)
afterExpansionShutdown.dispose()

const ThirdPartyChatView = (props) => jsx("third-party-chat-source", {
  children: jsx(OfficialChatView, props),
})
const thirdPartyViewEntry = {
  ...officialViewEntry,
  component: ThirdPartyChatView,
  options: { ...officialViewEntry.options, priority: -5 },
}
const ThirdPartyHeader = (props) => jsx("third-party-header-source", {
  children: jsx(OfficialHeader, props),
})
const thirdPartyHeaderEntry = {
  ...officialHeaderEntry,
  component: ThirdPartyHeader,
  options: { ...officialHeaderEntry.options, priority: -3 },
}
const rootSwap = registeredPlugin()
rootSwap.setSources("conversation.view", [officialViewEntry, thirdPartyViewEntry])
rootSwap.setSources("conversation.session.header", [officialHeaderEntry, thirdPartyHeaderEntry])
await rootSwap.flushMutations()
expect(
  rootSwap.activeRecords("conversation.view")[0]?.config.priority === -6,
  "chat root source 变化后没有用当前 winner priority - 1 重建",
)
expect(
  rootSwap.activeRecords("conversation.session.header")[0]?.config.priority === -4,
  "header root source 变化后没有用当前 winner priority - 1 重建",
)
expect(
  findElement(
    rootSwap.renderView(ownerFor(writeNode, snapshot, "root-swap")),
    (element) => element.type === "third-party-chat-source",
  ) !== undefined,
  "第三方更低 priority chat winner 没有成为新的委托 source",
)
const abdicatedViewSource = rootSwap.sourceRecord("conversation.view", ThirdPartyChatView)
const abdicatedHeaderSource = rootSwap.sourceRecord("conversation.session.header", ThirdPartyHeader)
rootSwap.triggerEntryError(abdicatedViewSource, { abdicated: false })
expect(
  findElement(
    rootSwap.renderView(ownerFor(writeNode, snapshot, "root-non-abdicating-error")),
    (element) => element.type === "third-party-chat-source",
  ) !== undefined,
  "非 abdicating source error 被错误记成退席来源",
)
rootSwap.triggerEntryError(abdicatedViewSource)
await rootSwap.flushMutations()
expect(abdicatedViewSource.abdicated === true, "chat source render error 没有先标记 abdicated")
expect(
  rootSwap.activeRecords("conversation.view")[0]?.config.priority === -6,
  "低 priority chat source 退席后没有避开 raw ledger 占用的 priority",
)
expect(
  findElement(
    rootSwap.renderView(ownerFor(writeNode, snapshot, "root-abdicated")),
    (element) => element.type === "third-party-chat-source",
  ) === undefined,
  "chat source 退席后仍短暂委托了 dead source",
)
rootSwap.triggerEntryError(abdicatedHeaderSource)
await rootSwap.flushMutations()
expect(abdicatedHeaderSource.abdicated === true, "header source render error 没有先标记 abdicated")
expect(
  rootSwap.activeRecords("conversation.session.header")[0]?.config.priority === -4,
  "低 priority header source 退席后没有避开 raw ledger 占用的 priority",
)
expect(
  findElement(rootSwap.renderHeader({
    views: {
      list: () => [
        { id: "chat", label: "shadow" },
        { id: "chat", label: "abdicated" },
        { id: "chat", label: "official" },
      ],
      subscribe: () => () => {},
      version: () => 0,
    },
  }), (element) => element.type === "third-party-header-source") === undefined,
  "header source 退席后仍短暂委托了 dead source",
)

const CollisionChatView = (props) => jsx("collision-chat-source", {
  children: jsx(OfficialChatView, props),
})
const collisionViewEntry = {
  ...officialViewEntry,
  component: CollisionChatView,
  options: { ...officialViewEntry.options, priority: -1 },
}
const CollisionHeader = (props) => jsx("collision-header-source", {
  children: jsx(OfficialHeader, props),
})
const collisionHeaderEntry = {
  ...officialHeaderEntry,
  component: CollisionHeader,
  options: { ...officialHeaderEntry.options, priority: -1 },
}
const abdicatedPriorityCollision = registeredPlugin({
  sourceSlots: new Map([
    ["conversation.view", [officialViewEntry, collisionViewEntry]],
    ["conversation.session.header", [officialHeaderEntry, collisionHeaderEntry]],
  ]),
})
expect(
  abdicatedPriorityCollision.activeRecords("conversation.view")[0]?.config.priority === -2,
  "root priority allocator 没有选择低于 raw chat cell 全部 priority 的值",
)
expect(
  abdicatedPriorityCollision.activeRecords("conversation.session.header")[0]?.config.priority === -2,
  "root priority allocator 没有选择低于 raw header cell 全部 priority 的值",
)
abdicatedPriorityCollision.triggerEntryError(
  abdicatedPriorityCollision.sourceRecord("conversation.view", CollisionChatView),
)
abdicatedPriorityCollision.triggerEntryError(
  abdicatedPriorityCollision.sourceRecord("conversation.session.header", CollisionHeader),
)
await abdicatedPriorityCollision.flushMutations()
expect(
  abdicatedPriorityCollision.activeRecords("conversation.view")[0]?.config.priority === -2,
  "abdicated chat priority=-1 留在 raw ledger 后 wrapper 撞 cell 或选错 priority",
)
expect(
  abdicatedPriorityCollision.activeRecords("conversation.session.header")[0]?.config.priority === -2,
  "abdicated header priority=-1 留在 raw ledger 后 wrapper 撞 cell 或选错 priority",
)
expect(
  findElement(
    abdicatedPriorityCollision.renderView(ownerFor(writeNode, snapshot, "collision-recovery")),
    (element) => element.type === "collision-chat-source",
  ) === undefined,
  "priority collision recovery 仍委托 abdicated chat source",
)

const exhaustedPriority = registeredPlugin({
  sourceSlots: new Map([["conversation.view", [{
    ...officialViewEntry,
    options: { ...officialViewEntry.options, priority: -Number.MAX_VALUE },
  }]]]),
})
expect(
  exhaustedPriority.activeRecords("conversation.view").length === 0
    && exhaustedPriority.parent === undefined,
  "没有更低安全有限 priority 时插件没有整体 no-op",
)
const nonfiniteRawPriority = registeredPlugin({
  sourceSlots: new Map([["conversation.view", [
    officialViewEntry,
    {
      ...officialViewEntry,
      component: () => null,
      options: { ...officialViewEntry.options, priority: Number.POSITIVE_INFINITY },
    },
  ]]]),
})
expect(
  nonfiniteRawPriority.activeRecords("conversation.view").length === 0
    && nonfiniteRawPriority.parent === undefined,
  "same-cell raw ledger 含非有限 priority 时插件没有整体 no-op",
)

const sourceV1 = atomicEntry("read", {
  component: (props) => jsx("official-read-version", { version: "v1", callId: props.callId }),
})
const sourceV2 = atomicEntry("read", {
  component: (props) => jsx("official-read-version", { version: "v2", callId: props.callId }),
})
const lifecycleSources = new Map([["tool.call.toolview", [sourceV1]]])
const lifecycle = registeredPlugin({ sourceSlots: lifecycleSources })
const oldParent = lifecycle.parent
const oldMirror = lifecycle.registrations.find((entry) => (
  !entry.disposed
  && entry.config.name.startsWith("dsd-pancake.operation.alias")
  && entry.config.key === "read"
))
const logStart = lifecycle.registrationLog.length
lifecycle.setSources("tool.call.toolview", [sourceV2])
await lifecycle.flushMutations()
expect(oldParent.disposed && oldMirror.disposed, "source swap 前没有完整释放旧 shadow tree")
const swapLog = lifecycle.registrationLog.slice(logStart)
expect(
  swapLog.findIndex((item) => item.startsWith("register:conversation.view"))
    > swapLog.findIndex((item) => item.startsWith("dispose:conversation.view")),
  "source swap 没有 remove-before-add，可能撞上同 key + priority",
)
const readRoot = running("swap-read", "read", { path: "README.md" }, 1)
const readNode = toolNode("swap-node", 20, readRoot, 1)
const swapOwner = ownerFor(
  readNode,
  snapshotFor([[20, [readNode]]]),
  "swap-session",
)
const swapSummary = findElement(
  lifecycle.renderParent(swapOwner),
  (element) => element.props?.["data-dsd-pancake-operation-summary"] === "",
)
swapSummary.props.onClick()
const swappedCard = lifecycle.renderParent(swapOwner)
expect(findElement(swappedCard, (element) => element.props?.version === "v2") !== undefined, "swap 后仍 dispatch v1")
lifecycle.setSources("tool.call.toolview", [])
await lifecycle.flushMutations()
expect(
  lifecycle.registrations.every((entry) => (
    entry.disposed || entry.config.key !== "read" || !entry.config.name.startsWith("dsd-pancake.operation.alias")
  )),
  "source remove 后仍残留 mirror",
)
expect(lifecycle.parent !== undefined, "空 source tree 不应让安全父 delegation 消失")
lifecycle.dispose()
expect(lifecycle.activeSubscriptionCount === 0, "插件卸载没有清理全部递归 source subscriptions")
expect(lifecycle.registrations.every((record) => record.disposed), "插件卸载没有清理整个 private tree")
await lifecycle.flushMutations()

const microtaskGate = registeredPlugin()
await microtaskGate.flushMutations()
microtaskGate.setSources("tool.call.toolview", [sourceV2])
await microtaskGate.flushMutations()
const registrationsAfterSourceRebuild = microtaskGate.registrations.length
await microtaskGate.flushMutations()
expect(
  microtaskGate.registrations.length === registrationsAfterSourceRebuild,
  "自身 root shadow 的 microtask 通知绕过 candidate fingerprint 触发了自激重建",
)

const detailV2 = {
  ...cordisDetailEntry,
  component(props) {
    return jsx("official-cordis-detail", {
      "data-cordis-detail-v2": props.callId,
      children: props.renderSlotChain("cordis.run.deep", { callId: props.callId }),
    })
  },
}
const descendantSwap = registeredPlugin()
descendantSwap.setSources("cordis.run.detail", [detailV2])
await descendantSwap.flushMutations()
const swappedCordis = descendantSwap.renderParent(ownerFor(
  cordisNode,
  snapshotFor([[10, [cordisNode]]]),
  "descendant-swap",
))
expect(
  findElement(swappedCordis, (element) => element.props?.["data-cordis-detail-v2"] === "call-cordis")
    !== undefined,
  "descendant source swap 没有触发递归整树重建",
)

const undefinedChain = registeredPlugin()
undefinedChain.setSources("cordis.run.deep", [{
  component: () => jsx("undefined-chain-winner", {}),
  options: { priority: -2 },
  select: () => undefined,
}])
await undefinedChain.flushMutations()
expect(
  findElement(
    undefinedChain.renderParent(ownerFor(
      cordisNode,
      snapshotFor([[10, [cordisNode]]]),
      "undefined-chain",
    )),
    (element) => element.type === "undefined-chain-winner",
  ) !== undefined,
  "chain selector 返回 undefined 时被错误当成拒绝；正式契约仅 null 表示拒绝",
)

let failSwap = false
const registerFailure = registeredPlugin({
  sourceSlots: new Map([["tool.call.toolview", [sourceV1]]]),
  registerFailure(config) {
    return failSwap
      && config.name.startsWith("dsd-pancake.operation.alias")
      && config.key === "write"
  },
})
failSwap = true
registerFailure.setSources("tool.call.toolview", [sourceV2, atomicEntry("write")])
await registerFailure.flushMutations()
expect(registerFailure.parent === undefined, "重建 register 异常没有回滚父 takeover")
expect(registerFailure.activeSubscriptionCount === 0, "重建异常后仍保留 source subscriptions")
expect(registerFailure.registrations.every((record) => record.disposed), "重建异常留下了部分 private tree")

const cleanupFailure = registeredPlugin({
  sourceSlots: new Map([["tool.call.toolview", [sourceV1]]]),
  unsubscribeFailure: true,
  disposalFailure(config) {
    return config.name.startsWith("dsd-pancake.operation.alias") && config.key === "read"
  },
})
cleanupFailure.dispose()
expect(cleanupFailure.parent === undefined, "unsubscribe/disposer 抛错中断了 parent 清理")
expect(cleanupFailure.registrations.every((record) => record.disposed), "单个 disposer 抛错中断其余清理")
await cleanupFailure.flushMutations()

const incompatible = registeredPlugin({
  specs: new Map([
    ["conversation.chat.node", { kind: "single", scope: "session" }],
    ["tool.call.toolview", { kind: "keyed", scope: "session" }],
  ]),
  sourceSlots: new Map([["tool.call.toolview", officialToolviewEntries]]),
})
expect(incompatible.parent === undefined, "父 slot spec 不兼容时没有安全 no-op")

const missingChild = registeredPlugin({
  specs: new Map([["conversation.chat.node", { kind: "keyed", scope: "session" }]]),
  sourceSlots: new Map([["tool.call.toolview", officialToolviewEntries]]),
})
expect(missingChild.parent === undefined, "atomic child slot 缺失时没有安全 no-op")

// entry error（插槽条目渲染异常）测试必须最后运行：插件设计为本次 client
// module 生命周期永久熔断，后续 apply 也不能再次 takeover。
const renderFailure = registeredPlugin({
  sourceSlots: new Map([["tool.call.toolview", [sourceV1]]]),
})
const failedMirror = renderFailure.registrations.find((entry) => (
  !entry.disposed
  && entry.config.name.startsWith("dsd-pancake.operation.alias")
  && entry.config.key === "assistant-step"
))
expect(failedMirror !== undefined, "没有为 assistant-step 注册 private alias renderer")
renderFailure.triggerEntryError(failedMirror)
expect(renderFailure.parent === undefined, "private alias render error 没有回滚 parent takeover")
expect(renderFailure.activeSubscriptionCount === 0, "render error 后仍保留 source subscriptions")
expect(renderFailure.registrations.every((record) => record.disposed), "render error 后仍残留 private tree")
await renderFailure.flushMutations()
const registrationCountAfterFailure = renderFailure.registrations.length
renderFailure.setSources("tool.call.toolview", [sourceV2])
await renderFailure.flushMutations()
expect(
  renderFailure.registrations.length === registrationCountAfterFailure,
  "render error 熔断后 source change 又重新注册了 private tree",
)
renderFailure.reapply()
expect(renderFailure.parent === undefined, "首次 entry error 后没有在本次 App 运行永久禁用")

const source = await readFile(clientPath, "utf8")
const forbiddenPatterns = [
  [/MutationObserver/, "DOM 变更监听"],
  [/querySelector/, "DOM selector"],
  [/getElementById/, "DOM id selector"],
  [/\bfetch\s*\(/, "网络请求"],
  [/localStorage/, "localStorage 持久化"],
  [/sessionStorage/, "sessionStorage 持久化"],
  [/indexedDB/, "IndexedDB 持久化"],
]
for (const [pattern, label] of forbiddenPatterns) {
  expect(!pattern.test(source), `操作折叠插件不应使用${label}`)
}
expect(!/source\.component\s*\(/.test(source), "source component 被直接函数调用")
expect(!source.includes("ctx.slots.isLive"), "插件使用了 DSH 0.1.1-rc.2 未公开的 slots.isLive")

console.log("operation-folding plugin verification passed")
