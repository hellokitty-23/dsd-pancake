window.__ModuleLoader__.load({
  id: "@dsd-pancake/dsh-desktop-operation-folding",
  factory: (require) => {
    const module = { exports: {} }
    const exports = module.exports

    const foldableTools = new Set([
      "bash",
      "pwsh",
      "read",
      "grep",
      "glob",
      "write",
      "edit",
      "web_fetch",
      "web_search",
      "run_code",
      "cordis_package_inspect",
      "cordis_runtime_inspect",
    ])

    const categoryOrder = [
      ["Read", new Set(["read"])],
      ["Bash", new Set(["bash", "pwsh"])],
      ["Grep", new Set(["grep"])],
      ["Glob", new Set(["glob"])],
      ["Write", new Set(["write"])],
      ["Edit", new Set(["edit"])],
      ["Web", new Set(["web_fetch", "web_search"])],
      ["Code", new Set(["run_code"])],
      ["Inspect", new Set(["cordis_package_inspect", "cordis_runtime_inspect"])],
    ]

    const categoryByTool = new Map(
      categoryOrder.flatMap(([label, tools]) => [...tools].map((tool) => [tool, label])),
    )
    const officialViewSlot = "conversation.view"
    const officialHeaderSlot = "conversation.session.header"
    const officialChatNodeSlot = "conversation.chat.node"
    const officialToolviewSlot = "tool.call.toolview"
    const privateAliasPrefix = "dsd-pancake.operation.alias"
    const emptyKeys = []
    const expandedSessions = new Set()
    const expansionListeners = new Set()
    const expandedThinkTurns = new Map()
    const thinkExpansionListeners = new Set()
    const thinkProjection = Symbol("dsd-pancake.operation.think-projection")
    let renderFailureDisabled = false

    const isRecord = (value) => typeof value === "object" && value !== null && !Array.isArray(value)
    const nodeFromStore = (nodeStore, key) => (
      typeof nodeStore?.get === "function" ? nodeStore.get(key) : nodeStore?.[key]
    )
    const nodeValuesFromStore = (nodeStore) => (
      typeof nodeStore?.values === "function"
        ? Array.from(nodeStore.values())
        : isRecord(nodeStore) ? Object.values(nodeStore) : []
    )
    const projectedNodeStore = (nodeStore, replacements) => {
      const replacementsByNode = new Map()
      for (const [key, replacement] of replacements) {
        const source = nodeFromStore(nodeStore, key)
        if (source !== undefined) replacementsByNode.set(source, replacement)
      }
      const values = nodeValuesFromStore(nodeStore).map((node) => {
        const identityReplacement = replacementsByNode.get(node)
        if (identityReplacement !== undefined) return identityReplacement
        const key = isRecord(node) ? node.key : undefined
        return replacements.has(key) ? replacements.get(key) : node
      })
      return Object.freeze({
        get: (key) => replacements.has(key)
          ? replacements.get(key)
          : nodeFromStore(nodeStore, key),
        values: () => values,
      })
    }
    const callName = (block) => {
      if (!isRecord(block)) return ""
      if (block.kind === "tool-result") {
        return isRecord(block.call) && typeof block.call.name === "string" ? block.call.name : ""
      }
      return typeof block.name === "string" ? block.name : ""
    }
    const callID = (block) => isRecord(block) && typeof block.callId === "string" ? block.callId : ""
    const subCalls = (block) => isRecord(block) && Array.isArray(block.subCalls) ? block.subCalls : []
    const isSettled = (block) => isRecord(block) && block.kind === "tool-result"

    const isFoldableTree = (root, seen = new Set()) => {
      const id = callID(root)
      const name = callName(root)
      if (id.length === 0 || !foldableTools.has(name) || seen.has(id)) return false
      const nextSeen = new Set(seen)
      nextSeen.add(id)
      return subCalls(root).every((child) => isFoldableTree(child, nextSeen))
    }

    const turnNumber = (node) => {
      const location = isRecord(node) ? node.location : undefined
      if (!isRecord(location) || (location.kind !== "turn" && location.kind !== "step")) return undefined
      const turn = isRecord(location.turn) ? location.turn.turn : undefined
      return Number.isInteger(turn) ? turn : undefined
    }

    const toolRoot = (node) => {
      if (!isRecord(node) || node.kind !== "tool-call" || !isRecord(node.data)) return undefined
      return isRecord(node.data.root) ? node.data.root : undefined
    }

    const assistantBlocks = (node) => (
      isRecord(node)
      && node.kind === "assistant-step"
      && isRecord(node.data)
      && Array.isArray(node.data.blocks)
        ? node.data.blocks
        : undefined
    )

    const lastNonEmptyLine = (text) => {
      if (typeof text !== "string") return ""
      const lines = text.split(/\r?\n/)
      for (let index = lines.length - 1; index >= 0; index -= 1) {
        const line = lines[index].replace(/\s+/g, " ").trim()
        if (line.length > 0) return line
      }
      return ""
    }

    const hasIndependentAssistantContent = (node, blocks) => {
      if (node.data.status === "interrupted") return true
      return blocks.some((block) => {
        if (!isRecord(block)) return false
        if (block.kind === "text") return typeof block.text === "string" && block.text.trim().length > 0
        if (block.kind === "tool-call" || block.kind === "reasoning") return false
        return true
      })
    }

    const hasRenderableAssistantContent = (blocks) => blocks.some((block) => (
      isRecord(block) && block.kind !== "tool-call" && block.kind !== "reasoning"
    ))

    const thinkGroupForTurn = (keys, nodeStore) => {
      if (!Array.isArray(keys) || !isRecord(nodeStore) && !(nodeStore instanceof Map)) return undefined
      const getNode = typeof nodeStore.get === "function"
        ? (key) => nodeStore.get(key)
        : (key) => nodeStore[key]
      const members = []
      let latest
      for (const key of keys) {
        const node = getNode(key)
        if (!isRecord(node) || node.visibility !== "visible") continue
        const blocks = assistantBlocks(node)
        if (blocks === undefined) continue
        const reasoning = blocks.flatMap((block, blockIndex) => (
          isRecord(block) && block.kind === "reasoning"
            ? [{ blockIndex, text: typeof block.text === "string" ? block.text : "" }]
            : []
        ))
        if (reasoning.length === 0) continue
        members.push({ key, node, blocks })
        for (const candidate of reasoning) {
          const summary = lastNonEmptyLine(candidate.text)
          if (summary.length > 0) {
            latest = {
              blockIndex: candidate.blockIndex,
              key,
              node,
              summary,
              text: candidate.text,
            }
          }
        }
      }
      if (members.length === 0) return undefined
      return { latest, members }
    }

    const flattenUniqueCalls = (roots) => {
      const calls = []
      const seen = new Set()
      const visit = (block) => {
        const id = callID(block)
        if (id.length === 0 || seen.has(id)) return
        seen.add(id)
        calls.push(block)
        for (const child of subCalls(block)) visit(child)
      }
      for (const root of roots) visit(root)
      return calls
    }

    const groupForTurn = (keys, nodeStore) => {
      if (!Array.isArray(keys) || !isRecord(nodeStore) && !(nodeStore instanceof Map)) return undefined
      const getNode = typeof nodeStore.get === "function"
        ? (key) => nodeStore.get(key)
        : (key) => nodeStore[key]
      const members = []
      for (const key of keys) {
        const candidate = getNode(key)
        if (!isRecord(candidate) || candidate.visibility !== "visible") continue
        const root = toolRoot(candidate)
        if (root === undefined || !isFoldableTree(root)) continue
        members.push({ key, node: candidate, root })
      }
      if (members.length === 0) return undefined

      const calls = flattenUniqueCalls(members.map((member) => member.root))
      const counts = new Map(categoryOrder.map(([label]) => [label, 0]))
      let failures = 0
      let current
      let currentTime = -Infinity
      for (let index = 0; index < calls.length; index += 1) {
        const block = calls[index]
        const category = categoryByTool.get(callName(block))
        if (category !== undefined) counts.set(category, (counts.get(category) ?? 0) + 1)
        if (isSettled(block) && block.isError === true) failures += 1
        if (!isSettled(block)) {
          const time = Number.isFinite(block.time) ? block.time : index
          if (time >= currentTime) {
            current = block
            currentTime = time
          }
        }
      }
      return {
        anchorKey: members[0].key,
        calls,
        counts,
        current,
        failures,
        memberKeys: new Set(members.map((member) => member.key)),
      }
    }

    const projectedToolOrder = (snapshot, order, nodes) => {
      if (!isRecord(snapshot) || !isRecord(snapshot.chat)) return undefined
      const { locations } = snapshot.chat
      if (!Array.isArray(order) || typeof locations?.getTurn !== "function") return undefined
      const hidden = new Set()
      const visitedTurns = new Set()
      for (const key of order) {
        const node = typeof nodes?.get === "function" ? nodes.get(key) : nodes?.[key]
        const turn = turnNumber(node)
        if (turn === undefined || visitedTurns.has(turn)) continue
        visitedTurns.add(turn)
        const group = groupForTurn(locations.getTurn(turn), nodes)
        if (group === undefined) continue
        for (const memberKey of group.memberKeys) {
          if (memberKey !== group.anchorKey) hidden.add(memberKey)
        }
      }
      if (hidden.size === 0) return order
      return order.filter((key) => !hidden.has(key))
    }

    const projectThinkSnapshot = (snapshot) => {
      if (!isRecord(snapshot) || !isRecord(snapshot.chat)) return snapshot
      const { order, nodes } = snapshot.chat
      if (!Array.isArray(order) || !isRecord(nodes) && !(nodes instanceof Map)) return snapshot
      const getNode = (key) => nodeFromStore(nodes, key)
      const byTurn = new Map()
      for (const key of order) {
        const node = getNode(key)
        const turn = turnNumber(node)
        if (turn === undefined) continue
        let keys = byTurn.get(turn)
        if (keys === undefined) {
          keys = []
          byTurn.set(turn, keys)
        }
        keys.push(key)
      }

      const replacements = new Map()
      const hidden = new Set()
      for (const [turn, keys] of byTurn) {
        const group = thinkGroupForTurn(keys, nodes)
        if (group === undefined) continue
        for (const member of group.members) {
          const blocks = member.blocks.filter((block) => !isRecord(block) || block.kind !== "reasoning")
          const projection = group.latest?.key === member.key
            ? {
                summary: group.latest.summary,
                text: group.latest.text,
                turn,
                splitIndex: member.blocks
                  .slice(0, group.latest.blockIndex)
                  .filter((block) => !isRecord(block) || block.kind !== "reasoning")
                  .length,
              }
            : undefined
          const projectedNode = {
            ...member.node,
            data: {
              ...member.node.data,
              blocks,
            },
            ...(projection === undefined ? {} : { [thinkProjection]: projection }),
          }
          replacements.set(member.key, projectedNode)
          if (
            projection === undefined
            && !hasIndependentAssistantContent(member.node, blocks)
          ) {
            hidden.add(member.key)
          }
        }
      }
      if (replacements.size === 0) return snapshot

      const projectedNodes = projectedNodeStore(nodes, replacements)
      const projectedOrder = hidden.size === 0 ? order : order.filter((key) => !hidden.has(key))
      return {
        ...snapshot,
        chat: {
          ...snapshot.chat,
          nodes: projectedNodes,
          order: projectedOrder,
        },
      }
    }

    const projectSnapshot = (snapshot, collapseTools) => {
      const thinkProjected = projectThinkSnapshot(snapshot)
      if (!collapseTools || !isRecord(thinkProjected.chat)) return thinkProjected
      const order = projectedToolOrder(
        thinkProjected,
        thinkProjected.chat.order,
        thinkProjected.chat.nodes,
      )
      if (order === undefined || order === thinkProjected.chat.order) return thinkProjected
      return {
        ...thinkProjected,
        chat: {
          ...thinkProjected.chat,
          order,
        },
      }
    }

    const subscribeExpansion = (listener) => {
      expansionListeners.add(listener)
      return () => {
        expansionListeners.delete(listener)
      }
    }

    const toggleExpansion = (sessionId) => {
      if (expandedSessions.has(sessionId)) expandedSessions.delete(sessionId)
      else expandedSessions.add(sessionId)
      for (const listener of expansionListeners) listener()
    }

    const sessionExpansionKey = (sessionId) => String(sessionId)

    const isThinkExpanded = (sessionId, turn) => (
      expandedThinkTurns.get(sessionExpansionKey(sessionId))?.has(turn) === true
    )

    const subscribeThinkExpansion = (listener) => {
      thinkExpansionListeners.add(listener)
      return () => {
        thinkExpansionListeners.delete(listener)
      }
    }

    const toggleThinkExpansion = (sessionId, turn) => {
      const sessionIdKey = sessionExpansionKey(sessionId)
      let turns = expandedThinkTurns.get(sessionIdKey)
      if (turns === undefined) {
        turns = new Set()
        expandedThinkTurns.set(sessionIdKey, turns)
      }
      if (turns.has(turn)) turns.delete(turn)
      else turns.add(turn)
      if (turns.size === 0) expandedThinkTurns.delete(sessionIdKey)
      for (const listener of thinkExpansionListeners) listener()
    }

    const pruneExpansionState = (sessionId, snapshot) => {
      const sessionIdKey = sessionExpansionKey(sessionId)
      if (snapshot.removed === true) {
        expandedSessions.delete(sessionId)
        expandedSessions.delete(sessionIdKey)
        expandedThinkTurns.delete(sessionIdKey)
        return
      }
      const turns = expandedThinkTurns.get(sessionIdKey)
      if (turns === undefined || !isRecord(snapshot.chat) || !Array.isArray(snapshot.chat.order)) return
      const liveTurns = new Set()
      for (const key of snapshot.chat.order) {
        const turn = turnNumber(nodeFromStore(snapshot.chat.nodes, key))
        if (turn !== undefined) liveTurns.add(turn)
      }
      for (const turn of turns) {
        if (!liveTurns.has(turn)) turns.delete(turn)
      }
      if (turns.size === 0) expandedThinkTurns.delete(sessionIdKey)
    }

    const clearExpansionState = () => {
      expandedSessions.clear()
      expandedThinkTurns.clear()
    }

    const rawArguments = (block) => {
      if (!isRecord(block)) return ""
      if (block.kind === "tool-result") {
        return isRecord(block.call) && typeof block.call.argsRaw === "string" ? block.call.argsRaw : ""
      }
      return typeof block.argsRaw === "string" ? block.argsRaw : ""
    }

    const compactValue = (block) => {
      const raw = rawArguments(block).trim()
      if (raw.length === 0) return ""
      let parsed
      try {
        parsed = JSON.parse(raw)
      } catch {
        return ""
      }
      if (!isRecord(parsed)) return ""
      const keys = ["path", "file_path", "filePath", "command", "pattern", "query", "url"]
      const value = keys.map((key) => parsed[key]).find((candidate) => typeof candidate === "string")
      if (typeof value !== "string") return ""
      const singleLine = value.replace(/\s+/g, " ").trim()
      return singleLine.length > 88 ? `${singleLine.slice(0, 85)}…` : singleLine
    }

    const titleFor = (block) => categoryByTool.get(callName(block)) ?? (callName(block) || "Tool call")

    const compatibleSpec = (spec, kind) => (
      isRecord(spec) && spec.kind === kind && spec.scope === "session"
    )

    const registerOperationFolding = (ctx) => {
      if (
        !isRecord(ctx.slots)
        || typeof ctx.slots.inject !== "function"
        || typeof ctx.slots.register !== "function"
        || typeof ctx.slots.spec !== "function"
        || typeof ctx.slots.entries !== "function"
        || typeof ctx.slots.entriesOfSlot !== "function"
        || typeof ctx.slots.subscribe !== "function"
        || typeof ctx.slots.onEntryError !== "function"
      ) {
        return
      }

      const react = require("react")
      const { jsx, jsxs } = require("react/jsx-runtime")

      const currentRow = (block) => {
        if (block === undefined) return null
        const detail = compactValue(block)
        return jsxs("div", {
          "aria-live": "polite",
          "data-dsd-pancake-current-operation": "",
          style: {
            color: "var(--dsw-alias-label-secondary)",
            font: "var(--dsw-font-xs-13)",
            lineHeight: "20px",
            marginBottom: "2px",
          },
          children: [
            jsx("span", { "aria-hidden": true, children: "✎ " }),
            "当前：",
            titleFor(block),
            detail.length > 0 ? ` · ${detail}` : "",
          ],
        })
      }

      const summaryButton = (sessionId, expanded, group) => {
        const countParts = categoryOrder.flatMap(([label]) => {
          const count = group.counts.get(label) ?? 0
          return count > 0 ? [` · ${label} ${String(count)}`] : []
        })
        const label = expanded
          ? `收起当前会话的 ${String(group.calls.length)} 项操作`
          : `展开当前会话已折叠的 ${String(group.calls.length)} 项操作`
        return jsxs("button", {
          type: "button",
          "aria-expanded": expanded,
          "aria-label": label,
          "data-dsd-pancake-operation-summary": "",
          onClick: () => {
            toggleExpansion(sessionId)
          },
          style: {
            appearance: "none",
            background: "transparent",
            border: 0,
            color: "var(--dsw-alias-label-secondary)",
            cursor: "pointer",
            display: "block",
            font: "var(--dsw-font-xs-13)",
            lineHeight: "20px",
            margin: 0,
            maxWidth: "100%",
            minHeight: "24px",
            outlineOffset: "2px",
            padding: "2px 0",
            textAlign: "left",
            width: "100%",
          },
          children: [
            expanded ? "▾ " : "▸ ",
            expanded ? `${String(group.calls.length)} 项操作` : `已折叠 ${String(group.calls.length)} 项操作`,
            ...countParts,
            " · ",
            jsx("span", {
              style: group.failures > 0
                ? { color: "var(--dsw-alias-state-error-primary)" }
                : undefined,
              children: `失败 ${String(group.failures)}`,
            }),
          ],
        })
      }

      const sourceEntry = (entry) => (
        isRecord(entry)
        && isRecord(entry.options)
        && entry.component !== undefined
        && entry.component !== null
      )

      const routeRender = (render, routes, chain) => (name, owner, options) => {
        const route = routes.get(name)
        if (route === undefined) {
          throw new Error(`private alias has no route for child slot '${String(name)}'`)
        }
        const isChain = route.spec.kind === "chain"
        if (isChain !== chain || typeof render !== "function") {
          throw new Error(`private alias routed child slot '${String(name)}' through the wrong renderer`)
        }
        return render(route.alias, owner, options)
      }

      const delegatedProps = (props, routes) => {
        const delegated = { ...props }
        if (routes.size > 0) {
          delegated.renderSlot = routeRender(props.renderSlot, routes, false)
          if ([...routes.values()].some((route) => route.spec.kind === "chain")) {
            delegated.renderSlotChain = routeRender(props.renderSlotChain, routes, true)
          }
        }
        return delegated
      }

      const aliasDelegate = (source, routes) => {
        const PrivateAliasDelegate = (props) => (
          // 必须交给 React 创建 source element；直接调用函数会破坏 memo、forwardRef
          // 与 Hooks dispatcher（Hooks 调度器）的组件边界。
          jsx(source.component, delegatedProps(props, routes))
        )
        return PrivateAliasDelegate
      }

      const operationToolNode = (source, routes) => {
        const OperationToolNode = (props) => {
          const root = toolRoot(props.node)
          const turn = turnNumber(props.node)
          const keys = props.useSession((snapshot) => turn === undefined
            ? emptyKeys
            : snapshot.chat.locations.getTurn(turn))
          const nodeStore = props.useSession((snapshot) => snapshot.chat.nodes)
          const group = react.useMemo(() => groupForTurn(keys, nodeStore), [keys, nodeStore])
          const expanded = react.useSyncExternalStore(
            subscribeExpansion,
            () => expandedSessions.has(props.sessionId),
            () => false,
          )
          const original = () => jsx(source.component, delegatedProps(props, routes))
          if (
            root === undefined
            || !isFoldableTree(root)
            || turn === undefined
            || group === undefined
            || !group.memberKeys.has(props.node.key)
            || props.node.key !== group.anchorKey
          ) {
            return original()
          }

          return jsxs("div", {
            "data-dsd-pancake-operation-group": "",
            style: {
              margin: "4px 0",
              minWidth: 0,
            },
            children: [
              currentRow(group.current),
              summaryButton(props.sessionId, expanded, group),
              expanded ? original() : null,
            ],
          })
        }
        return OperationToolNode
      }

      const thinkIcon = () => jsx("svg", {
        "aria-hidden": true,
        fill: "none",
        height: 14,
        viewBox: "0 0 14 14",
        width: 14,
        children: jsx("path", {
          d: "M7 1.4c1.55 0 2.8 2.5 2.8 5.6S8.55 12.6 7 12.6 4.2 10.1 4.2 7 5.45 1.4 7 1.4Zm-4.85 2.8C2.93 2.86 5.72 3.03 8.4 4.58s4.24 3.87 3.46 5.22c-.78 1.34-3.57 1.17-6.25-.38S1.37 5.55 2.15 4.2Zm9.7 0c.78 1.35-.78 3.68-3.46 5.22s-5.47 1.72-6.25.38C1.37 8.45 2.93 6.13 5.6 4.58s5.47-1.72 6.25-.38Z",
          stroke: "currentColor",
          strokeWidth: 1.1,
        }),
      })

      const operationAssistantNode = (source, routes) => {
        const OperationAssistantNode = (props) => {
          const projection = isRecord(props.node) ? props.node[thinkProjection] : undefined
          const original = (blocks = props.node.data.blocks, status = props.node.data.status) => (
            jsx(source.component, delegatedProps({
              ...props,
              node: {
                ...props.node,
                data: {
                  ...props.node.data,
                  blocks,
                  status,
                },
              },
            }, routes))
          )
          const expanded = react.useSyncExternalStore(
            subscribeThinkExpansion,
            () => isRecord(projection) && isThinkExpanded(props.sessionId, projection.turn),
            () => false,
          )
          if (!isRecord(projection)) return original()

          const blocks = props.node.data.blocks
          const splitIndex = Math.max(0, Math.min(projection.splitIndex, blocks.length))
          const before = blocks.slice(0, splitIndex)
          const after = blocks.slice(splitIndex)
          const beforeView = hasRenderableAssistantContent(before)
            ? original(before, props.node.data.status === "interrupted" ? "settled" : props.node.data.status)
            : null
          const afterView = hasRenderableAssistantContent(after)
            || props.node.data.status === "interrupted"
            ? original(after)
            : null

          return jsxs("div", {
            "data-dsd-pancake-think-group": "",
            style: {
              color: "var(--dsw-alias-label-secondary)",
              display: "flex",
              flexDirection: "column",
              gap: "16px",
              minWidth: 0,
            },
            children: [
              beforeView,
              jsxs("div", {
                children: [
                  jsxs("button", {
                type: "button",
                "aria-expanded": expanded,
                "aria-label": expanded
                  ? `收起最新 Think：${projection.summary}`
                  : `展开最新 Think：${projection.summary}`,
                "data-dsd-pancake-think-summary": "",
                onClick: () => {
                  toggleThinkExpansion(props.sessionId, projection.turn)
                },
                style: {
                  alignItems: "center",
                  appearance: "none",
                  background: "transparent",
                  border: 0,
                  color: "inherit",
                  cursor: "pointer",
                  display: "flex",
                  font: "var(--dsw-font-xs-13)",
                  gap: "8px",
                  lineHeight: "24px",
                  margin: 0,
                  maxWidth: "100%",
                  minHeight: "24px",
                  outlineOffset: "2px",
                  padding: 0,
                  textAlign: "left",
                  width: "100%",
                },
                children: [
                  jsx("span", {
                    style: {
                      color: "var(--dsw-alias-label-secondary)",
                      display: "inline-flex",
                      flex: "0 0 auto",
                    },
                    children: thinkIcon(),
                  }),
                  jsx("span", {
                    style: { flex: "0 0 auto" },
                    children: "Think",
                  }),
                  jsx("span", {
                    "aria-hidden": true,
                    style: {
                      color: "var(--dsw-alias-label-caption)",
                      flex: "0 0 auto",
                    },
                    children: "·",
                  }),
                  jsx("span", {
                    style: {
                      color: "var(--dsw-alias-label-tertiary)",
                      flex: "1 1 auto",
                      minWidth: 0,
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                      whiteSpace: "nowrap",
                    },
                    children: projection.summary,
                  }),
                  jsx("span", {
                    "aria-hidden": true,
                    style: {
                      color: "var(--dsw-alias-label-secondary)",
                      flex: "0 0 auto",
                      transform: expanded ? "rotate(180deg)" : undefined,
                    },
                    children: "⌄",
                  }),
                ],
                  }),
                  expanded ? jsx("div", {
                    "data-dsd-pancake-think-body": "",
                    style: {
                      color: "var(--dsw-alias-label-tertiary)",
                      fontSize: "14px",
                      lineHeight: "24px",
                      padding: "4px 0 4px 22px",
                      whiteSpace: "pre-wrap",
                      wordBreak: "break-word",
                    },
                    children: projection.text,
                  }) : null,
                ],
              }),
              afterView,
            ],
          })
        }
        return OperationAssistantNode
      }

      const operationChatView = (source, routes) => {
        const OperationChatView = (props) => {
          const expanded = react.useSyncExternalStore(
            subscribeExpansion,
            () => expandedSessions.has(props.sessionId),
            () => false,
          )
          const useProjectedSession = react.useMemo(() => {
            const cache = new WeakMap()
            return (selector, equality) => props.useSession((snapshot) => {
              if (!isRecord(snapshot)) return selector(snapshot)
              pruneExpansionState(props.sessionId, snapshot)
              let projected = cache.get(snapshot)
              if (projected === undefined) {
                projected = projectSnapshot(snapshot, !expanded)
                cache.set(snapshot, projected)
              }
              return selector(projected)
            }, equality)
          }, [expanded, props.useSession])
          return jsx(source.component, delegatedProps({
            ...props,
            useSession: useProjectedSession,
          }, routes))
        }
        return OperationChatView
      }

      const operationHeader = (source, routes) => {
        const OperationHeader = (props) => {
          const views = react.useMemo(() => ({
            ...props.views,
            list: () => {
              const rawEntries = ctx.slots.entries(officialViewSlot).filter((entry) => (
                sourceEntry(entry) && typeof entry.options.id === "string"
              ))
              const rawTabs = props.views.list()
              const tabByEntry = new Map(rawEntries.map((entry, index) => [entry, rawTabs[index]]))
              const seen = new Set()
              return ctx.slots.entriesOfSlot(officialViewSlot).flatMap((winner) => {
                const id = winner.options.id
                if (typeof id !== "string" || seen.has(id)) return []
                seen.add(id)
                const exact = tabByEntry.get(winner)
                if (isRecord(exact) && exact.id === id) return [exact]
                const fallback = rawTabs.find((tab) => isRecord(tab) && tab.id === id)
                return fallback === undefined ? [] : [fallback]
              })
            },
          }), [props.views])
          return jsx(source.component, delegatedProps({ ...props, views }, routes))
        }
        return OperationHeader
      }

      const copyEntryOptions = (source, name, children) => {
        const options = {
          ...source.options,
          name,
        }
        delete options.children
        delete options.inject
        delete options.locale
        delete options.select
        delete options.store
        if (children !== undefined) options.children = children
        if (source.inject !== undefined) options.inject = source.inject
        if (source.locale !== undefined) options.locale = source.locale
        if (source.select !== undefined) options.select = source.select
        if (source.store !== undefined) options.store = source.store
        return options
      }

      ctx.slots.inject(officialViewSlot, () => {
        if (renderFailureDisabled) return undefined
        if (!compatibleSpec(ctx.slots.spec(officialViewSlot), "list")) return undefined
        return ctx.slots.inject(officialHeaderSlot, () => {
          if (renderFailureDisabled) return undefined
          if (!compatibleSpec(ctx.slots.spec(officialHeaderSlot), "single")) return undefined
          return ctx.slots.inject(officialChatNodeSlot, () => {
            if (renderFailureDisabled) return undefined
            if (!compatibleSpec(ctx.slots.spec(officialChatNodeSlot), "keyed")) return undefined
            return ctx.slots.inject(officialToolviewSlot, () => {
              if (renderFailureDisabled) return undefined
              if (!compatibleSpec(ctx.slots.spec(officialToolviewSlot), "keyed")) return undefined

              const pluginComponents = new WeakSet()
              const retiredSources = new WeakSet()
              const sourcePriority = (entry) => entry.options.priority ?? 0
              const allocateRootPriority = (slot, source, sameCell) => {
                const livePriority = sourcePriority(source)
                if (!Number.isFinite(livePriority)) return undefined
                const occupied = []
                for (const entry of ctx.slots.entries(slot)) {
                  if (!sourceEntry(entry) || pluginComponents.has(entry.component) || !sameCell(entry)) continue
                  const priority = sourcePriority(entry)
                  if (!Number.isFinite(priority)) return undefined
                  occupied.push(priority)
                }
                const floor = occupied.length === 0 ? livePriority : Math.min(livePriority, ...occupied)
                const candidate = floor - 1
                if (
                  !Number.isFinite(candidate)
                  || candidate >= floor
                  || occupied.includes(candidate)
                ) {
                  return undefined
                }
                return candidate
              }
              const sourceWinner = (slot, accepts) => ctx.slots.entriesOfSlot(slot).find((entry) => (
                sourceEntry(entry)
                && !pluginComponents.has(entry.component)
                && !retiredSources.has(entry)
                && accepts(entry)
              ))
              const selectRootSources = () => ({
                header: sourceWinner(officialHeaderSlot, () => true),
                view: sourceWinner(officialViewSlot, (entry) => (
                  entry.options.id === "chat"
                  && isRecord(entry.children)
                  && compatibleSpec(entry.children[officialChatNodeSlot], "keyed")
                )),
              })
              const rootCandidates = () => ({
                header: ctx.slots.entries(officialHeaderSlot).filter((entry) => (
                  sourceEntry(entry)
                  && !pluginComponents.has(entry.component)
                  && !retiredSources.has(entry)
                )),
                view: ctx.slots.entries(officialViewSlot).filter((entry) => (
                  sourceEntry(entry)
                  && !pluginComponents.has(entry.component)
                  && !retiredSources.has(entry)
                  && entry.options.id === "chat"
                )),
              })
              const sameCandidates = (left, right) => (
                left !== undefined
                && left.header.length === right.header.length
                && left.view.length === right.view.length
                && left.header.every((entry, index) => entry === right.header[index])
                && left.view.every((entry, index) => entry === right.view[index])
              )
              let aliasGeneration = 0
              const buildPrivateTree = () => {
                aliasGeneration += 1
                let aliasIndex = 0
                const sourceSlots = new Set([officialViewSlot, officialHeaderSlot])
                const rootSources = selectRootSources()
                if (rootSources.view === undefined || rootSources.header === undefined) {
                  throw new Error("official conversation roots are unavailable")
                }
                const rootPriorities = {
                  header: allocateRootPriority(officialHeaderSlot, rootSources.header, () => true),
                  view: allocateRootPriority(
                    officialViewSlot,
                    rootSources.view,
                    (entry) => entry.options.id === rootSources.view.options.id,
                  ),
                }
                if (rootPriorities.view === undefined || rootPriorities.header === undefined) {
                  throw new Error("official conversation roots have no collision-free priority")
                }

                const visit = (source, sourceSlot, targetSlot, ancestors, depth, rootKind, rootPriority) => {
                  if (depth > 32) throw new Error("private alias tree exceeded 32 levels")
                  const routes = new Map()
                  const aliasChildren = {}
                  const descendants = []
                  if (source.children !== undefined) {
                    if (!isRecord(source.children)) throw new Error("source entry has invalid child declarations")
                    for (const [childName, spec] of Object.entries(source.children)) {
                      if (!isRecord(spec) || typeof spec.kind !== "string" || ancestors.has(childName)) {
                        throw new Error(`source child slot '${childName}' cannot be mirrored safely`)
                      }
                      const alias = `${privateAliasPrefix}.${String(aliasGeneration)}.${String(aliasIndex)}`
                      aliasIndex += 1
                      aliasChildren[alias] = spec
                      routes.set(childName, { alias, spec })
                      sourceSlots.add(childName)
                      const nextAncestors = new Set(ancestors)
                      nextAncestors.add(childName)
                      for (const childSource of ctx.slots.entriesOfSlot(childName).filter(sourceEntry)) {
                        descendants.push(visit(childSource, childName, alias, nextAncestors, depth + 1))
                      }
                    }
                  }
                  const children = routes.size === 0 ? undefined : aliasChildren
                  let component
                  if (rootKind === "view") component = operationChatView(source, routes)
                  else if (rootKind === "header") component = operationHeader(source, routes)
                  else if (sourceSlot === officialChatNodeSlot && source.options.key === "tool-call") {
                    component = operationToolNode(source, routes)
                  } else if (sourceSlot === officialChatNodeSlot && source.options.key === "assistant-step") {
                    component = operationAssistantNode(source, routes)
                  } else component = aliasDelegate(source, routes)
                  pluginComponents.add(component)
                  const options = copyEntryOptions(source, targetSlot, children)
                  if (rootKind !== undefined) options.priority = rootPriority
                  return { component, descendants, options }
                }

                return {
                  roots: [
                    visit(
                      rootSources.view,
                      officialViewSlot,
                      officialViewSlot,
                      new Set([officialViewSlot]),
                      1,
                      "view",
                      rootPriorities.view,
                    ),
                    visit(
                      rootSources.header,
                      officialHeaderSlot,
                      officialHeaderSlot,
                      new Set([officialHeaderSlot]),
                      1,
                      "header",
                      rootPriorities.header,
                    ),
                  ],
                  candidates: rootCandidates(),
                  sourceSlots,
                }
              }

              const sourceSubscriptions = new Map()
              let currentGeneration
              let disposeEntryErrors
              let disabled = false
              let stopped = false
              let rebuilding = false
              let rebuildQueued = false

              const safelyDispose = (dispose) => {
                try {
                  if (typeof dispose === "function") dispose()
                } catch {
                  // 回滚必须继续清理余下贡献，不能因单个 disposer 失败停在半状态。
                }
              }

              const disposeGeneration = (strict) => {
                const generation = currentGeneration
                currentGeneration = undefined
                if (generation === undefined) return
                let firstError
                for (const dispose of [...generation.disposers].reverse()) {
                  try {
                    dispose()
                  } catch (error) {
                    if (firstError === undefined) firstError = error
                  }
                }
                if (strict && firstError !== undefined) throw firstError
              }

              const disposeSourceSubscriptions = () => {
                for (const unsubscribe of sourceSubscriptions.values()) safelyDispose(unsubscribe)
                sourceSubscriptions.clear()
              }

              const disable = () => {
                if (disabled || stopped) return
                disabled = true
                disposeSourceSubscriptions()
                const stopWatchingErrors = disposeEntryErrors
                disposeEntryErrors = undefined
                safelyDispose(stopWatchingErrors)
                disposeGeneration(false)
                clearExpansionState()
              }

              const shutdown = () => {
                if (stopped) return
                stopped = true
                disposeSourceSubscriptions()
                const stopWatchingErrors = disposeEntryErrors
                disposeEntryErrors = undefined
                safelyDispose(stopWatchingErrors)
                disposeGeneration(false)
                clearExpansionState()
              }

              const reconcileSourceSubscriptions = (sourceSlots, requestRebuild) => {
                const added = []
                try {
                  for (const slot of sourceSlots) {
                    if (sourceSubscriptions.has(slot)) continue
                    const unsubscribe = ctx.slots.subscribe(slot, () => requestRebuild(slot))
                    sourceSubscriptions.set(slot, unsubscribe)
                    added.push(slot)
                  }
                  for (const [slot, unsubscribe] of [...sourceSubscriptions]) {
                    if (sourceSlots.has(slot)) continue
                    unsubscribe()
                    sourceSubscriptions.delete(slot)
                  }
                } catch (error) {
                  for (const slot of added) {
                    safelyDispose(sourceSubscriptions.get(slot))
                    sourceSubscriptions.delete(slot)
                  }
                  throw error
                }
              }

              const installTree = (tree) => {
                const generation = {
                  components: new Set(),
                  candidates: tree.candidates,
                  disposers: [],
                  slots: new Set(),
                }
                currentGeneration = generation
                const register = (options, component) => {
                  const dispose = ctx.slots.register(options, component)
                  generation.disposers.push(dispose)
                  generation.components.add(component)
                  generation.slots.add(options.name)
                }
                const registerNode = (node) => {
                  register(node.options, node.component)
                  for (const descendant of node.descendants) registerNode(descendant)
                }
                for (const root of tree.roots) registerNode(root)
              }

              const requestRebuild = (changedSlot) => {
                if (disabled || stopped) return
                if (rebuilding) {
                  rebuildQueued = true
                  return
                }
                if (
                  (changedSlot === officialViewSlot || changedSlot === officialHeaderSlot)
                  && sameCandidates(currentGeneration?.candidates, rootCandidates())
                ) {
                  // SlotRegistry 的 subscribe 是 microtask-batched（微任务合并）的；
                  // 本插件注册/释放 root shadow 引发的通知会在当前 rebuild 后到达，
                  // 此时 raw source fingerprint 未变化，直接忽略，避免自激循环。
                  return
                }
                rebuilding = true
                do {
                  rebuildQueued = false
                  try {
                    // remove-before-add：先释放整棵 shadow tree，避免 source swap 在同一
                    // cell + priority 上与旧镜像形成 duplicate cell（重复单元格）。
                    // 同时保证随后的 entriesOfSlot 只观察公开 live winner，不会把
                    // 本插件自己的 shadow 当成 source。
                    disposeGeneration(true)
                    const tree = buildPrivateTree()
                    installTree(tree)
                    reconcileSourceSubscriptions(tree.sourceSlots, requestRebuild)
                  } catch {
                    disable()
                  }
                } while (rebuildQueued && !disabled && !stopped)
                rebuilding = false
              }

              try {
                disposeEntryErrors = ctx.slots.onEntryError((slot, entry, _error, info) => {
                  const generation = currentGeneration
                  if (entry !== undefined && entry !== null && info?.abdicated === true) {
                    retiredSources.add(entry)
                  }
                  if (
                    generation === undefined
                    || !generation.slots.has(slot)
                    || !generation.components.has(entry?.component)
                  ) {
                    return
                  }
                  // 一次真实渲染异常就让本轮 takeover 永久退场；DSH 已把异常项交给
                  // boundary（错误边界）处理，这里同步撤销整棵私有树，让 shipped
                  // winner（随 DSH 发布的获胜 renderer）立即接管，避免留下 dead cell。
                  renderFailureDisabled = true
                  disable()
                })
                requestRebuild()
              } catch {
                disable()
              }
              return shutdown
            })
          })
        })
      })
    }

    const apply = (ctx) => {
      registerOperationFolding(ctx)
    }

    exports.apply = apply
    exports.inject = ["slots"]
    return module.exports
  },
})
