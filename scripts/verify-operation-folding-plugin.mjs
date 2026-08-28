import { execFileSync } from "node:child_process"
import { readFile } from "node:fs/promises"
import { fileURLToPath, pathToFileURL } from "node:url"

const expect = (condition, message) => {
  if (!condition) throw new Error(message)
}

const clientPath = new URL("../Plugins/dsd-pancake-operation-folding/lib/client.js", import.meta.url)
const clientURL = pathToFileURL(clientPath.pathname)
const packagePath = new URL("../Plugins/dsd-pancake-operation-folding/package.json", import.meta.url)
const patchPath = new URL("../Plugins/dsd-pancake-operation-folding/cordis.patch.yml", import.meta.url)
const mainPath = new URL("../Plugins/dsd-pancake-operation-folding/lib/index.js", import.meta.url)
const packageSource = await readFile(packagePath, "utf8")
const packageManifest = JSON.parse(packageSource)
const patchManifest = JSON.parse(execFileSync(
  "/usr/bin/ruby",
  [
    "--disable=gems",
    "-rjson",
    "-ryaml",
    "-e",
    "print JSON.generate(YAML.safe_load(File.read(ARGV.fetch(0)), [], [], false))",
    fileURLToPath(patchPath),
  ],
  { encoding: "utf8" },
))
const mainModule = await import(`${pathToFileURL(fileURLToPath(mainPath)).href}?main=${String(Date.now())}`)

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

const react = {
  useMemo(factory) {
    return factory()
  },
  useSyncExternalStore(_subscribe, getSnapshot) {
    return getSnapshot()
  },
}
const Fragment = Symbol("Fragment")
const jsx = (type, props, key) => ({ type, props: props ?? {}, key })
const jsxs = jsx
const requireForTest = (name) => {
  if (name === "react") return react
  if (name === "react/jsx-runtime") return { Fragment, jsx, jsxs }
  throw new Error(`操作折叠插件请求了未知依赖：${name}`)
}

const isElement = (value) => typeof value === "object" && value !== null && "type" in value
const materialize = (value) => {
  if (Array.isArray(value)) return value.map(materialize)
  if (!isElement(value)) return value
  if (typeof value.type === "function") return materialize(value.type(value.props))
  if (
    typeof value.type === "object"
    && value.type !== null
    && typeof value.type.type === "function"
  ) {
    return materialize(value.type.type(value.props))
  }
  const children = value.props?.children
  return {
    ...value,
    props: {
      ...value.props,
      ...(children === undefined ? {} : { children: materialize(children) }),
    },
  }
}

const childrenOf = (element) => {
  const children = element?.props?.children
  if (children === undefined || children === null) return []
  return Array.isArray(children) ? children : [children]
}
const findElement = (element, predicate) => {
  if (element === undefined || element === null || typeof element !== "object") return undefined
  if (predicate(element)) return element
  for (const child of childrenOf(element)) {
    const found = findElement(child, predicate)
    if (found !== undefined) return found
  }
  return undefined
}
const textOf = (element) => {
  if (element === undefined || element === null || element === false) return ""
  if (typeof element === "string" || typeof element === "number") return String(element)
  if (Array.isArray(element)) return element.map(textOf).join("")
  return childrenOf(element).map(textOf).join("")
}

const callName = (block) => block.kind === "tool-result" ? block.call.name : block.name
const officialParentInject = () => ({
  useHostDescription(selector) {
    return selector({ home: "/Users/test" })
  },
})
const OfficialToolCallTree = (props) => {
  const home = props.useHostDescription((description) => description?.home)
  const renderBranch = (block) => {
    const owner = {
      block,
      callId: block.callId,
      cwd: props.cwd,
      home,
      inspect: () => props.inspectCall(block.callId),
      openFile: props.openFile,
      toolName: callName(block),
    }
    return jsxs("official-tool-branch", {
      "data-chat-call-id": block.callId,
      "data-selected": block.callId === props.selectedCallId || undefined,
      children: [
        props.renderSlot("tool.call.toolview", owner, {
          entryKey: owner.toolName,
          fallback: jsx("official-generic-tool-card", {
            "data-official-generic": owner.toolName,
            callId: owner.callId,
          }),
        }),
        block.subCalls.map((child) => renderBranch(child)),
      ],
    })
  }
  return jsx("official-tool-tree", {
    "data-official-parent": "",
    children: renderBranch(props.node.data.root),
  })
}
const officialParentEntry = {
  component: OfficialToolCallTree,
  options: { key: "tool-call", priority: 0 },
  locale: "conversation",
  inject: officialParentInject,
  children: {
    "tool.call.toolview": { kind: "keyed", scope: "session" },
  },
}

const OfficialChatView = (props) => {
  const order = props.useSession((state) => state.chat.order)
  const nodes = props.useSession((state) => state.chat.nodes)
  return jsx("official-chat-view", {
    "data-official-order": order.join(","),
    "data-order-reference": order,
    children: order.map((nodeKey) => {
      const node = nodes.get(nodeKey)
      return jsx("official-flow-item", {
        "data-flow-key": nodeKey,
        children: props.renderSlot("conversation.chat.node", {
          cwd: props.cwd,
          fileMentions: props.fileMentions,
          forkAt: props.forkAt,
          inspectCall: props.inspectCall,
          node,
          openFile: props.openFile,
          renderMessageImages: props.renderMessageImages,
          sessionId: props.sessionId,
          useSession: props.useSession,
        }, {
          entryKey: node.kind,
        }),
      }, nodeKey)
    }),
  })
}
const officialViewEntry = {
  component: OfficialChatView,
  options: { id: "chat", order: 0, priority: 0, label: "对话" },
  locale: "conversation",
  inject: () => ({}),
  children: {
    "conversation.chat.node": { kind: "keyed", scope: "session" },
    "conversation.message.images": { kind: "single", scope: "session" },
  },
}
const OfficialHeader = (props) => jsx("official-header", {
  "data-header-tabs": props.views.list().map((view) => view.id).join(","),
  "data-header-labels": props.views.list().map((view) => view.label).join(","),
})
const officialHeaderEntry = {
  component: OfficialHeader,
  options: { priority: 0 },
  locale: "conversation",
  inject: () => ({}),
  children: {
    "conversation.session.header.actions": { kind: "list", scope: "session" },
  },
}

const atomicEntry = (key, fields = {}) => ({
  component(props) {
    return jsx("official-tool-card", {
      "data-official-tool": key,
      callId: props.callId,
      children: key,
    })
  },
  options: { key, priority: 0 },
  locale: "conversation",
  ...fields,
})

const cordisDeepSelect = (owner) => ({ callId: owner.callId })
const cordisDeepEntry = {
  component(props) {
    return jsx("official-cordis-deep", {
      "data-cordis-deep": props.matched.callId,
      children: "deep",
    })
  },
  options: { priority: 0 },
  select: cordisDeepSelect,
}
const cordisDetailEntry = {
  component(props) {
    return jsx("official-cordis-detail", {
      "data-cordis-detail": props.callId,
      children: props.renderSlotChain("cordis.run.deep", { callId: props.callId }),
    })
  },
  options: { key: "detail", priority: 0 },
  children: {
    "cordis.run.deep": { kind: "chain", scope: "session" },
  },
}
const cordisInject = () => ({ injectedCordisValue: "native-inject" })
const cordisStore = { create() {} }
const cordisRunEntry = atomicEntry("cordis_run", {
  component(props) {
    return jsx("official-cordis-run", {
      "data-official-tool": "cordis_run",
      "data-injected-value": props.injectedCordisValue,
      callId: props.callId,
      children: props.renderSlot("cordis.run.detail", { callId: props.callId }, {
        entryKey: "detail",
        fallback: jsx("cordis-detail-fallback", {}),
      }),
    })
  },
  children: {
    "cordis.run.detail": { kind: "keyed", scope: "session" },
  },
  inject: cordisInject,
  locale: "cordis",
  store: cordisStore,
})
const memoLikeComponent = {
  $$typeof: Symbol("react.memo"),
  type(props) {
    return jsx("official-memo-card", { callId: props.callId })
  },
}
const officialToolviewEntries = [
  "bash",
  "read",
  "grep",
  "glob",
  "write",
  "edit",
  "web_fetch",
  "web_search",
  "ask_user_question",
  "todo_write",
].map((key) => atomicEntry(key)).concat(
  cordisRunEntry,
  {
    component: memoLikeComponent,
    options: { key: "memo_like", priority: 0 },
  },
)

const defaultSourceSlots = () => new Map([
  ["conversation.view", [officialViewEntry]],
  ["conversation.session.header", [officialHeaderEntry]],
  ["conversation.chat.node", [officialParentEntry]],
  ["tool.call.toolview", officialToolviewEntries],
  ["cordis.run.detail", [cordisDetailEntry]],
  ["cordis.run.deep", [cordisDeepEntry]],
])
const defaultSpecs = () => new Map([
  ["conversation.view", { kind: "list", scope: "session" }],
  ["conversation.session.header", { kind: "single", scope: "session" }],
  ["conversation.chat.node", { kind: "keyed", scope: "session" }],
  ["conversation.message.images", { kind: "single", scope: "session" }],
  ["conversation.session.header.actions", { kind: "list", scope: "session" }],
  ["tool.call.toolview", { kind: "keyed", scope: "session" }],
  ["cordis.run.detail", { kind: "keyed", scope: "session" }],
  ["cordis.run.deep", { kind: "chain", scope: "session" }],
])

const registeredPlugin = (options = {}) => {
  const plugin = definition.factory(requireForTest)
  const specs = options.specs ?? defaultSpecs()
  const configuredSourceSlots = options.sourceSlots === undefined
    ? defaultSourceSlots()
    : new Map([...defaultSourceSlots(), ...options.sourceSlots])
  const cloneSourceEntries = (entries) => entries.map((entry) => ({
    ...entry,
    abdicated: false,
    options: { ...entry.options },
  }))
  const sourceSlots = new Map([...configuredSourceSlots].map(([name, entries]) => (
    [name, cloneSourceEntries(entries)]
  )))
  const sourceEntrySlots = new Map()
  for (const [name, entries] of sourceSlots) {
    for (const entry of entries) sourceEntrySlots.set(entry, name)
  }
  const declarations = new Map([...specs].map(([name, spec]) => [name, { owner: "official", spec }]))
  const liveEntries = new Map()
  const registrations = []
  const registrationLog = []
  const disposalLog = []
  const slotDispatches = []
  const jsxDelegations = []
  const injectedSlots = []
  const subscribers = new Map()
  const entryErrorListeners = new Set()
  const dirtySlots = new Set()
  const notificationCallbackCounts = new Map()
  let mutationFlushScheduled = false
  let topDispose

  const notifyMutation = (name) => {
    dirtySlots.add(name)
    if (mutationFlushScheduled) return
    mutationFlushScheduled = true
    queueMicrotask(() => {
      mutationFlushScheduled = false
      const dirty = [...dirtySlots]
      dirtySlots.clear()
      for (const slot of dirty) {
        for (const callback of [...(subscribers.get(slot) ?? [])]) {
          notificationCallbackCounts.set(
            slot,
            (notificationCallbackCounts.get(slot) ?? 0) + 1,
          )
          callback()
        }
      }
    })
  }

  const rows = (name) => {
    let entries = liveEntries.get(name)
    if (entries === undefined) {
      entries = []
      liveEntries.set(name, entries)
    }
    return entries
  }
  const configOf = (record) => record.config ?? record.options
  const priority = (record) => configOf(record).priority ?? 0
  const order = (record) => configOf(record).order ?? 0
  const activeEntries = (name) => {
    const spec = declarations.get(name)?.spec
    return [
      ...(sourceSlots.get(name) ?? []),
      ...rows(name).filter((entry) => !entry.disposed),
    ].sort(spec?.kind === "list"
      ? (left, right) => priority(left) - priority(right) || order(left) - order(right)
      : (left, right) => priority(left) - priority(right))
  }
  const isActiveEntry = (entry) => {
    if (entry?.abdicated === true || entry?.disposed === true) return false
    if (sourceEntrySlots.has(entry)) return (sourceSlots.get(sourceEntrySlots.get(entry)) ?? []).includes(entry)
    return [...liveEntries.values()].some((entries) => entries.includes(entry))
  }
  const cellConflict = (record, config) => {
    const spec = declarations.get(config.name)?.spec
    const existing = configOf(record)
    if (spec?.kind === "keyed") {
      return existing.key === config.key && priority(record) === (config.priority ?? 0)
    }
    if (spec?.kind === "single") return priority(record) === (config.priority ?? 0)
    if (spec?.kind === "list") {
      return existing.id === config.id && priority(record) === (config.priority ?? 0)
    }
    return false
  }
  const removeRecord = (record) => {
    const entries = rows(record.config.name)
    const index = entries.indexOf(record)
    if (index >= 0) entries.splice(index, 1)
  }
  const register = (config, component) => {
    if (!declarations.has(config.name)) throw new Error(`slot not declared: ${config.name}`)
    if (options.registerFailure?.(config, component) === true) {
      throw new Error(`register failure: ${config.name}:${config.key ?? ""}`)
    }
    // SlotCore 的 raw ledger 即使 entry 已 abdicate 仍保留 cell；duplicate
    // 校验因此必须覆盖 source raw entries，而不只是当前 live winner。
    if (activeEntries(config.name).some((record) => cellConflict(record, config))) {
      throw new Error(`duplicate cell: ${config.name}:${config.key ?? ""}:${String(config.priority ?? 0)}`)
    }
    const childEntries = Object.entries(config.children ?? {})
    for (const [childName] of childEntries) {
      if (declarations.has(childName)) throw new Error(`duplicate child declaration: ${childName}`)
    }
    let disposed = false
    const record = {
      abdicated: false,
      component,
      config,
      options: config,
      children: config.children,
      inject: config.inject,
      locale: config.locale,
      select: config.select,
      store: config.store,
      get disposed() { return disposed },
    }
    rows(config.name).push(record)
    registrations.push(record)
    registrationLog.push(`register:${config.name}:${config.key ?? ""}`)
    for (const [childName, spec] of childEntries) declarations.set(childName, { owner: record, spec })
    notifyMutation(config.name)
    for (const [childName] of childEntries) notifyMutation(childName)

    return () => {
      if (disposed) return
      for (const [childName] of childEntries) {
        if (rows(childName).some((entry) => !entry.disposed)) {
          throw new Error(`child slot still occupied: ${childName}`)
        }
      }
      disposed = true
      removeRecord(record)
      for (const [childName] of childEntries) {
        if (declarations.get(childName)?.owner === record) declarations.delete(childName)
      }
      disposalLog.push(`${config.name}:${config.key ?? ""}`)
      registrationLog.push(`dispose:${config.name}:${config.key ?? ""}`)
      notifyMutation(config.name)
      for (const [childName] of childEntries) notifyMutation(childName)
      if (options.disposalFailure?.(config) === true) {
        throw new Error(`dispose failure: ${config.name}:${config.key ?? ""}`)
      }
    }
  }

  const slots = {
    inject(name, callback) {
      injectedSlots.push(name)
      const effect = callback()
      let disposed = false
      const dispose = () => {
        if (disposed) return
        disposed = true
        if (typeof effect === "function") effect()
      }
      if (name === "conversation.view" && topDispose === undefined) topDispose = dispose
      return dispose
    },
    spec(name) {
      return declarations.get(name)?.spec
    },
    register,
    entries(name) {
      return activeEntries(name)
    },
    entriesOfSlot(name) {
      const entries = activeEntries(name).filter(isActiveEntry)
      const spec = declarations.get(name)?.spec
      if (spec?.kind === "chain") return entries
      const winners = []
      const cells = new Set()
      for (const entry of entries) {
        const config = configOf(entry)
        const cell = spec?.kind === "keyed"
          ? config.key
          : spec?.kind === "list"
            ? config.id
            : "single"
        if (cells.has(cell)) continue
        cells.add(cell)
        winners.push(entry)
      }
      return winners
    },
    subscribe(name, callback) {
      let listeners = subscribers.get(name)
      if (listeners === undefined) {
        listeners = new Set()
        subscribers.set(name, listeners)
      }
      listeners.add(callback)
      let disposed = false
      return () => {
        if (disposed) return
        disposed = true
        listeners.delete(callback)
        if (options.unsubscribeFailure === true) throw new Error("unsubscribe failure")
      }
    },
    onEntryError(callback) {
      entryErrorListeners.add(callback)
      return () => {
        entryErrorListeners.delete(callback)
      }
    },
  }

  plugin.apply({ slots })

  const winner = (name, opts) => {
    const spec = declarations.get(name)?.spec
    const entries = slots.entriesOfSlot(name)
    if (spec?.kind === "keyed") return entries.find((entry) => configOf(entry).key === opts?.entryKey)
    if (spec?.kind === "single") return entries[0]
    if (spec?.kind === "list") return entries.find((entry) => (
      opts?.only === undefined || configOf(entry).id === opts.only
    ))
    if (spec?.kind === "chain") {
      for (const entry of entries) {
        const matched = configOf(entry).select?.(opts.owner)
        if (matched !== null) return { entry, matched }
      }
    }
    return undefined
  }
  const renderFallback = (fallback) => materialize(fallback ?? null)
  const renderPublic = (name, owner, opts = {}) => {
    const spec = declarations.get(name)?.spec
    const selected = spec?.kind === "chain" ? winner(name, { owner }) : winner(name, opts)
    const record = spec?.kind === "chain" ? selected?.entry : selected
    if (record === undefined) return renderFallback(opts.fallback)
    slotDispatches.push({ name, owner, options: opts, record })
    const config = configOf(record)
    const boundRenderSlot = (childName, childOwner, childOptions) => {
      const childSpec = config.children?.[childName]
      if (childSpec === undefined) throw new Error(`entry does not own child slot: ${childName}`)
      if (childSpec.kind === "chain") throw new Error(`child slot requires renderSlotChain: ${childName}`)
      return renderPublic(childName, childOwner, childOptions)
    }
    const boundRenderSlotChain = (childName, childOwner, childOptions) => {
      const childSpec = config.children?.[childName]
      if (childSpec === undefined) throw new Error(`entry does not own child slot: ${childName}`)
      if (childSpec.kind !== "chain") throw new Error(`child slot is not a chain: ${childName}`)
      return renderPublic(childName, childOwner, childOptions)
    }
    const injected = typeof config.inject === "function" ? config.inject() : {}
    const componentProps = {
      ...(config.children === undefined ? {} : {
        renderSlot: boundRenderSlot,
        ...(Object.values(config.children).some((entry) => entry.kind === "chain")
          ? { renderSlotChain: boundRenderSlotChain }
          : {}),
      }),
      ...(config.locale === undefined ? {} : { t: (key) => key }),
      ...injected,
      ...owner,
      ...(spec?.kind === "chain" ? { matched: selected.matched } : {}),
    }
    const delegated = record.component(componentProps)
    jsxDelegations.push({ record, delegatedType: delegated?.type })
    return materialize(delegated)
  }

  const pluginParents = () => registrations.filter((entry) => (
    !entry.disposed
    && entry.config.name.startsWith("dsd-pancake.operation.alias")
    && entry.config.key === "tool-call"
  ))
  const invokeParent = (owner, raw) => {
    const record = pluginParents().sort((a, b) => priority(a) - priority(b))[0]
    if (record === undefined) return undefined
    const result = renderPublic(record.config.name, owner, { entryKey: "tool-call" })
    return raw ? record.component({
      renderSlot: (name, childOwner, childOptions) => renderPublic(name, childOwner, childOptions),
      t: (key) => key,
      ...(typeof record.config.inject === "function" ? record.config.inject() : {}),
      ...owner,
    }) : result
  }

  return {
    declarations,
    disposalLog,
    injectedSlots,
    jsxDelegations,
    plugin,
    registrations,
    registrationLog,
    slotAPIKeys: Object.keys(slots),
    slotDispatches,
    registerForTest(config, component) {
      return register(config, component)
    },
    subscribeForTest(name, callback) {
      return slots.subscribe(name, callback)
    },
    rawEntriesForTest(name) {
      return slots.entries(name)
    },
    winningEntriesForTest(name) {
      return slots.entriesOfSlot(name)
    },
    notificationCallbackCount(name) {
      return notificationCallbackCounts.get(name) ?? 0
    },
    async flushMutations() {
      while (mutationFlushScheduled || dirtySlots.size > 0) await Promise.resolve()
    },
    get activeSubscriptionCount() {
      return [...subscribers.values()].reduce((count, listeners) => count + listeners.size, 0)
    },
    get parent() {
      return pluginParents()[0]
    },
    activeRecords(name) {
      return rows(name).filter((entry) => !entry.disposed)
    },
    dispose() {
      topDispose?.()
    },
    renderParent(owner) {
      return invokeParent(owner, false)
    },
    renderParentRaw(owner) {
      return invokeParent(owner, true)
    },
    renderView(owner) {
      return renderPublic("conversation.view", owner, { only: "chat" })
    },
    renderHeader(owner) {
      return renderPublic("conversation.session.header", owner)
    },
    reapply() {
      plugin.apply({ slots })
    },
    setSources(name, entries) {
      const previous = sourceSlots.get(name) ?? []
      for (const entry of previous) sourceEntrySlots.delete(entry)
      const next = cloneSourceEntries(entries)
      sourceSlots.set(name, next)
      for (const entry of next) sourceEntrySlots.set(entry, name)
      notifyMutation(name)
    },
    triggerEntryError(record, info = { abdicated: true }) {
      const slot = sourceEntrySlots.get(record) ?? record.config?.name
      if (info.abdicated === true) {
        if (record.abdicated === true) return
        record.abdicated = true
        notifyMutation(slot)
      }
      for (const callback of [...entryErrorListeners]) {
        callback(slot, record, new Error("render failure"), info)
      }
    },
    sourceRecord(name, component) {
      return (sourceSlots.get(name) ?? []).find((entry) => entry.component === component)
    },
  }
}

const running = (callId, name, args, time, children = []) => ({
  callId,
  name,
  argsRaw: JSON.stringify(args),
  time,
  subCalls: children,
})
const settled = (callId, name, args, time, isError = false, children = []) => ({
  kind: "tool-result",
  seq: time,
  time,
  callId,
  call: { name, argsRaw: JSON.stringify(args) },
  callTime: time - 1,
  content: [],
  isError,
  error: isError ? { name: "Error", code: "test_failure" } : undefined,
  callView: null,
  resultView: null,
  subCalls: children,
})
const toolNode = (key, turn, root, anchorSeq = 0) => ({
  key,
  kind: "tool-call",
  id: root.callId,
  target: "chat",
  anchorSeq,
  visibility: "visible",
  location: {
    kind: "step",
    turn: { turn },
    step: { step: 1 },
  },
  data: { root },
})
const snapshotFor = (nodesByTurn) => {
  const nodes = new Map()
  const turns = new Map()
  const order = []
  for (const [turn, entries] of nodesByTurn) {
    const keys = []
    for (const node of entries) {
      nodes.set(node.key, node)
      keys.push(node.key)
      order.push(node.key)
    }
    turns.set(turn, keys)
  }
  return {
    chat: {
      order,
      nodes,
      locations: { getTurn: (turn) => turns.get(turn) ?? [] },
    },
  }
}
const ownerFor = (node, snapshot, sessionId, overrides = {}) => ({
  node,
  sessionId,
  selectedCallId: undefined,
  cwd: "/tmp/project",
  openFile() {},
  inspectCall() {},
  useSession(selector) {
    return selector(snapshot)
  },
  ...overrides,
})

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
  && entry.config.key === "read"
))
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
expect(
  packageManifest.name === "@dsd-pancake/dsh-desktop-operation-folding",
  "operation-folding package name 不正确",
)
expect(packageManifest.type === "module", "operation-folding package type 必须是 module")
expect(packageManifest.main === "./lib/index.js", "operation-folding package main 不正确")
expect(
  packageManifest.exports?.["./client"] === "./lib/client.js",
  "operation-folding package 缺少 ./client export",
)
expect(packageManifest.dsh?.client?.platform === "web", "operation-folding dsh client platform 不正确")
expect(
  JSON.stringify(packageManifest.dsh?.client?.inject) === JSON.stringify(["slots"]),
  "operation-folding dsh client inject 必须精确为 ['slots']",
)
expect(
  JSON.stringify(patchManifest) === JSON.stringify([{
    insert: [{
      id: "dsd-pancake-operation-folding",
      name: "@dsd-pancake/dsh-desktop-operation-folding",
    }],
  }]),
  "cordis.patch.yml 必须精确插入 operation-folding package id 与 name",
)
expect(typeof mainModule.apply === "function", "operation-folding package main 无法导入 apply")
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
expect(source.includes("jsx(source.component, delegatedProps("), "source component 没有通过 JSX 委托")
expect(!/source\.component\s*\(/.test(source), "source component 被直接函数调用")
expect(!source.includes("ctx.slots.isLive"), "插件使用了 DSH 0.1.1-rc.2 未公开的 slots.isLive")
expect(source.includes("ctx.slots.entriesOfSlot(slot).find"), "source winner 没有以公开 entriesOfSlot 为权威")
expect(source.includes("ctx.slots.onEntryError("), "插件没有监听 private entry render error")

console.log("operation-folding plugin verification passed")
