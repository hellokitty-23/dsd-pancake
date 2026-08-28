let definition

export const useOperationFoldingDefinition = (value) => {
  definition = value
}

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
const findElements = (element, predicate, found = []) => {
  if (element === undefined || element === null || typeof element !== "object") return found
  if (predicate(element)) found.push(element)
  for (const child of childrenOf(element)) findElements(child, predicate, found)
  return found
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

const OfficialAssistantStep = (props) => jsx("official-assistant-step", {
  "data-assistant-node": props.node.key,
  "data-assistant-status": props.node.data.status,
  "data-block-kinds": props.node.data.blocks
    .filter((block) => block !== undefined)
    .map((block) => block.kind)
    .join(","),
  children: [
    ...props.node.data.blocks.flatMap((block, index) => {
      if (block === undefined) return []
      if (block.kind === "reasoning") {
        return [jsx("official-reasoning", { children: block.text }, index)]
      }
      if (block.kind === "text") return [jsx("official-text", { children: block.text }, index)]
      if (block.kind === "image") return [jsx("official-image", { attachment: block.attachment }, index)]
      if (block.kind === "tool-call") return []
      return [jsx("official-unknown", { payload: block.block }, index)]
    }),
    props.node.data.status === "interrupted"
      ? jsx("official-stopped", { children: "已停止" })
      : null,
  ],
})
const officialAssistantEntry = {
  component: OfficialAssistantStep,
  options: { key: "assistant-step", priority: 0 },
  locale: "conversation",
}

const OfficialChatView = (props) => {
  const order = props.useSession((state) => state.chat.order)
  const nodes = props.useSession((state) => state.chat.nodes)
  const values = Array.from(nodes.values())
  return jsx("official-chat-view", {
    "data-official-order": order.join(","),
    "data-order-reference": order,
    "data-value-block-kinds": values.map((node) => (
      Array.isArray(node?.data?.blocks)
        ? `${node.key}:${node.data.blocks.map((block) => block?.kind ?? "undefined").join("+")}`
        : node?.key
    )).join(","),
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
  ["conversation.chat.node", [officialParentEntry, officialAssistantEntry]],
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

export {
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
}
