import { spawnSync } from "node:child_process"
import {
  copyFile,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, isAbsolute, resolve } from "node:path"
import { fileURLToPath } from "node:url"

import { privatePlugins, requiredPluginFiles } from "./private-plugin-catalog.mjs"

const expect = (condition, message) => {
  if (!condition) throw new Error(message)
}

const projectRoot = fileURLToPath(new URL("..", import.meta.url))
const verifierPath = fileURLToPath(import.meta.url)
const runtimeKindSource = "Sources/DSHDesktopCore/State/PrivatePluginLaunchState.swift"
const runtimeControllerSource = "Sources/DSHDesktopApp/PrivatePluginController.swift"
const moduleEvaluationTimeoutMilliseconds = 2_000
const sandboxProcessTimeoutMilliseconds = 5_000
const maximumModuleBytes = 1_000_000
const nodePermissionFlag = process.allowedNodeEnvironmentFlags.has("--permission")
  ? "--permission"
  : process.allowedNodeEnvironmentFlags.has("--experimental-permission")
    ? "--experimental-permission"
    : undefined
expect(nodePermissionFlag !== undefined, "当前 Node.js 不支持 client sandbox 所需的 permission model")

// client bundle 不在 metadata verifier 的宿主进程内执行。子进程没有环境变量、
// 文件、网络、子进程或 worker 权限；VM 还关闭动态 code generation，并对入口求值
// 与 factory 求值分别设置同步超时。即使待验证文件被篡改，也不能继承 verifier 的权限。
const clientSandboxProgram = String.raw`
import { createContext, Script } from "node:vm"

const chunks = []
for await (const chunk of process.stdin) chunks.push(chunk)
const input = JSON.parse(Buffer.concat(chunks).toString("utf8"))
const timeout = input.timeout
const context = createContext(Object.create(null), {
  codeGeneration: { strings: false, wasm: false },
  microtaskMode: "afterEvaluate",
  name: "dsd-private-plugin-metadata",
})

const bootstrapSource = [
  "globalThis.window = Object.create(null)",
  "globalThis.__dsdDefinition = undefined",
  "window.__ModuleLoader__ = Object.freeze({",
  "  load(definition) {",
  "    if (globalThis.__dsdDefinition !== undefined) throw new Error('client 只能注册一个 module')",
  "    globalThis.__dsdDefinition = definition",
  "  },",
  "})",
].join("\n")
new Script(bootstrapSource, { filename: "metadata-bootstrap.js" }).runInContext(context, { timeout })

new Script(input.source, { filename: input.filename }).runInContext(context, { timeout })
const probeSource = [
  "(() => {",
  "  const definition = globalThis.__dsdDefinition",
  "  if (definition === null || typeof definition !== 'object' || Array.isArray(definition)) throw new Error('client loader definition 必须是对象')",
  "  if (JSON.stringify(Object.keys(definition).sort()) !== JSON.stringify(['factory', 'id'])) throw new Error('client loader definition 字段不精确')",
  "  if (typeof definition.id !== 'string' || typeof definition.factory !== 'function') throw new Error('client loader definition 的 id/factory 无效')",
  "  const exports = definition.factory(() => Object.freeze(Object.create(null)))",
  "  if (exports === null || typeof exports !== 'object' || Array.isArray(exports)) throw new Error('client exports 必须是对象')",
  "  if (JSON.stringify(Object.keys(exports).sort()) !== JSON.stringify(['apply', 'inject'])) throw new Error('client exports 字段不精确')",
  "  if (typeof exports.apply !== 'function' || !Array.isArray(exports.inject)) throw new Error('client exports 的 apply/inject 无效')",
  "  return JSON.stringify({ id: definition.id, inject: Array.from(exports.inject) })",
  "})()",
].join("\n")
const result = new Script(probeSource, { filename: "metadata-probe.js" }).runInContext(context, { timeout })
process.stdout.write(result)
`

const parseArguments = (args) => {
  if (args.length === 0) return { mode: "source", root: projectRoot, selfTest: false }
  if (args.length === 1 && args[0] === "--self-test") {
    return { mode: "source", root: projectRoot, selfTest: true }
  }
  expect(
    args.length === 2,
    "用法：node scripts/verify-private-plugin-metadata.mjs [--source-root PATH|--bundle-resources PATH|--self-test]",
  )
  expect(args[0] === "--source-root" || args[0] === "--bundle-resources", "未知的私有插件 metadata 校验参数")
  expect(isAbsolute(args[1]), "私有插件 metadata 校验根目录必须是绝对路径")
  return {
    mode: args[0] === "--bundle-resources" ? "bundle" : "source",
    root: resolve(args[1]),
    selfTest: false,
  }
}

const regularFile = async (path, label) => {
  let information
  try {
    information = await lstat(path)
  } catch {
    throw new Error(`${label} 缺失：${path}`)
  }
  expect(information.isFile() && !information.isSymbolicLink(), `${label} 必须是普通文件且不能是符号链接：${path}`)
}

const exactKeys = (value, expected, label) => {
  expect(value !== null && typeof value === "object" && !Array.isArray(value), `${label} 必须是对象`)
  expect(
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort()),
    `${label} 字段不精确`,
  )
}

const verifyPackage = (manifest, plugin) => {
  exactKeys(
    manifest,
    ["name", "version", "private", "type", "main", "exports", "dsh", "license"],
    `${plugin.label} package.json`,
  )
  expect(manifest.name === plugin.packageName, `${plugin.label} package name 不正确`)
  expect(typeof manifest.version === "string" && /^\d+\.\d+\.\d+$/.test(manifest.version), `${plugin.label} version 不是三段数字版本`)
  expect(manifest.private === true, `${plugin.label} 必须保持 private=true`)
  expect(manifest.type === "module", `${plugin.label} type 必须是 module`)
  expect(manifest.main === "./lib/index.js", `${plugin.label} main 不正确`)
  exactKeys(manifest.exports, [".", "./client", "./package.json"], `${plugin.label} exports`)
  expect(manifest.exports["."] === "./lib/index.js", `${plugin.label} 根 export 不正确`)
  expect(manifest.exports["./client"] === "./lib/client.js", `${plugin.label} client export 不正确`)
  expect(manifest.exports["./package.json"] === "./package.json", `${plugin.label} package export 不正确`)
  exactKeys(manifest.dsh, ["client"], `${plugin.label} dsh`)
  exactKeys(manifest.dsh.client, ["platform", "inject"], `${plugin.label} dsh.client`)
  expect(manifest.dsh.client.platform === "web", `${plugin.label} client platform 必须是 web`)
  expect(
    JSON.stringify(manifest.dsh.client.inject) === JSON.stringify(plugin.inject),
    `${plugin.label} client inject 与清单不一致`,
  )
  expect(manifest.license === "MIT", `${plugin.label} license 必须是 MIT`)
}

const verifyPatch = (source, plugin) => {
  const significantLines = source
    .split(/\r?\n/)
    .filter((line) => line.trim() !== "" && !line.trimStart().startsWith("#"))
  const expectedLines = [
    "- insert:",
    `    - id: ${plugin.patchId}`,
    `      name: '${plugin.packageName}'`,
  ]
  expect(
    JSON.stringify(significantLines) === JSON.stringify(expectedLines),
    `${plugin.label} cordis.patch.yml 必须精确插入清单声明的单一 package`,
  )
}

const verifyJavaScriptSyntax = (path, label) => {
  const result = spawnSync(process.execPath, ["--check", path], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: sandboxProcessTimeoutMilliseconds,
    maxBuffer: 1_000_000,
  })
  expect(result.error === undefined, `${label} 无法启动 JavaScript 语法检查：${result.error?.message ?? "unknown"}`)
  expect(
    result.status === 0,
    `${label} 不是可解析的 JavaScript：${(result.stderr || result.stdout).trim()}`,
  )
}

const verifyHostModule = async (path, plugin) => {
  verifyJavaScriptSyntax(path, `${plugin.label} lib/index.js`)
  const source = await readFile(path, "utf8")
  expect(Buffer.byteLength(source, "utf8") <= maximumModuleBytes, `${plugin.label} lib/index.js 超过大小上限`)
  const significantLines = source
    .split(/\r\n|[\n\r\u2028\u2029]/)
    .map((line) => line.trim())
    .filter((line) => line !== "" && !line.startsWith("//"))
  expect(
    JSON.stringify(significantLines) === JSON.stringify(["export function apply() {}"]),
    `${plugin.label} lib/index.js 必须是只有注释与 export function apply() {} 的精确 no-op host 入口`,
  )
}

const verifyClientModule = async (path, plugin) => {
  verifyJavaScriptSyntax(path, `${plugin.label} lib/client.js`)
  const source = await readFile(path, "utf8")
  expect(Buffer.byteLength(source, "utf8") <= maximumModuleBytes, `${plugin.label} lib/client.js 超过大小上限`)
  const result = spawnSync(process.execPath, [
    nodePermissionFlag,
    "--disable-proto=throw",
    "--max-old-space-size=64",
    "--input-type=module",
    "--eval",
    clientSandboxProgram,
  ], {
    cwd: tmpdir(),
    encoding: "utf8",
    env: {},
    input: JSON.stringify({
      filename: `${plugin.id}/lib/client.js`,
      source,
      timeout: moduleEvaluationTimeoutMilliseconds,
    }),
    stdio: ["pipe", "pipe", "pipe"],
    timeout: sandboxProcessTimeoutMilliseconds,
    maxBuffer: 1_000_000,
  })
  expect(result.error === undefined, `${plugin.label} client sandbox 无法完成：${result.error?.message ?? "unknown"}`)
  expect(
    result.status === 0,
    `${plugin.label} client 无法在受限 sandbox 中求值：${(result.stderr || result.stdout).trim()}`,
  )
  let metadata
  try {
    metadata = JSON.parse(result.stdout)
  } catch (error) {
    throw new Error(`${plugin.label} client sandbox 返回了无效结果：${error instanceof Error ? error.message : String(error)}`)
  }
  exactKeys(metadata, ["id", "inject"], `${plugin.label} client sandbox metadata`)
  expect(metadata.id === plugin.packageName, `${plugin.label} client module id 与清单不一致`)
  expect(JSON.stringify(metadata.inject) === JSON.stringify(plugin.inject), `${plugin.label} client inject 与清单不一致`)
}

const declarationBody = (source, pattern, label) => {
  const match = pattern.exec(source)
  expect(match !== null, `${label} 声明缺失`)
  const opening = source.indexOf("{", match.index + match[0].length)
  expect(opening >= 0, `${label} 没有 body`)

  let depth = 0
  let lineComment = false
  let blockCommentDepth = 0
  let string = false
  let escaped = false
  for (let index = opening; index < source.length; index += 1) {
    const character = source[index]
    const next = source[index + 1]
    if (lineComment) {
      if (character === "\n") lineComment = false
      continue
    }
    if (blockCommentDepth > 0) {
      if (character === "/" && next === "*") {
        blockCommentDepth += 1
        index += 1
      } else if (character === "*" && next === "/") {
        blockCommentDepth -= 1
        index += 1
      }
      continue
    }
    if (string) {
      if (escaped) {
        escaped = false
      } else if (character === "\\") {
        escaped = true
      } else if (character === "\"") {
        string = false
      }
      continue
    }
    if (character === "/" && next === "/") {
      lineComment = true
      index += 1
      continue
    }
    if (character === "/" && next === "*") {
      blockCommentDepth = 1
      index += 1
      continue
    }
    if (character === "\"") {
      string = true
      continue
    }
    if (character === "{") depth += 1
    if (character === "}") {
      depth -= 1
      if (depth === 0) return source.slice(opening + 1, index)
    }
  }
  throw new Error(`${label} body 未闭合`)
}

const exactMatches = (source, pattern) => [...source.matchAll(pattern)].map((match) => match[1])
const escapeRegularExpression = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")

const swiftCodeOnly = (source) => {
  let result = ""
  let lineComment = false
  let blockCommentDepth = 0
  let stringDelimiterLength = 0
  let escaped = false
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index]
    const next = source[index + 1]
    const nextTwo = source.slice(index, index + 3)
    if (lineComment) {
      if (character === "\n" || character === "\r") {
        lineComment = false
        result += character
      } else {
        result += " "
      }
      continue
    }
    if (blockCommentDepth > 0) {
      if (character === "/" && next === "*") {
        blockCommentDepth += 1
        result += "  "
        index += 1
      } else if (character === "*" && next === "/") {
        blockCommentDepth -= 1
        result += "  "
        index += 1
      } else {
        result += character === "\n" || character === "\r" ? character : " "
      }
      continue
    }
    if (stringDelimiterLength > 0) {
      if (stringDelimiterLength === 3 && nextTwo === "\"\"\"") {
        result += "   "
        index += 2
        stringDelimiterLength = 0
      } else if (stringDelimiterLength === 1 && !escaped && character === "\"") {
        result += " "
        stringDelimiterLength = 0
      } else {
        result += character === "\n" || character === "\r" ? character : " "
        escaped = !escaped && character === "\\"
        if (character !== "\\") escaped = false
      }
      continue
    }
    if (character === "/" && next === "/") {
      lineComment = true
      result += "  "
      index += 1
    } else if (character === "/" && next === "*") {
      blockCommentDepth = 1
      result += "  "
      index += 1
    } else if (nextTwo === "\"\"\"") {
      stringDelimiterLength = 3
      result += "   "
      index += 2
    } else if (character === "\"") {
      stringDelimiterLength = 1
      escaped = false
      result += " "
    } else {
      result += character
    }
  }
  expect(blockCommentDepth === 0 && stringDelimiterLength === 0, "PrivatePluginKind 包含未闭合的注释或字符串")
  return result
}

const canonicalTopLevelEnumCases = (body, label) => {
  const cases = []
  let depth = 0
  for (const line of swiftCodeOnly(body).split(/\r\n|[\n\r\u2028\u2029]/)) {
    const depthAtLineStart = depth
    if (depthAtLineStart === 0 && /\bcase\b/.test(line)) {
      const match = /^\s*case\s+([A-Za-z_][A-Za-z0-9_]*)\s*$/.exec(line)
      expect(
        match !== null,
        `${label} case 必须每行精确声明一个名称，禁止 raw value、逗号、分号或同一行附加语句：${line.trim()}`,
      )
      cases.push(match[1])
    }
    for (const character of line) {
      if (character === "{") depth += 1
      if (character === "}") depth -= 1
      expect(depth >= 0, `${label} body 的大括号层级无效`)
    }
  }
  expect(depth === 0, `${label} body 的大括号层级未闭合`)
  return cases
}

const verifySwiftPluginType = async (root, plugin) => {
  const path = resolve(root, plugin.swiftSource)
  await regularFile(path, `${plugin.label} Swift runtime source`)
  const source = await readFile(path, "utf8")
  const body = declarationBody(
    source,
    new RegExp(`\\bpublic\\s+struct\\s+${escapeRegularExpression(plugin.swiftType)}\\b`),
    plugin.swiftType,
  )
  const constants = [...body.matchAll(/\bpublic\s+static\s+let\s+(packageName|resourcesDirectoryName)\s*=\s*"([^"]+)"/g)]
  const values = Object.fromEntries(constants.map((match) => [match[1], match[2]]))
  expect(constants.length === 2 && Object.keys(values).length === 2, `${plugin.swiftType} 必须精确声明 packageName 与 resourcesDirectoryName`)
  expect(values.packageName === plugin.packageName, `${plugin.swiftType}.packageName 与清单不一致`)
  expect(values.resourcesDirectoryName === plugin.resourceDirectory, `${plugin.swiftType}.resourcesDirectoryName 与清单不一致`)
}

const preparationMethod = (swiftKind) => `prepare${swiftKind[0].toUpperCase()}${swiftKind.slice(1)}`

const verifySwiftRuntime = async (root) => {
  const kindPath = resolve(root, runtimeKindSource)
  const controllerPath = resolve(root, runtimeControllerSource)
  await regularFile(kindPath, "PrivatePluginKind runtime source")
  await regularFile(controllerPath, "PrivatePluginController runtime source")

  const kindSource = await readFile(kindPath, "utf8")
  const kindBody = declarationBody(kindSource, /\bpublic\s+enum\s+PrivatePluginKind\b/, "PrivatePluginKind")
  const runtimeKinds = canonicalTopLevelEnumCases(kindBody, "PrivatePluginKind")
  const catalogKinds = privatePlugins.map((plugin) => plugin.swiftKind)
  expect(
    JSON.stringify(runtimeKinds) === JSON.stringify(catalogKinds),
    `PrivatePluginKind 必须与清单双向、同序一致：runtime=${runtimeKinds.join(",")} catalog=${catalogKinds.join(",")}`,
  )

  for (const plugin of privatePlugins) await verifySwiftPluginType(root, plugin)

  const controllerSource = await readFile(controllerPath, "utf8")
  const controllerBody = declarationBody(controllerSource, /\bfinal\s+class\s+PrivatePluginController\b/, "PrivatePluginController")
  const expectedMethods = privatePlugins.map((plugin) => preparationMethod(plugin.swiftKind))
  const declaredMethods = exactMatches(controllerBody, /\bprivate\s+func\s+(prepare[A-Za-z0-9_]+)\s*\(/g)
  expect(
    JSON.stringify(declaredMethods) === JSON.stringify(expectedMethods),
    `PrivatePluginController prepare 方法必须与清单双向、同序一致：runtime=${declaredMethods.join(",")} catalog=${expectedMethods.join(",")}`,
  )

  const preparePatchesBody = declarationBody(controllerBody, /\bfunc\s+preparePatches\s*\(/, "PrivatePluginController.preparePatches")
  const calledPreparationMethods = exactMatches(preparePatchesBody, /\b(prepare[A-Z][A-Za-z0-9_]*)\s*\(/g)
  expect(
    JSON.stringify(calledPreparationMethods) === JSON.stringify(expectedMethods),
    `preparePatches 调用必须与清单双向、同序一致：runtime=${calledPreparationMethods.join(",")} catalog=${expectedMethods.join(",")}`,
  )

  for (const plugin of privatePlugins) {
    const method = preparationMethod(plugin.swiftKind)
    const body = declarationBody(
      controllerBody,
      new RegExp(`\\bprivate\\s+func\\s+${escapeRegularExpression(method)}\\s*\\(`),
      `PrivatePluginController.${method}`,
    )
    const referencedTypes = [...new Set(exactMatches(body, /\b(DSH[A-Za-z0-9]+Plugin)\b/g))]
    expect(
      JSON.stringify(referencedTypes) === JSON.stringify([plugin.swiftType]),
      `${method} 必须且只能建立 ${plugin.swiftType}`,
    )
    expect(
      body.includes(`${plugin.swiftType}.resourcesDirectoryName`),
      `${method} 没有使用 ${plugin.swiftType}.resourcesDirectoryName`,
    )
    const patchKinds = exactMatches(body, /patches\[\.([A-Za-z_][A-Za-z0-9_]*)\]\s*=\s*plugin\.patchURL/g)
    const recordedKinds = exactMatches(body, /launchState\.recordPrepared\(\.([A-Za-z_][A-Za-z0-9_]*)\)/g)
    expect(JSON.stringify(patchKinds) === JSON.stringify([plugin.swiftKind]), `${method} patch 映射与清单不一致`)
    expect(JSON.stringify(recordedKinds) === JSON.stringify([plugin.swiftKind]), `${method} prepared kind 映射与清单不一致`)
  }
}

const verifyMetadata = async ({ mode, root }) => {
  for (const plugin of privatePlugins) {
    const pluginRoot = mode === "bundle"
      ? resolve(root, plugin.resourceDirectory)
      : resolve(root, plugin.sourceDirectory)
    for (const relativePath of requiredPluginFiles) {
      await regularFile(resolve(pluginRoot, relativePath), `${plugin.label} ${relativePath}`)
    }

    const packagePath = resolve(pluginRoot, "package.json")
    let manifest
    try {
      manifest = JSON.parse(await readFile(packagePath, "utf8"))
    } catch {
      throw new Error(`${plugin.label} package.json 无法解析`)
    }
    verifyPackage(manifest, plugin)
    verifyPatch(await readFile(resolve(pluginRoot, "cordis.patch.yml"), "utf8"), plugin)
    await verifyHostModule(resolve(pluginRoot, "lib/index.js"), plugin)
    await verifyClientModule(resolve(pluginRoot, "lib/client.js"), plugin)
  }

  if (mode === "source") await verifySwiftRuntime(root)
  console.log(`PASS: ${String(privatePlugins.length)} 个 App 私有插件的 ${mode} metadata、可解析模块与固定清单一致`)
}

const copySourceFixture = async (temporaryRoot) => {
  const relativePaths = new Set([runtimeKindSource, runtimeControllerSource])
  for (const plugin of privatePlugins) {
    relativePaths.add(plugin.swiftSource)
    for (const file of requiredPluginFiles) relativePaths.add(`${plugin.sourceDirectory}/${file}`)
  }
  for (const relativePath of relativePaths) {
    const source = resolve(projectRoot, relativePath)
    const destination = resolve(temporaryRoot, relativePath)
    await mkdir(dirname(destination), { recursive: true })
    await copyFile(source, destination)
  }
}

const runSourceVerifier = (root) => spawnSync(process.execPath, [verifierPath, "--source-root", root], {
  encoding: "utf8",
  stdio: ["ignore", "pipe", "pipe"],
  timeout: 20_000,
  maxBuffer: 2_000_000,
})

const verifyMutationGuards = async () => {
  const temporaryRoot = await mkdtemp(resolve(tmpdir(), "dsd-private-plugin-mutation."))
  try {
    await copySourceFixture(temporaryRoot)
    const baseline = runSourceVerifier(temporaryRoot)
    expect(
      baseline.status === 0,
      `mutation fixture 基线未通过：${(baseline.stderr || baseline.stdout).trim()}`,
    )

    const clientPath = resolve(temporaryRoot, privatePlugins[0].sourceDirectory, "lib/client.js")
    const validClient = await readFile(clientPath, "utf8")
    await writeFile(clientPath, `${validClient}\n}\n`, "utf8")
    const syntaxMutation = runSourceVerifier(temporaryRoot)
    expect(syntaxMutation.status !== 0, "破坏 client JavaScript 语法后 verifier 仍然成功")
    await writeFile(clientPath, `Function(\"return process\")()\n${validClient}`, "utf8")
    const codeGenerationMutation = runSourceVerifier(temporaryRoot)
    expect(codeGenerationMutation.status !== 0, "client 尝试动态 code generation 后 verifier 仍然成功")
    await writeFile(clientPath, validClient, "utf8")

    const hostPath = resolve(temporaryRoot, privatePlugins[0].sourceDirectory, "lib/index.js")
    const validHost = await readFile(hostPath, "utf8")
    await writeFile(hostPath, `${validHost}\nglobalThis.sideEffect = true\n`, "utf8")
    const hostMutation = runSourceVerifier(temporaryRoot)
    expect(hostMutation.status !== 0, "host 入口包含 no-op 之外的语句后 verifier 仍然成功")
    await writeFile(hostPath, validHost, "utf8")

    const kindPath = resolve(temporaryRoot, runtimeKindSource)
    const validKinds = await readFile(kindPath, "utf8")
    const mutationTarget = `case ${privatePlugins.at(-1).swiftKind}`
    const mutatedKinds = validKinds.replace(mutationTarget, `${mutationTarget}Mutation`)
    expect(mutatedKinds !== validKinds, "无法建立 Swift runtime mutation fixture")
    await writeFile(kindPath, mutatedKinds, "utf8")
    const runtimeMutation = runSourceVerifier(temporaryRoot)
    expect(runtimeMutation.status !== 0, "破坏 manifest/runtime 一致性后 verifier 仍然成功")
    await writeFile(kindPath, validKinds, "utf8")

    const rawValuedKinds = validKinds.replace(
      mutationTarget,
      `${mutationTarget}\n    case runtimeOnly = \"runtime-only\"`,
    )
    expect(rawValuedKinds !== validKinds, "无法建立 raw-valued Swift runtime mutation fixture")
    await writeFile(kindPath, rawValuedKinds, "utf8")
    const rawValuedMutation = runSourceVerifier(temporaryRoot)
    expect(rawValuedMutation.status !== 0, "runtime 多出 raw-valued case 后 verifier 仍然成功")

    console.log("PASS: 临时 mutation 自测证明 JS 语法、sandbox、host no-op 与 Swift runtime 漂移均会 fail closed")
  } finally {
    await rm(temporaryRoot, { recursive: true, force: true })
  }
}

const options = parseArguments(process.argv.slice(2))
if (options.selfTest) {
  await verifyMutationGuards()
} else {
  await verifyMetadata(options)
}
