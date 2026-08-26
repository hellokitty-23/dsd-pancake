# DSD Pancake

DSD Pancake 是一个 macOS 薄壳：它把用户**已经安装**的 DSH Web UI 显示在原生 `WKWebView` 中，并在本机服务尚未运行时后台启动它。若服务由 App 自己创建，App 还会按该次启动临时挂载一个私有的完成提醒插件；手动运行的普通 DSH 不会加载它。

本项目是独立的本地桌面壳，不打包或分发 DSH，也不是 DSH 的功能分支或官方发布。App 菜单可同时只读检查 DSD Pancake 的 GitHub 正式 Release（发行版）和当前 DSH 的 npm `latest`（最新发行标签）；两项更新都由用户独立选择。

## 它做什么

- 打开固定的本机地址 `http://127.0.0.1:3080/`；
- 端口空闲时，调用用户当前安装的 DSH；可用时以该次进程专属的 `--patch` 覆盖层加载 App 私有提醒插件；
- 不打开 Terminal.app，不打开默认浏览器；
- 只会停止当前 App 会话亲自创建、并且仍能验证归属的 DSH 进程；
- 可从 App 菜单统一检查 DSD Pancake 与 DeepSeek Harness 更新；App 有新版本时只显示下载地址并打开发布页，DSH 只有再次确认后才会更新；
- 将同源 DSH 页面留在 App 内，把用户点击的外部链接交给默认浏览器；
- 提供标准 macOS 编辑快捷键、首次 `⌘Q` 退出确认，以及关闭窗口后继续保留当前网页会话的行为。

首次打开 App 时，macOS 会在需要时询问通知权限。当 App 自己启动的 DSH 中有顶层对话回复，或 goal（目标）进入完成／受阻状态时，私有插件可通过最小原生桥触发 macOS 通知。通知只使用固定文案；不会携带消息正文、任务标题、路径、Cookie 或网页内容。若普通浏览器访问的是 App 已启动的同一个本机服务，DSH 仍会传送该客户端模块，但它因不存在 WebKit 原生桥而完全 no-op（无操作）：不读取会话、不发送通知。

在 macOS 菜单栏的 `消息 → 完成提醒` 中可选择投递方式；状态会保留到下次启动。`永不` 阻断新的原生通知，`仅在未聚焦时`（默认）只在 App 不在前台、窗口隐藏或最小化时提醒，`一律` 则在所有状态下提醒。切换不重启 DSH，也不改变 macOS 已授予的通知权限。

## 它明确不做什么

- 不打包 DSH 或 Node.js，不自动安装、升级或降级任何依赖，也不改写用户 DSH profile（配置档）的 package、bundle（插件列表）或 patch（覆盖层）配置、数据库或账号数据；
- 不下载、安装、替换或重启 DSD Pancake 自身；App 更新检查只显示固定 GitHub 项目的正式 Release 版本与下载地址，由用户自行下载安装；
- 不对手动选择的未知安装、源码 checkout（检出目录）、`npx` 临时运行或 external（外部已有）DSH 执行更新；只有当前可执行文件能解析到同一 npm 的全局 `@deepseek-ai/dsh` 包目录，且用户在弹窗中确认时，才运行固定参数的 npm 更新；
- 不扫描、接管或停止已存在的本机服务；
- 不提供通用终端、任意命令执行、多标签页或远程 DSH 管理；
- 不收集遥测数据，也不将网页内容、Cookie 或会话数据写入项目日志。

为让该次 `--patch` 能解析 App 内的私有包，App 只会在 DSH home 的 `profiles/node_modules/@dsd-pancake/` 下维护一个指向自身 bundle 的符号链接；若该精确路径是用户文件或指向实际未知目录的链接，则安全降级为没有提醒的普通启动，不覆盖用户文件。若该 App 保留命名空间中的旧链接已失效，App 会把它修复为当前 bundle，以支持移动或替换 `.app`。

## 前置条件

- macOS 13 或更高版本；
- 可用的 Swift Command Line Tools；
- 已独立安装可运行的 `dsh`，以及该 DSH 所需的 Node.js 环境。

当前开发与受控验证基线为 `@deepseek-ai/dsh 0.1.1-rc.2`。DSH 上游目前仍标注为 Developer preview（开发者预览），后续版本可能包含 breaking changes（破坏性变更）。基础壳与 DSH Web UI（网页界面）的兼容性，和 App 私有提醒插件的兼容性是两件事：提醒集成不可用时基础 Web UI 仍可能正常工作；只有带提醒覆盖层的 DSH 在页面就绪前退出时，App 才会自动重试一次不带提醒覆盖层的启动，不能据此推断未知 DSH 版本中的 client API（客户端接口）仍与提醒插件兼容。

App 会依次检查上次手动选择的可执行文件、`/opt/homebrew/bin/dsh` 和 `/usr/local/bin/dsh`。找不到时，界面会让用户手动选择现有的 `dsh` 可执行文件。

## 可选更新

打开 macOS App 菜单中的 `检查更新…`，两项检查会独立完成；一项失败不会阻止另一项显示结果。

### DSD Pancake

App 从 `Info.plist` 读取当前版本，对固定公开仓库 `hellokitty-23/dsd-pancake` 的 GitHub `/releases/latest` 发出只读 `HEAD`（仅响应头）请求，并从最终重定向的正式 Release 标签比较 SemVer（语义版本）。该流程不使用需要未登录速率额度的 GitHub REST API。发现新版本时，窗口附属弹窗会显示当前／最新版本和按固定发布命名生成的 DMG（磁盘映像）下载地址；只有用户点击“打开发布页”才会把 GitHub 页面交给默认浏览器。App 不会下载文件、替换正在运行的 bundle（应用包）、启动安装器或重启自身。

“关于 DSD Pancake”窗口也提供可点击的 [GitHub 项目地址](https://github.com/hellokitty-23/dsd-pancake)。

### DeepSeek Harness

1. App 用当前实际选择的 `dsh --version` 读取本机版本；
2. 验证该可执行文件位于同一 npm 返回的全局 `@deepseek-ai/dsh` 包目录内；
3. 用同一个 npm 只读查询 `dist-tags.latest`（最新发行标签）；
4. 发现更新时显示当前版本、最新版本和 npm 路径；只有点击“更新 DSH”才继续；
5. 若 DSH 是本次 App 创建且归属仍有效，先发送一次 `SIGTERM` 并等待进程和日志自然收敛，再执行固定参数数组 `npm install --global @deepseek-ai/dsh@latest --no-audit --no-fund`；完成后校验 `dsh --version` 并重新启动服务。

若 `127.0.0.1:3080` 是 external（外部已有）服务、进程归属失效、安装来源不匹配、停止超时或 npm 需要当前用户没有的写入权限，App 会停止更新并显示原因。它不会使用 Shell（命令解释器）、`sudo`、`SIGKILL` 或任意用户输入拼接命令，也不会修改 `$DSH_HOME` 中的会话、凭据和 profile（配置档）。

## 构建、打包与安装

完整说明见 [docs/build-and-run.md](./docs/build-and-run.md)。在仓库根目录执行：

```zsh
zsh scripts/verify.zsh
zsh scripts/local-release/build-release.zsh
```

`scripts/verify.zsh` 会跳过对当前正在使用的 `127.0.0.1:3080` 的 HTTP 探测；其余检查只使用受控子进程和随机端口测试夹具。

打包完成后会得到 `local-release/DSD Pancake.dmg`，同时保留 `.app`、ZIP 和 build plist（构建映射文件）。发给用户时优先提供 DMG（磁盘映像）：用户打开后，将 `DSD Pancake.app` 拖到同一窗口中的 `Applications` 快捷入口即可；已有同名 App 时选择“替换”，随后从“应用程序”启动它。

打包脚本会在组装完成后使用 macOS 自带的 `codesign --sign -` 做本机 ad-hoc（无身份）签名，以便系统可靠识别 App 身份并登记通知权限。这不需要 Xcode、Apple 开发者账号、证书或公证，也不会自动写入 `/Applications` 或安装 DSH。DMG 只改善拖拽安装体验，不会把 App 变成 Developer ID（开发者身份）签名或已公证软件；若要面向陌生用户公开发布，仍应另行建立 Developer ID 签名、hardened runtime（强化运行时）与 Apple notarization（公证）流程。

## 结构

```text
Sources/                    macOS 应用层、核心服务层与受控验证器
Resources/                  Info.plist、通知／Finder 图标与独立 Dock 图标
Plugins/                    随 App 打包的私有 DSH 完成提醒插件
scripts/                    受控验证、本地 .app 打包与结构校验
docs/                       公开架构与使用文档
```

设计细节见 [docs/architecture.md](./docs/architecture.md)。贡献前请阅读 [CONTRIBUTING.md](./CONTRIBUTING.md)，安全问题请阅读 [SECURITY.md](./SECURITY.md)。

## 许可证

本项目采用 [MIT License](./LICENSE)。
