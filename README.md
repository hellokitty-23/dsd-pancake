# DSD Pancake

DSD Pancake 是一个 macOS 薄壳：它把用户**已经安装**的 DSH Web UI 显示在原生 `WKWebView` 中，并在本机服务尚未运行时后台启动它。若服务由 App 自己创建，App 还会按该次启动临时挂载独立的完成提醒、执行操作折叠、底部终端和双 `Esc` 停止快捷键四个私有插件；手动运行的普通 DSH 不会加载它们。

本项目是独立的本地桌面壳，不打包或分发 DSH，也不是 DSH 的功能分支或官方发布。App 每小时在后台分别只读检查 DSD Pancake 的 GitHub 正式 Release（发行版）和当前 DSH 的 npm `latest`（最新发行标签），并只保存最近检查时间与最小版本缓存；发现更新时仅显示壳层标题栏图标，两个更新都始终由用户独立选择。

## 它做什么

- 正式 App 打开固定的本机地址 `http://127.0.0.1:3080/`；
- 端口空闲时，调用用户当前安装的 DSH；可用时以该次进程专属的 `--patch` 覆盖层加载 App 私有插件；
- 默认把同一助手轮次中的非交互工具调用收纳为“当前操作 + 操作汇总”，并把同一助手轮次中的多条 `Think` 投影为一条最新摘要；两种摘要都可就地展开；
- 当前会话正在生成时，可在 2 秒内连按两次不带修饰键的 `Esc` 请求停止；
- 对本次 App 创建且已验证归属的 DSH，在 App 原生标题栏右侧提供底部终端按钮和 `⌘J`；终端仅停靠在右侧主内容区域，并将对话与输入框顶到其上方，左侧工程栏保持完整可见、可操作；
- 发现 App 或 DSH 可选更新时，在 App 原生标题栏的主内容区起点旁显示一个更新图标；点击才打开附着于壳内、锚定该图标的原生浮层，不会向 DSH 网页注入图标、按钮或弹窗；
- 不打开 Terminal.app，不打开默认浏览器；
- 只会停止当前 App 会话亲自创建、并且仍能验证归属的 DSH 进程；
- 可从 App 菜单立即统一检查 DSD Pancake 与 DeepSeek Harness 更新；App 有新版本时，用户可在壳内更新浮层下载经过 SHA-256 校验的 DMG 到 Downloads（下载）目录，DSH 只有再次确认后才会更新；
- 将同源 DSH 页面留在 App 内，把用户点击的外部链接交给默认浏览器；
- 提供标准 macOS 编辑快捷键、首次 `⌘Q` 退出确认，以及关闭窗口后继续保留当前网页会话的行为。

首次打开 App 时，macOS 会在需要时询问通知权限。当 App 自己启动的 DSH 中有顶层对话回复，或 goal（目标）进入完成／受阻状态时，私有插件可通过最小原生桥触发 macOS 通知。通知只使用固定文案；不会携带消息正文、任务标题、路径、Cookie 或网页内容。若普通浏览器访问的是 App 已启动的同一个本机服务，提醒与终端模块因不存在 WebKit 原生桥而完全 no-op（无操作）：不读取会话、不发送通知或同步工作区；无原生桥依赖的操作折叠和双 `Esc` 停止快捷键仍会作用于这个共享的 patched service（已挂载覆盖层的服务）。手动启动的普通 `dsh web` 不加载任何 App 私有模块。

在 macOS 菜单栏的 `消息 → 完成提醒` 中可选择投递方式；状态会保留到下次启动。`永不` 阻断新的原生通知，`仅在未聚焦时`（默认）只在 App 不在前台、窗口隐藏或最小化时提醒，`一律` 则在所有状态下提醒。切换不重启 DSH，也不改变 macOS 已授予的通知权限。

## 执行操作折叠

操作折叠是 App 私有 DSH 客户端适配器，只使用 DSH 正式 `conversation.view`、`conversation.session.header`、`conversation.chat.node` 和 `tool.call.toolview` slot（插槽），不检查或修改 DOM（文档对象模型）。新会话默认折叠同一助手轮次中的非交互工具卡，只保留实时更新的“当前操作”和按类型、失败数统计的汇总行。汇总行本身就是开关：点击，或聚焦后按 Enter／Space（空格），可展开现有卡片，且当前会话后续操作也保持展开；再次操作则恢复折叠。

同一 assistant turn（助手轮次）中连续出现的多条 `Think` 也会被只读投影成一行 `Think · <最新非空摘要>`，不会显示累计条数；流式产生的空 reasoning（推理内容）不会覆盖上一条有效摘要。点击该行可只展开本轮最新一条完整 `Think`，再次点击收起；它与工具卡的展开状态彼此独立。若 assistant-step（助手步骤）还含正文、警告或其它独立内容，这些内容仍保留原位。

工具展开状态按 DSH session（会话）隔离，`Think` 展开状态按 session 与 assistant turn 隔离；两者都仅保留在本次 App 运行的内存中，重启后恢复默认折叠，不写 DSH 会话数据。用户消息、助手正文、最终回复、系统警告与交互式工具不参与工具折叠；失败数始终可见。折叠态在原生 Chat view（对话视图）创建消息行前投影只读 snapshot（快照）和顺序，只移除同一轮次中摘要锚点以外的可折叠操作或已归并的纯 reasoning 行，因此不会留下仍占布局间距的空外壳；展开态通过递归 private alias（私有别名插槽）继续使用上游原生工具卡。Chat view 与标题栏去重作为同一代接管启用；若 DSH slot 规格不兼容，或任一私有别名注册／渲染失败，本次 App 运行会完整撤销折叠接管并保留上游原生界面，不留下空白卡片或重复标签。

## 双 `Esc` 停止生成

双 `Esc` 快捷键是第四个 App 私有 DSH 客户端插件，不经过原生 bridge。只有当前 DSH session 仍为 `running`（正在生成），且能取得该 session 的正式 `cancel()` 能力时，第一个有效 `Esc` 才会进入待确认状态并显示“再按一次 Esc 停止生成”；从第一次按键起的闭区间 `[0, 2000ms]` 内第二次有效 `Esc` 才调用一次当前 session 的取消操作。

带 Option／Control／Command／Shift 的 `Esc`、系统标记为 repeat（按键重复）、IME composing（输入法组字）或已经 `defaultPrevented`（被页面消费）的事件都不会参与计数。按其它键、点击页面、窗口失焦、切换 session、当前 session 停止运行或插件卸载都会清空待确认状态，避免把两次无关操作拼成停止请求。取消失败只显示短暂提示，不自动重试；该插件不会停止其它会话、DSH 进程或终端 PTY。

## 底部终端

底部终端不是网页中的 Shell（命令解释器）模拟器。网页插件只通过 DSH 正式 `sessions` service（会话服务）取得当前 session 的 `cwd`（工作区路径），并向受限原生 bridge（通信桥）同步当前工作区；显示／收起意图、terminal view（终端视图）和 PTY（伪终端）始终由 App 原生壳处理。原生壳还会单向通知已钳制的 dock 高度，插件仅在 DSH 的正式 composer footer（输入框底部扩展位）渲染不可交互占位，用于把对话流顶到终端上方。

- 点击 App 标题栏右侧终端图标、按 `⌘J` 或通过“视图 → 显示/隐藏终端”切换面板；顶部原生 tab bar（标签栏）显示当前工作区的终端标签，`+` 在当前工作区新建独立 shell，点击标签可切换，标签内 `×` 只结束该 shell，最右 `×` 只收起 dock；标签栏和 shell 画布复用 DSH 右侧对话主表面色，形成连续表面而不额外留出视觉缓冲；
- 面板默认约 280px、最小约 160px、最高为可用窗口高度的 50%，以 1pt 细分隔线与上方对话区分，线周边仍可拖动调整；DSH 的左侧工程栏与主内容同属一个 `WKWebView`，因此 WebView 保持全高，而右侧对话流为 dock 预留等高空间，消息和输入框会一起上移，不会被终端覆盖；左侧工程栏不会被终端占据或遮住；
- 每个有效 workspace 在本次 App 运行中可保留多个独立 shell：切换同工作区的不同 DSH 会话会恢复最后选择的标签，切换到其它工作区绝不显示旧终端；
- 采用 SwiftTerm `1.20.0` 的 `LocalProcessTerminalView`，由 `forkpty` 提供 ANSI、光标、交互输入、resize（尺寸变化）与 Ctrl-C；App 退出或 DSH ownership（进程归属）丢失时会终止本 App 创建的 PTY process group（进程组）；
- terminal bridge 只接受本机同源主 frame（主页面）的严格枚举消息；不接受命令、脚本、`eval`、环境变量或任意进程参数，也不记录终端输入、输出或路径；
- external（外部已有）DSH、普通浏览器和无有效工作区的 session 都没有终端能力。普通浏览器没有 WebKit 原生 bridge，因此插件不会订阅会话或读取工作区数据。

## 它明确不做什么

- 不打包 DSH 或 Node.js，不自动安装、升级或降级任何依赖，也不改写用户 DSH profile（配置档）的 package、bundle（插件列表）或 patch（覆盖层）配置、数据库或账号数据；
- 不在后台自动下载、安装、替换或重启 DSD Pancake；只有用户在壳内更新浮层点击“下载更新”后，App 才会下载并校验固定 GitHub Release 的 DMG，之后仍由用户自行打开、退出旧 App 和拖拽安装；
- 不对手动选择的未知安装、源码 checkout（检出目录）、`npx` 临时运行或 external（外部已有）DSH 执行更新；只有当前可执行文件能解析到同一 npm 的全局 `@deepseek-ai/dsh` 包目录，且用户在弹窗中确认时，才运行固定参数的 npm 更新；
- 不扫描、接管或停止已存在的本机服务；
- 不提供网页可调用的通用终端、任意 bridge 命令执行、远程 DSH 管理或跨工作区共享 shell；唯一的本机终端仅面向当前 owned DSH 的有效 workspace；
- 不收集遥测数据，也不将网页内容、Cookie 或会话数据写入项目日志。

为让该次 `--patch` 能解析 App 内的私有包，App 只会在 DSH home 的 `profiles/node_modules/@dsd-pancake/` 下维护分别指向提醒、终端、操作折叠和双 `Esc` 快捷键 bundle 资源的四个符号链接；若任一精确路径是用户文件，或符号链接仍指向可访问目录，则仅让对应能力安全降级，绝不覆盖。只有该 App 保留命名空间中的旧链接已失效时，才会把它修复为当前 bundle，以支持移动或替换 `.app`。

## 前置条件

- macOS 13 或更高版本；
- 可用的 Swift Command Line Tools；
- 已独立安装可运行的 `dsh`，以及该 DSH 所需的 Node.js 环境。

当前开发与受控验证基线为 `@deepseek-ai/dsh 0.1.1-rc.2`。DSH 上游目前仍标注为 Developer preview（开发者预览），后续版本可能包含 breaking changes（破坏性变更）。基础壳与 DSH Web UI（网页界面）的兼容性，和 App 私有提醒／终端／操作折叠／双 `Esc` 快捷键插件的兼容性是两件事：某项集成不可用时基础 Web UI 仍可能正常工作；只有带 App 私有覆盖层的 DSH 在页面就绪前退出时，App 才会自动重试一次不带插件的启动，不能据此推断未知 DSH 版本中的 client API（客户端接口）仍兼容。

App 会依次检查上次手动选择的可执行文件、`/opt/homebrew/bin/dsh` 和 `/usr/local/bin/dsh`。找不到时，界面会让用户手动选择现有的 `dsh` 可执行文件。

## 可选更新

App 启动后及之后每隔约一小时，会分别对 App 和 DSH 进行一次静默只读检查。每个来源只记录最近一次尝试时间和可选更新所需的最小版本信息；睡眠恢复后最多补一轮到期检查，不会连续补跑历史时点。检查从不自动弹窗、下载或安装。若发现至少一项更新，App 原生标题栏会在当前 sidebarWidth（侧栏宽度）右侧、主内容区起点旁以强调色显示更新图标；点击后显示锚定该图标、挂在 `WindowChromeContainer` 内的壳层浮层。图标与面板会随侧栏宽度和窗口尺寸重新定位，窄窗自动收窄而不越过主内容区。没有下载任务时，按 `Esc`、点击浮层外、窗口失焦或进入全屏都会关闭浮层并恢复焦点；下载进行中则保持浮层和任务，`Esc` 仍由壳层消费，用户需点击“取消下载”显式结束。macOS App 菜单中的 `检查更新…` 可立即同时刷新两项结果并显示摘要；确认没有可选更新后，标题栏图标保持隐藏。一项失败不会掩盖另一项。

### DSD Pancake

App 从 `Info.plist` 读取当前版本，对固定公开仓库 `hellokitty-23/dsd-pancake` 的 GitHub `/releases/latest` 发出只读 `HEAD`（仅响应头）请求，并从最终重定向的正式 Release 标签比较 SemVer（语义版本）。该流程使用无 Cookie、无凭据缓存的临时会话，不使用需要未登录速率额度的 GitHub REST API。发现新版本时，壳内更新浮层显示当前／最新版本：

- 用户打开更新浮层后，App 先只读取同一已验证 tag 下固定命名 DMG 的 `.sha256` sidecar（校验文件）；只有 sidecar 严格匹配时才显示“下载更新”，跳转只允许 GitHub 明确受控的 Release 资产主机；
- 下载先写入 App 自己创建的同目录临时文件，流式计算 SHA-256（安全散列算法）且与 sidecar 精确匹配后才移动到 Downloads；既有同名文件绝不覆盖，会自动加序号；
- 缺少、格式错误或不匹配的 sidecar 时不下载 DMG，只提供“打开发布页”；下载成功后，App 会在执行“在 Finder 中显示”“打开 DMG”或再次处理下载动作前重新确认文件仍是普通文件、不是符号链接，并重新计算 SHA-256。若用户已删除、移走或替换该文件，界面立即退回“下载更新”步骤，而不会尝试打开失效路径；App 仍不会自动挂载、安装、替换或重启；
- sidecar 只能证明发布者给出的哈希与文件一致，不能替代 Developer ID（开发者身份）签名或 Apple notarization（公证）。

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

若需要保留当前正式 App 和 3080 DSH 不动，可用 `scripts/local-release/build-test-app.zsh` 构建 `DSD Pancake Test.app`。Test build（测试构建）使用不同名称与 bundle ID、非 3080 端口、独立 `DSH_HOME` 与下载目录、non-persistent WebKit（非持久网页数据）、独立偏好和单实例锁；脚本不会安装或替换 `/Applications/DSD Pancake.app`。可选的 `DSHD_TEST_APP_VERSION` 只覆盖复制出的 Test bundle 版本，便于验收更新入口，不会改正式版本。具体命令与清理边界见构建文档。

打包完成后会得到 `local-release/DSD-Pancake-v<version>-arm64.dmg` 及同名 `.sha256` sidecar，同时保留 `.app`、ZIP 和 build plist（构建映射文件）。`<version>` 的唯一项目事实源是 [Resources/Info.plist](./Resources/Info.plist) 中的 `CFBundleShortVersionString`；文档不另行维护当前数字版本。公开发布时必须把 DMG 与 sidecar 一起上传。用户下载后可让 App 校验，也可使用 `shasum -a 256` 手动核对 sidecar；随后打开 DMG，将 `DSD Pancake.app` 拖到同一窗口中的 `Applications` 快捷入口即可。已有同名 App 时选择“替换”，随后从“应用程序”启动它。

打包脚本会在组装完成后使用 macOS 自带的 `codesign --sign -` 做本机 ad-hoc（无身份）签名，以便系统可靠识别 App 身份并登记通知权限。这不需要 Xcode、Apple 开发者账号、证书或公证，也不会自动写入 `/Applications` 或安装 DSH。DMG 只改善拖拽安装体验，不会把 App 变成 Developer ID（开发者身份）签名或已公证软件；若要面向陌生用户公开发布，仍应另行建立 Developer ID 签名、hardened runtime（强化运行时）与 Apple notarization（公证）流程。

## 结构

```text
Sources/                    macOS 应用层、核心服务层与受控验证器
Resources/                  Info.plist、通知／Finder 图标与独立 Dock 图标
Plugins/                    随 App 打包的提醒、终端、操作折叠与双 Esc 快捷键插件
scripts/                    受控验证、本地 .app 打包与结构校验
docs/                       公开架构与使用文档
```

设计细节见 [docs/architecture.md](./docs/architecture.md)。贡献前请阅读 [CONTRIBUTING.md](./CONTRIBUTING.md)，安全问题请阅读 [SECURITY.md](./SECURITY.md)。

## 许可证

本项目采用 [MIT License](./LICENSE)。

运行时终端模拟器 SwiftTerm `1.20.0` 采用 MIT License；版权与完整文本见 [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)。
