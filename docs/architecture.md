# 架构

DSD Pancake 是一个 macOS 本机薄壳：原生 App 负责启动边界、窗口生命周期和安全退出；DSH 继续独立提供网页、功能与升级。

## 设计边界

```text
Finder
  │
  ▼
DSD Pancake.app
  ├─ 探测 http://127.0.0.1:3080/
  ├─ 必要时准备 App 私有提醒／终端插件的解析链接
  ├─ 必要时以独立的一次性 --patch 启动用户已有的 dsh
  ├─ 管理本次直接创建的子进程
  ├─ 管理每个 workspace 的原生 PTY 与底部 dock
  ├─ 每小时静默只读检查固定 GitHub 项目的 App Release 与 DSH npm latest
  ├─ 用户确认后可更新已验证的全局 npm DSH
  └─ 用一个持久 WKWebView 显示本机页面与受限原生桥
                  │
                  ▼
          已独立安装的 DSH
          （仅 App 创建的进程加载私有插件）
```

App 不打包 DSH、Node.js、用户插件与用户数据，也不会后台自动修改它们。DSD Pancake 自身每小时只读检查 GitHub 元数据，发现更新只在原生标题栏显示状态；用户打开原生 Popover 后，App 仅读取并验证固定 Release 的 SHA-256（安全散列算法）sidecar，只有验证成功才显示“下载更新”，并且绝不自动打开、安装、替换或重启 App。唯一的 DSH 写操作是用户看到版本差异、点击“更新 DSH”并在原生弹窗再次确认后，对来源已验证的全局 `@deepseek-ai/dsh` 执行固定 npm 更新；未知安装与 external（外部已有）服务一律不更新。它也不是通用浏览器、网页可调用终端、远程管理器或全局进程清理工具。App bundle 自带的提醒和终端插件都是壳的一部分，不会登记进用户 DSH profile 的 package、bundle 或 patch 配置。

## 模块

| 模块 | 职责 |
| --- | --- |
| 应用壳层 | AppKit 生命周期、SwiftUI 状态页、窗口视觉、WebKit 容器和退出确认层。 |
| 服务层 | 固定本机地址、DSH 可执行文件定位、启动环境与有界 HTTP 探测。 |
| 更新服务 | SemVer（语义版本）比较、每小时独立调度、最小缓存恢复、固定 GitHub Release 只读检查、SHA-256 sidecar 校验下载、全局 npm 来源验证、DSH 固定参数更新与安装后复核。 |
| 更新壳层 | 原生标题栏状态图标与 Popover；它不属于 DSH DOM（文档对象模型）或私有插件，只有用户点击才显示、下载或进入 DSH 写入确认。 |
| 进程层 | 直接子进程创建、stdout/stderr 有界日志、PID/PGID/启动时间复核、监听 socket 复核与正常终止。 |
| 状态层 | 串行状态归约、单实例锁和异步退出事务门控。 |
| 网页层 | 同源页面与外部链接的导航策略。 |
| 私有提醒插件 | 只在本 App 创建的 DSH 进程内，观察公开会话摘要并生成最小完成事件。 |
| 原生通知桥 | 仅接受本机同源顶层页面的严格固定协议，负责 macOS 授权、前台抑制、内存去重和通知点击恢复窗口。 |
| 私有终端插件 | 在 native bridge 已确认可用时订阅正式 `sessions.list` 的 current（当前会话），仅读取其 `cwd` 无界面同步工作区；没有 WebKit bridge 时完全 no-op（无操作）。 |
| 原生终端层 | AppKit 标题栏按钮、一个持久 `WKWebView` 与一个右侧原生底部 dock；SwiftTerm PTY、工作区隔离、面板状态和 process group（进程组）清理。 |
| 受控验证器 | 不依赖真实 DSH 的受控验证器。 |

应用层通过 `AppCoordinator` 编排，Core 不直接依赖 SwiftUI 或窗口对象。

## 启动与服务归属

启动时先取得单实例锁，然后探测固定地址 `127.0.0.1:3080`：

1. 已有可识别 DSH 时，直接在 WebView 中显示，标记为 `external`（外部已有）。
2. 已有可访问但无法确认的服务时，要求用户确认是否显示；无论是否显示都不接管它。
3. 地址不可访问时，才查找已安装的 `dsh`。若 App bundle 内私有插件完整、其保留解析路径没有被用户文件或仍指向可访问目录的链接占用，则分别创建只指向 bundle 的链接：

   ```text
   $DSH_HOME/profiles/node_modules/@dsd-pancake/dsh-desktop-notifications
     -> DSD Pancake.app/Contents/Resources/DSHNotifications
   $DSH_HOME/profiles/node_modules/@dsd-pancake/dsh-desktop-terminal
     -> DSD Pancake.app/Contents/Resources/DSHTerminal
   ```

   接着用 DSH launcher（启动器）参数数组启动：

   ```text
   dsh --profile web --patch <提醒 patch> --patch <终端 patch> --no-open --host 127.0.0.1 --port 3080
   ```

   `--patch` 是该进程参数，不会改写默认 profile；因此普通 `dsh web` 和浏览器直接访问的既有 DSH 都不会加载插件。若普通浏览器访问的是 App 已启动的同一服务，DSH 会传送客户端模块，但模块因没有 WebKit 原生桥而不订阅会话、不申请权限、不发送通知或注册终端工作区同步组件。保留命名空间中的失效链接会修复到当前 bundle，任何仍指向可访问目录的链接绝不覆盖。若插件资源、解析链接或带覆盖层的启动在网页就绪前失败，App 仅自动退回一次不带插件的标准 `dsh web` 启动，不循环重试。

4. 服务就绪后，只有满足“本 App 直接创建 + 进程身份仍匹配 + 该进程自身监听固定回环端口”的进程才标记为 `owned`（本应用拥有）。原生提醒和终端 bridge 也只在各自 patch 已准备的这个 `owned` 进程有效；已有或后继的 external（外部已有）服务始终没有 bridge 能力。只要 ownership 丢失，终端面板立即收起且所有 App 创建的 PTY 都被清理。

端口、PID 或命令文本都不足以证明归属。App 不使用 `pkill`，不扫描其他 PID，也不会把已存在的服务变成可停止对象。

## 可选更新边界

`UpdateStatusController`（更新状态控制器）为 App 与 DSH 分别保存最后一次检查时间；首次没有记录时会各做一次检查，之后用一个单次 Timer（计时器）安排下一个最早到期项。休眠恢复只重新计算到期来源，至多开始一轮检查，不补跑多个历史小时。自动检查从不弹窗、下载、安装或调用 DSH 的更新命令。手动菜单检查共享同一只读路径，但会汇总两项结果；GitHub 不可用时仍可处理 DSH，DSH 缺失或 npm 查询失败时仍可显示 App 结果。

缓存仅包含 App 的最新稳定版本，以及 DSH 的可执行文件绝对路径、当前版本和最新版本。App 恢复缓存时重新从固定常量推导 GitHub Release／资产地址，不持久化重定向 URL、签名参数或响应正文；DSH 恢复缓存时必须再次读取当前选择的可执行文件版本，路径或版本变化立即丢弃缓存。任一检查失败不会伪造“已是最新”，也不会抹掉已验证的另一项提示。

App 自身的检查从 bundle 读取当前版本，只对固定公开仓库的 `/releases/latest` 页面发出 `HEAD`（仅响应头）请求，并解析 GitHub 最终重定向的稳定 SemVer 标签；它使用无 Cookie、无凭据缓存的临时会话，不使用需要未登录速率额度的 GitHub REST API。发布页必须是固定项目的精确 tag 路径，DMG 与 checksum（校验文件）地址再由已验证标签和固定 arm64 命名生成。壳层标题栏左侧的原生状态图标仅在发现可选更新时显示；手动检查的汇总结果通过当次原生确认弹窗呈现，确认没有更新时图标保持隐藏。它不注入 DSH 页面、header 或插件，也不持久化手动检查报告。

用户打开 Popover 时，下载器先读取精确同名 `.sha256` sidecar，严格要求单行 `<64 位 hash><空白><精确 DMG 文件名>`；缺失／错误时界面只提供发布页。只有 sidecar 已验证、用户再点击“下载更新”时，才会继续 DMG 传输。它只允许从固定 GitHub 初始 URL 跳转到明确列出的 GitHub Release 资产主机；DMG 写入 Downloads 同目录的 App 自己创建的 `.part` 文件，流式算出 SHA-256 后再和 sidecar 比较。只有匹配时才通过不覆盖的 `moveItem` 移动到最终文件名；既有文件使用递增后缀。失败或取消只删除本次精确临时文件，且不会打开、挂载、安装、替换或重启 App。“关于”窗口复用同一个固定仓库常量显示项目地址。

DSH 更新流程与正常启动共享同一条“只停止 owned（本应用拥有）进程”的所有权规则：

1. 当前版本只从 App 实际选择的 `dsh --version` 读取；版本比较实现 SemVer（语义版本）预发布规则，`rc.10` 不会被字符串顺序误判为早于 `rc.2`，build metadata（构建元数据）不影响优先级。
2. App 在当前 `dsh` 同目录和受支持的 Homebrew／`/usr/local` 路径中寻找 npm，执行只读 `npm root --global`，并要求解析符号链接后的 DSH 落在 `<global-root>/@deepseek-ai/dsh/` 内。相似路径前缀、源码 checkout（检出目录）和未知包管理器不会通过。
3. 检查只运行 `npm view @deepseek-ai/dsh dist-tags.latest --json`。结果与确认都显示为主窗口附属 sheet（窗口附属弹窗），不会强制把后台 App 抢到前台；只有用户在第二个确认步骤点击“更新 DSH”，才准备写操作。
4. owned DSH 先收到一次 `SIGTERM`；App 等待主进程回收和 stdout/stderr 自然 EOF。若端口随后出现 external 服务、归属失效或十五秒仍未收敛，更新终止，不使用 `SIGKILL`。
5. 安装使用结构化可执行文件与固定参数数组，不经过 Shell（命令解释器），不接受页面或用户文本作为命令参数，不调用 `sudo`。命令输出进入独立的有界、脱敏内存日志；npm 最长运行十分钟。
6. 安装结束后重新执行同一路径的 `dsh --version`；校验通过或失败都会恢复正常启动预检。失败不会循环重装、自动降级或修改 `$DSH_HOME`。

正在进行的显式 DSH 更新、只读检查或 App 下载任务会暂时阻止 AppKit 退出并提示等待／取消，避免中断 npm 写入或遗留不完整下载。自动检查本身不会启动下载或安装任务。

## 窗口与退出

- 关闭主窗口只隐藏窗口；再次激活 App 会恢复原窗口与同一个 WebView。
- `external` 服务不会因 App 退出而被停止。
- 无论服务是 `external`、`owned` 或当前没有服务，第一次 `⌘Q` 都只显示原生半透明确认层。
- 四秒内再次按 `⌘Q` 时，`owned` 服务才会收到一次 `SIGTERM`；`external` 服务或无服务时只退出 App，不发送信号。
- `Esc`、取消、背景点击或确认超时都会取消退出，不发送信号。
- 终止请求后 App 异步等待进程和日志管道收尾；不会在主线程阻塞，也不会自动发送 `SIGKILL`。

这套退出事务由 `TerminationTransactionRegistry` 和 `TerminationConfirmationGate` 防止重复确认、重复 reply（AppKit 退出回复）或过期事务影响新事务。

## 网页边界

`WebContainer` 在整个会话中只创建一个持久 `WKWebView`，保留 DSH 的 WebKit 登录状态与页面状态。

- `127.0.0.1:3080` 同源顶层导航留在 App 内；
- 用户点击的外部 HTTP/HTTPS 链接交给默认浏览器；
- 非用户触发的跨源跳转、无地址跳转和不支持的 scheme（协议）会被阻止并给出说明；
- `target=_blank` 不创建第二个窗口；
- 视觉桥只读取页面根布局的宽度、已计算的背景色和分隔线色，用于让原生窗口表面与 DSH 侧栏协调。它不读取文字、会话、Cookie 或输入，不写入 DOM，也不调用 DSH 功能。

## 完成提醒

私有插件使用 DSH 的公开 `ctx.sessions.list` 会话摘要，而不是 DOM（文档对象模型）扫描、端口轮询或后台守护。它建立打开页面时的基线，不为历史已完成任务补发提醒；之后只处理顶层、非 subagent（子代理）会话的以下变化：

- 普通对话从 `running` 变为不运行；
- goal（目标）进入 `complete`（完成）或 `blocked`（受阻）这一不同的终态；例如先受阻、后完成会分别提醒一次。

有 goal 的会话只发终态通知，避免“普通回复”和“任务完成”重复。插件把不含自由文本的 event ID（事件标识）与固定 kind（类型）经 WebKit reply bridge（可回复桥）发送给原生 App；桥只接受 `http://127.0.0.1:3080` 的顶层页面、协议版本 `1` 和精确字段集。原生层固定显示“对话已有回复”“任务已完成”或“任务需要你处理”，并且：

- 完成提醒投递模式分为“永不”“仅在未聚焦时”（默认）和“一律”；默认模式仅在 App 非前台、窗口隐藏或最小化时投递，“一律”也允许前台横幅；
- 首次打开 App 时由 macOS 询问通知权限；拒绝后插件静默降级；
- 菜单栏的“消息 → 完成提醒”是持久化的最终投递门；切换后立即调整新 bridge 事件的投递范围，不改写系统授权、不重启 DSH；
- 仅做 App 生命周期内有界去重；通知请求使用不透明 event ID（事件标识）作为系统标识，不写入对话或事件日志；
- 点击通知只恢复 DSD Pancake 主窗口。

## 底部终端

页面端和原生端有刻意窄的分工，避免 DSH 网页获得任意本机命令能力：

```text
DSH sessions.list current session
  └─ 私有终端 client plugin
      ├─ 仅读取 current session.cwd（包括新会话的空白 session）
      └─ 只发送 capabilities / syncWorkspace / clearWorkspace
                  │  主 frame + 127.0.0.1:3080 + 精确字段集
                  ▼
          WebContainer terminal bridge
                  │  workspace 必须是存在的目录
                  ▼
      DesktopTerminalController
        ├─ workspace -> 一个或多个 TerminalTab -> 各自一个 LocalProcessTerminalView / forkpty shell
        ├─ AppKit 标题栏右侧按钮 / ⌘J / 视图菜单 -> 显示状态
        └─ TerminalDockContainer -> 原生标签、`+`、仅右侧主内容区域的 dock
                  │  单向：已钳制的 dock 高度
                  ▼
      composer footer slot -> 不可交互高度占位 -> 对话和输入框上移
```

私有终端插件先协商 native bridge 能力；只有原生壳明确回复可用时，才订阅公开 `ctx.sessions.list` 并仅读取 `current` 对应 session 的 `cwd`。这覆盖已选工作区的新会话空白 session，不依赖会话头部是否渲染。能力确认后，它只在 DSH 正式 `conversation.composer.dock` slot（输入框底部扩展位）注册一个不可交互的高度占位：原生壳单向发送版本化的布尔开关与已钳制高度，插件据此让消息与输入框为 dock 留位；这个页面本地事件不属于 bridge action，网页即使伪造它也只能改变自身空白高度，不能改变原生 dock 或本机权限。插件不在 DSH 内显示按钮、图标或 terminal view（终端视图），不替换 `root`、`conversation` 或 AppFrame，不检查 DSH DOM（文档对象模型）或哈希 CSS class（样式类），也不使用 `shell.overlay`。没有 native bridge 的浏览器端插件在能力协商后静默退出，因此不会加载 React、注册 slot、订阅会话、读取 workspace 或创建其它副作用。

`DesktopTerminalBridge` 只接受版本 `1` 的精确字段集：`capabilities` 只有版本和动作，`syncWorkspace` 才携带 `sessionID` 与绝对 `workspacePath`，`clearWorkspace` 只声明当前会话没有可用工作区。未知字段、未知 action、控制字符、相对路径、空路径与不存在目录均被拒绝。网页 bridge 不具有显示／收起权限；响应仅携带 capability、面板打开状态和 workspace 是否通过，不反向返回路径。它不定义 command、script、`eval`、环境变量或任意进程参数字段；所有键盘输入直接由 `LocalProcessTerminalView` 写入 PTY，不经过网页 bridge，也不会记录输入、输出、环境变量或路径。

原生 UI 使用 AppKit 标题栏右侧按钮、一个持久 `WKWebView` 和 `TerminalDockContainer`。展开时 dock 以默认约 280px、最小约 160px、最多可用窗口内容高度 50% 放在窗口底部，并从 DSH 左侧工程栏的右边开始停靠；可见分隔线为 1pt，但 AppKit 在其周边保留透明拖拽热区，本次 App 运行记住最后一次非零高度。因为 DSH 的侧栏与主内容同属一个 `WKWebView`，壳层保持 WebView 全高来让工程栏继续完整可见、可操作；同时把实际 dock 高度单向传给上述正式 composer footer slot，使右侧消息与输入框为原生 terminal 留出对应高度，而不是被它覆盖。标题栏按钮、`⌘J` 与 macOS “视图 → 显示/隐藏终端”调用同一个 `DesktopTerminalController` 状态源；终端顶部使用紧凑原生 tab bar（标签栏）显示当前工作区的标签，`+` 新建独立 shell，点击标签切换，标签内 `×` 只结束该 shell，最右 `×` 只收起 dock；现有只读 chrome bridge（视觉桥）把 DSH 右侧主表面色同时提供给标题栏、标签栏和 SwiftTerm shell 画布，因此它们使用同一连续表面而不额外插入视觉缓冲。动画仅在系统没有 Reduce Motion（减少动态效果）时使用短暂、可中断的 AppKit ease-in-out（缓入缓出）过渡；拖动从当前 frame 直接接管，不等待动画完成。

每个规范化 workspace 可拥有一个或多个 PTY；每个标签严格对应一个 shell 和一个 process group（进程组），同 workspace 的不同标签也绝不共享 PTY。切换同 workspace 的 DSH session 会恢复最后选择的标签；切换到其它 workspace 时收起旧面板而不混用状态；收起面板只隐藏 view；标签内 `×`、终端内 shell 正常退出、DSH ownership 丢失或 App 退出都会清理对应 shell。SwiftTerm `LocalProcessTerminalView` 使用 `forkpty`，提供 ANSI、光标、输入、窗口 resize 和 Ctrl-C；App 对对应 process group 先发 `SIGTERM`，短暂等待后才在退出清理中升级 `SIGKILL`，避免遗留子进程。该 PTY 和 DSH agent（智能体）自身的 terminal 完全独立。

## 日志与本地数据

子进程 stdout/stderr 只保留在内存中的有界环形日志中。常见 token、Authorization、Cookie 等敏感键值会被遮盖，日志默认不落盘。

网页数据由 WebKit 按 App bundle ID 保存；用户偏好保存上次手动选择的 `dsh` 路径、提醒偏好，以及最后检查时间与最小更新缓存。它不保存 GitHub／npm 响应正文、下载重定向 URL、DMG 内容、网页数据或遥测。删除 App 不会删除 DSH 的数据。fork（派生）后如需和原 App 并存，应先改掉 `CFBundleIdentifier`，以获得独立的单实例锁与 WebKit 数据命名空间。

## 本地打包

项目使用 Swift Package Manager，并固定 SwiftTerm `1.20.0`（MIT License；见 `THIRD_PARTY_NOTICES.md`）。`scripts/local-release/build-app.zsh` 将 Release 可执行文件、`Info.plist`、两套图标、两个已构建的 App 私有插件各四个文件，以及 SwiftTerm 唯一必要的 `Contents/Resources/SwiftTerm_SwiftTerm.bundle/Shaders.metal` 放入 `.app` 后，使用 `codesign --sign -` 完成无身份的本机 ad-hoc 签名。SwiftTerm 当前 Metal renderer 会从标准的 `Bundle.main.resourceURL` 查找这个 bundle；将资源放在 `.app` 根目录会破坏 macOS bundle 的 sealed resources（签名封装资源）规则，因此 `verify-app.zsh` 对标准资源位置使用精确白名单。`PancakeAppIcon` 是由 `Resources/AppIcon.png` 生成的 Finder／原生通知 bundle 身份图标，`DockIcon` 只在运行时显示于 Dock，二者可独立调整留白与构图；白名单拒绝 DSH、Node.js、`node_modules`、第三方插件、网页资源、测试夹具、额外可执行文件和符号链接。`build-dmg.zsh` 只把已通过检查的 App 与指向 `/Applications` 的快捷入口封装为只读压缩 DMG，并强制输出 `DSD-Pancake-v<version>-arm64.dmg` 与精确同名 `.sha256` sidecar；`verify-dmg.zsh` 在挂载前精确比对 sidecar，再真实挂载映像并再次验证其中的 App 与版本化文件名；`build-release.zsh` 是串联整套流程的单一入口。

这保证“App 是壳”是可检查的包结构，而不只是文档承诺。

## 验证

```zsh
zsh scripts/verify.zsh
```

验证器覆盖状态机、单实例、日志脱敏、导航、WebKit 持久化配置、私有插件解析链接、提醒与终端 bridge 协议、通知前台策略与去重、终端 workspace 隔离、dock 的 50% 高度上限、右侧内容区域和对话预留高度规则、SemVer（语义版本）、GitHub Release 来源与 npm 路径边界、每小时时间表、缓存失效、标题栏更新标签、固定 Release 资产跳转、严格 SHA-256 sidecar、sidecar 缺失、哈希不匹配、下载中取消、无覆盖目标名和受控 URLProtocol 的实际落盘哈希计算、受控单次命令、受控 HTTP 探测、进程创建／回收／归属和退出门控。客户端插件验证额外证明普通浏览器 no-op、公开 composer footer slot 的不可交互布局预留、无界面工作区同步与最小 bridge 负载。文档中的脚本固定跳过当前 3080，以免读取用户正在使用的服务。
