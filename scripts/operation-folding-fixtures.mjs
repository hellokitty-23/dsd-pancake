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
const assistantNode = (key, turn, blocks, status = "settled", anchorSeq = 0) => ({
  key,
  kind: "assistant-step",
  target: "chat",
  anchorSeq,
  visibility: "visible",
  location: {
    kind: "step",
    turn: { turn },
    step: { step: anchorSeq + 1 },
  },
  data: {
    status,
    turn,
    step: anchorSeq + 1,
    blocks,
    time: anchorSeq,
  },
})
const passiveNode = (key, kind, turn, anchorSeq = 0) => ({
  key,
  kind,
  target: "chat",
  anchorSeq,
  visibility: "visible",
  location: {
    kind: "turn",
    turn: { turn },
  },
  data: { preserved: true },
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
class PrototypeChatNodeStore {
  #nodes
  #values

  constructor(nodes) {
    this.#values = Array.from(nodes)
    this.#nodes = new Map(this.#values.map((node) => [node.key, node]))
  }

  get(key) {
    return this.#nodes.get(key)
  }

  values() {
    return this.#values
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

export {
  PrototypeChatNodeStore,
  assistantNode,
  ownerFor,
  passiveNode,
  running,
  settled,
  snapshotFor,
  toolNode,
}
