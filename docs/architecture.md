# 架构

DSD Pancake 是一个 macOS 本机薄壳：原生 App 负责启动边界、窗口生命周期和安全退出；DSH 继续独立提供网页、功能与升级。

## 设计边界

```text
Finder
  │
  ▼
DSD Pancake.app
  ├─ 探测 http://127.0.0.1:3080/
  ├─ 必要时启动用户已有的 dsh
  ├─ 管理本次直接创建的子进程
  └─ 用一个持久 WKWebView 显示本机页面
                  │
                  ▼
          已独立安装的 DSH
```

App 不安装、升级、修改或打包 DSH、Node.js、插件与用户数据。它也不是通用浏览器、终端、远程管理器或全局进程清理工具。

## 模块

| 模块 | 职责 |
| --- | --- |
| 应用壳层 | AppKit 生命周期、SwiftUI 状态页、窗口视觉、WebKit 容器和退出确认层。 |
| 服务层 | 固定本机地址、DSH 可执行文件定位、启动环境与有界 HTTP 探测。 |
| 进程层 | 直接子进程创建、stdout/stderr 有界日志、PID/PGID/启动时间复核、监听 socket 复核与正常终止。 |
| 状态层 | 串行状态归约、单实例锁和异步退出事务门控。 |
| 网页层 | 同源页面与外部链接的导航策略。 |
| 受控验证器 | 不依赖真实 DSH 的受控验证器。 |

应用层通过 `AppCoordinator` 编排，Core 不直接依赖 SwiftUI 或窗口对象。

## 启动与服务归属

启动时先取得单实例锁，然后探测固定地址 `127.0.0.1:3080`：

1. 已有可识别 DSH 时，直接在 WebView 中显示，标记为 `external`（外部已有）。
2. 已有可访问但无法确认的服务时，要求用户确认是否显示；无论是否显示都不接管它。
3. 地址不可访问时，才查找已安装的 `dsh`，并以参数数组启动：

   ```text
   dsh web --no-open --host 127.0.0.1 --port 3080
   ```

4. 服务就绪后，只有满足“本 App 直接创建 + 进程身份仍匹配 + 该进程自身监听固定回环端口”的进程才标记为 `owned`（本应用拥有）。

端口、PID 或命令文本都不足以证明归属。App 不使用 `pkill`，不扫描其他 PID，也不会把已存在的服务变成可停止对象。

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

## 日志与本地数据

子进程 stdout/stderr 只保留在内存中的有界环形日志中。常见 token、Authorization、Cookie 等敏感键值会被遮盖，日志默认不落盘。

网页数据由 WebKit 按 App bundle ID 保存；用户偏好只保存上次手动选择的 `dsh` 路径。删除 App 不会删除 DSH 的数据。fork（派生）后如需和原 App 并存，应先改掉 `CFBundleIdentifier`，以获得独立的单实例锁与 WebKit 数据命名空间。

## 本地打包

项目使用 Swift Package Manager。`scripts/local-release/build-app.zsh` 将 Release 可执行文件、`Info.plist` 和图标放入 `.app`；`verify-app.zsh` 用严格白名单检查 bundle，拒绝 DSH、Node.js、插件、网页资源、测试夹具、额外可执行文件和符号链接。

这保证“App 是壳”是可检查的包结构，而不只是文档承诺。

## 验证

```zsh
zsh scripts/verify.zsh
```

验证器覆盖状态机、单实例、日志脱敏、导航、WebKit 持久化配置、受控 HTTP 探测、进程创建／回收／归属和退出门控。文档中的脚本固定跳过当前 3080，以免读取用户正在使用的服务。
