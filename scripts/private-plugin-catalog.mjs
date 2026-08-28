import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { fileURLToPath } from "node:url"

const catalogPath = fileURLToPath(new URL("./private-plugins.json", import.meta.url))
const expectedRequiredFiles = [
  "package.json",
  "cordis.patch.yml",
  "lib/index.js",
  "lib/client.js",
]

const fail = (message) => {
  throw new Error(`私有插件清单无效：${message}`)
}

const exactKeys = (value, expected, label) => {
  if (value === null || typeof value !== "object" || Array.isArray(value)) fail(`${label} 必须是对象`)
  if (JSON.stringify(Object.keys(value).sort()) !== JSON.stringify([...expected].sort())) {
    fail(`${label} 字段不精确`)
  }
}

let parsed
try {
  parsed = JSON.parse(readFileSync(catalogPath, "utf8"))
} catch (error) {
  fail(`无法读取 ${catalogPath}（${error instanceof Error ? error.message : String(error)}）`)
}

exactKeys(parsed, ["schemaVersion", "requiredFiles", "plugins"], "根对象")
if (parsed.schemaVersion !== 1) fail("schemaVersion 必须是 1")
if (JSON.stringify(parsed.requiredFiles) !== JSON.stringify(expectedRequiredFiles)) {
  fail("requiredFiles 必须精确列出四个可发行文件")
}
if (!Array.isArray(parsed.plugins) || parsed.plugins.length === 0) fail("plugins 必须是非空数组")

const seen = {
  id: new Set(),
  sourceDirectory: new Set(),
  resourceDirectory: new Set(),
  packageName: new Set(),
  patchId: new Set(),
  swiftKind: new Set(),
  swiftType: new Set(),
  swiftSource: new Set(),
  verifier: new Set(),
}
const safeText = (value) => typeof value === "string" && value.length > 0 && !/[\t\r\n]/.test(value)
const assertUnique = (field, value) => {
  if (seen[field].has(value)) fail(`${field} 重复：${value}`)
  seen[field].add(value)
}

const plugins = parsed.plugins.map((plugin, index) => {
  exactKeys(
    plugin,
    [
      "id",
      "label",
      "sourceDirectory",
      "resourceDirectory",
      "packageName",
      "patchId",
      "inject",
      "swiftKind",
      "swiftType",
      "swiftSource",
      "verifier",
    ],
    `plugins[${String(index)}]`,
  )
  if (!safeText(plugin.id) || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(plugin.id)) {
    fail(`plugins[${String(index)}].id 不安全`)
  }
  if (!safeText(plugin.label)) fail(`plugins[${String(index)}].label 不安全`)
  if (!safeText(plugin.sourceDirectory) || !/^Plugins\/dsd-pancake-[a-z0-9-]+$/.test(plugin.sourceDirectory)) {
    fail(`plugins[${String(index)}].sourceDirectory 必须位于 Plugins/dsd-pancake-*`)
  }
  if (!safeText(plugin.resourceDirectory) || !/^DSH[A-Za-z0-9]+$/.test(plugin.resourceDirectory)) {
    fail(`plugins[${String(index)}].resourceDirectory 不安全`)
  }
  if (!safeText(plugin.packageName) || !/^@dsd-pancake\/[a-z0-9-]+$/.test(plugin.packageName)) {
    fail(`plugins[${String(index)}].packageName 不安全`)
  }
  if (!safeText(plugin.patchId) || !/^dsd-pancake-[a-z0-9-]+$/.test(plugin.patchId)) {
    fail(`plugins[${String(index)}].patchId 不安全`)
  }
  if (!safeText(plugin.verifier) || !/^scripts\/verify-[a-z0-9-]+-plugin\.mjs$/.test(plugin.verifier)) {
    fail(`plugins[${String(index)}].verifier 不安全`)
  }
  if (!safeText(plugin.swiftKind) || !/^[a-z][A-Za-z0-9]*$/.test(plugin.swiftKind)) {
    fail(`plugins[${String(index)}].swiftKind 不是安全的 Swift case 名称`)
  }
  if (!safeText(plugin.swiftType) || !/^DSH[A-Za-z0-9]+Plugin$/.test(plugin.swiftType)) {
    fail(`plugins[${String(index)}].swiftType 不是受支持的 Swift 插件类型`)
  }
  const expectedSwiftSource = `Sources/DSHDesktopCore/Service/${plugin.swiftType}.swift`
  if (plugin.swiftSource !== expectedSwiftSource) {
    fail(`plugins[${String(index)}].swiftSource 必须精确指向 ${expectedSwiftSource}`)
  }
  if (
    !Array.isArray(plugin.inject)
    || plugin.inject.length === 0
    || plugin.inject.some((name) => !/^[a-z][a-z0-9-]*$/.test(name))
    || new Set(plugin.inject).size !== plugin.inject.length
  ) {
    fail(`plugins[${String(index)}].inject 必须是非空、无重复的 service 名称数组`)
  }
  for (const field of Object.keys(seen)) assertUnique(field, plugin[field])
  return Object.freeze({ ...plugin, inject: Object.freeze([...plugin.inject]) })
})

export const requiredPluginFiles = Object.freeze([...expectedRequiredFiles])
export const privatePlugins = Object.freeze(plugins)

const printLines = (lines) => {
  if (lines.length > 0) process.stdout.write(`${lines.join("\n")}\n`)
}

const command = process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)
  ? process.argv[2]
  : undefined

if (command !== undefined) {
  switch (command) {
  case "required-files":
    printLines(requiredPluginFiles)
    break
  case "rows":
    printLines(privatePlugins.map((plugin) => [
      plugin.sourceDirectory,
      plugin.resourceDirectory,
      plugin.packageName,
      plugin.patchId,
      plugin.label,
    ].join("\t")))
    break
  case "verifiers":
    printLines(privatePlugins.map((plugin) => plugin.verifier))
    break
  default:
    process.stderr.write("用法：node scripts/private-plugin-catalog.mjs required-files|rows|verifiers\n")
    process.exitCode = 64
  }
}
