# 架构

DSD Pancake 是一个 macOS 本机薄壳：原生 App 负责启动边界、窗口生命周期和安全退出；DSH 继续独立提供网页、功能与升级。

## 设计边界

```text
Finder
  │
  ▼
DSD Pancake.app
  ├─ 探测 http://127.0.0.1:3080/
  ├─ 必要时准备 App 私有提醒插件的解析链接
  ├─ 必要时以一次性 --patch 启动用户已有的 dsh
  ├─ 管理本次直接创建的子进程
  ├─ 用户确认后可更新已验证的全局 npm DSH
  └─ 用一个持久 WKWebView 显示本机页面与受限原生桥
                  │
                  ▼
          已独立安装的 DSH
          （仅 App 创建的进程加载私有插件）
```

App 不打包 DSH、Node.js、用户插件与用户数据，也不会后台自动修改它们。唯一的 DSH 写操作是用户从菜单发起、看到版本差异并在原生弹窗再次确认后，对来源已验证的全局 `@deepseek-ai/dsh` 执行固定 npm 更新；未知安装与 external（外部已有）服务一律不更新。它也不是通用浏览器、终端、远程管理器或全局进程清理工具。App bundle 自带的提醒插件是壳的一部分，不会登记进用户 DSH profile 的 package、bundle 或 patch 配置。

## 模块

| 模块 | 职责 |
| --- | --- |
| 应用壳层 | AppKit 生命周期、SwiftUI 状态页、窗口视觉、WebKit 容器和退出确认层。 |
| 服务层 | 固定本机地址、DSH 可执行文件定位、启动环境与有界 HTTP 探测。 |
| 更新服务 | SemVer（语义版本）比较、全局 npm 来源验证、只读 latest 查询、固定参数更新与安装后复核。 |
| 进程层 | 直接子进程创建、stdout/stderr 有界日志、PID/PGID/启动时间复核、监听 socket 复核与正常终止。 |
| 状态层 | 串行状态归约、单实例锁和异步退出事务门控。 |
| 网页层 | 同源页面与外部链接的导航策略。 |
| 私有提醒插件 | 只在本 App 创建的 DSH 进程内，观察公开会话摘要并生成最小完成事件。 |
| 原生通知桥 | 仅接受本机同源顶层页面的严格固定协议，负责 macOS 授权、前台抑制、内存去重和通知点击恢复窗口。 |
| 受控验证器 | 不依赖真实 DSH 的受控验证器。 |

应用层通过 `AppCoordinator` 编排，Core 不直接依赖 SwiftUI 或窗口对象。

## 启动与服务归属

启动时先取得单实例锁，然后探测固定地址 `127.0.0.1:3080`：

1. 已有可识别 DSH 时，直接在 WebView 中显示，标记为 `external`（外部已有）。
2. 已有可访问但无法确认的服务时，要求用户确认是否显示；无论是否显示都不接管它。
3. 地址不可访问时，才查找已安装的 `dsh`。若 App bundle 内私有插件完整、其保留解析路径没有被用户文件或指向实际未知目录的链接占用，则先创建一个只指向 bundle 的链接：

   ```text
   $DSH_HOME/profiles/node_modules/@dsd-pancake/dsh-desktop-notifications
     -> DSD Pancake.app/Contents/Resources/DSHNotifications
   ```

   接着用 DSH launcher（启动器）参数数组启动：

   ```text
   dsh --profile web --patch <App 内 cordis.patch.yml> --no-open --host 127.0.0.1 --port 3080
   ```

   `--patch` 是该进程参数，不会改写默认 profile；因此普通 `dsh web` 和浏览器直接访问的既有 DSH 都不会加载该插件。若普通浏览器访问的是 App 已启动的同一服务，DSH 会传送客户端模块，但模块因没有 WebKit 原生桥而不订阅会话、不申请权限、不发送通知。保留命名空间中的失效链接会修复到当前 bundle，支持移动／替换 App；仍指向未知实际目录的链接绝不覆盖。若插件资源、解析链接或带覆盖层的启动在网页就绪前失败，App 仅自动退回一次不带插件的标准 `dsh web` 启动，不循环重试。

4. 服务就绪后，只有满足“本 App 直接创建 + 进程身份仍匹配 + 该进程自身监听固定回环端口”的进程才标记为 `owned`（本应用拥有）。原生提醒桥也只在这个带覆盖层的 `owned` 进程有效；已有或后继的 external（外部已有）服务始终没有桥能力。

端口、PID 或命令文本都不足以证明归属。App 不使用 `pkill`，不扫描其他 PID，也不会把已存在的服务变成可停止对象。

## 依赖更新边界

更新流程与正常启动共享同一条“只停止 owned（本应用拥有）进程”的所有权规则：

1. 当前版本只从 App 实际选择的 `dsh --version` 读取；版本比较实现 SemVer（语义版本）预发布规则，`rc.10` 不会被字符串顺序误判为早于 `rc.2`，build metadata（构建元数据）不影响优先级。
2. App 在当前 `dsh` 同目录和受支持的 Homebrew／`/usr/local` 路径中寻找 npm，执行只读 `npm root --global`，并要求解析符号链接后的 DSH 落在 `<global-root>/@deepseek-ai/dsh/` 内。相似路径前缀、源码 checkout（检出目录）和未知包管理器不会通过。
3. 检查只运行 `npm view @deepseek-ai/dsh dist-tags.latest --json`。结果与确认都显示为主窗口附属 sheet（窗口附属弹窗），不会强制把后台 App 抢到前台；只有用户在第二个确认步骤点击“更新”，才准备写操作。
4. owned DSH 先收到一次 `SIGTERM`；App 等待主进程回收和 stdout/stderr 自然 EOF。若端口随后出现 external 服务、归属失效或十五秒仍未收敛，更新终止，不使用 `SIGKILL`。
5. 安装使用结构化可执行文件与固定参数数组，不经过 Shell（命令解释器），不接受页面或用户文本作为命令参数，不调用 `sudo`。命令输出进入独立的有界、脱敏内存日志；npm 最长运行十分钟。
6. 安装结束后重新执行同一路径的 `dsh --version`；校验通过或失败都会恢复正常启动预检。失败不会循环重装、自动降级或修改 `$DSH_HOME`。

检查／更新任务存在时，AppKit 退出会被暂时取消并提示等待，避免 App 在 npm 写入全局包的中途自行退出。

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

## 日志与本地数据

子进程 stdout/stderr 只保留在内存中的有界环形日志中。常见 token、Authorization、Cookie 等敏感键值会被遮盖，日志默认不落盘。

网页数据由 WebKit 按 App bundle ID 保存；用户偏好只保存上次手动选择的 `dsh` 路径。删除 App 不会删除 DSH 的数据。fork（派生）后如需和原 App 并存，应先改掉 `CFBundleIdentifier`，以获得独立的单实例锁与 WebKit 数据命名空间。

## 本地打包

项目使用 Swift Package Manager。`scripts/local-release/build-app.zsh` 将 Release 可执行文件、`Info.plist`、两套图标和四个已构建的 App 私有插件文件放入 `.app` 后，使用 `codesign --sign -` 完成无身份的本机 ad-hoc 签名。`PancakeAppIcon` 是由 `Resources/AppIcon.png` 生成的 Finder／原生通知 bundle 身份图标，`DockIcon` 只在运行时显示于 Dock，二者可独立调整留白与构图；`verify-app.zsh` 先校验这份签名，再用严格白名单检查 bundle，拒绝 DSH、Node.js、`node_modules`、第三方插件、网页资源、测试夹具、额外可执行文件和符号链接。`build-dmg.zsh` 只把已通过检查的 App 与指向 `/Applications` 的快捷入口封装为只读压缩 DMG（磁盘映像），`verify-dmg.zsh` 会真实挂载映像并再次验证其中的 App；`build-release.zsh` 是串联整套流程的单一入口。

这保证“App 是壳”是可检查的包结构，而不只是文档承诺。

## 验证

```zsh
zsh scripts/verify.zsh
```

验证器覆盖状态机、单实例、日志脱敏、导航、WebKit 持久化配置、私有插件解析链接、桥协议、通知前台策略与去重、SemVer（语义版本）与 npm 路径边界、受控单次命令、受控 HTTP 探测、进程创建／回收／归属和退出门控。文档中的脚本固定跳过当前 3080，以免读取用户正在使用的服务。
