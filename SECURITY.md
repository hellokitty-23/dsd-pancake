# 安全说明

DSD Pancake 会启动用户明确安装的本机 `dsh`，并把本机网页放入 `WKWebView`。App 自带的页面内私有插件会按功能读取 DSH 公开 session snapshot（会话快照）或正式 slot（插槽），但这些只读投影留在页面进程内；原生层不应接收对话正文、账号信息、Cookie、输入内容或 API 密钥。原生视觉桥只读取布局尺寸与已计算表面颜色，提醒／终端 bridge 只接受下文定义的最小结构化字段。

如果发现以下问题，请不要在公开 Issue 中附上真实凭据、Cookie、完整日志或个人路径：

- App 可能停止非本次创建的进程；
- 日志可能未脱敏；
- 页面内容或 Cookie 可能泄露给原生层；
- 外部链接或非本机页面可能绕过导航边界。
- terminal bridge（终端通信桥）可能接受命令、脚本、非预期字段或非本机／非主 frame（主页面）消息；
- App 创建的 PTY（伪终端）或其子进程在关闭终端、失去 DSH ownership（进程归属）或 App 退出后遗留。
- 自动更新检查可能在未获用户点击时下载、安装、替换或启动文件；
- App 更新下载可能接受非固定 Release、非受信任重定向、错误 SHA-256 sidecar（校验文件），或覆盖既有 Downloads 文件。

仓库启用 GitHub Private Security Advisories（私密安全通报）后，请优先通过仓库的 **Security** 页面提交报告。若该入口尚未启用，只提交最小可复现描述，并要求维护者提供私下沟通渠道。

本项目不处理 DSH、Node.js 或第三方插件自身的安全漏洞；这些问题应报告给相应上游项目。

App 私有插件在发行前采用 fail-closed（异常即拒绝）门禁：host 入口只接受带注释的精确 `export function apply() {}`，不会被 metadata verifier 以宿主 Node 权限动态导入；client metadata 只在清空环境、禁止文件／网络／子进程权限、关闭动态 code generation（动态代码生成）且有同步与进程级超时的独立 VM 子进程内求值。清单还与 Swift `PrivatePluginKind` 及控制器映射做双向、同序核对，并拒绝 raw-valued（显式原始值）、逗号合并或其它非规范 enum case（枚举分支）。签名前会对 staging bundle 直接重复 metadata 校验，并要求其中的四个发行文件与已通过行为 verifier 的 source 逐字节一致；这些检查不扩大 App bundle 白名单。

DSD Pancake 自身的更新检查以 App 与 DSH 两个独立来源每小时静默执行一次，并只保存最近检查时间及最小版本缓存；它不弹窗、不下载、不安装。App 检查只向固定公开仓库的 GitHub `/releases/latest` 页面发送 `HEAD`（仅响应头）请求，使用无 Cookie、无凭据缓存的临时会话，不调用需要未登录速率额度的 REST API；它验证最终重定向的项目路径和稳定 SemVer 标签，再生成同一标签下固定命名的 arm64 DMG 与 `.sha256` sidecar 地址。状态只显示在 App 原生标题栏和主窗口内的原生 update overlay（更新浮层），不注入 DSH 网页。

用户打开原生 update overlay（更新浮层）后，App 只读取格式严格的单行 sidecar（`<64 位 hash><空白><精确 DMG 文件名>`）；sidecar 缺失／错误时界面只提供发布页。只有 sidecar 已验证、用户再点击“下载更新”后，App 才会下载 DMG。下载器只允许固定 GitHub 初始 URL 以及明确的 GitHub Release 资产跳转主机；文件只先写入本次创建的 `.part` 临时路径，流式 SHA-256（安全散列算法）匹配后才移动到 Downloads（下载）目录。它不会覆盖既有文件，取消、跳转异常或哈希不匹配时只移除本次临时文件，并且不会自动打开、挂载、安装、替换或重启 App。SHA-256 sidecar 只能验证与发布者公布的摘要一致，不能替代 Developer ID（开发者身份）签名、hardened runtime（强化运行时）或 Apple notarization（公证）。

底部终端只在本 App 创建且已验证归属的 DSH，并且本次私有 terminal patch（覆盖层）已准备时启用。正式 App 的 WebKit reply bridge（可回复通信桥）只接受 `127.0.0.1:3080` 的主 frame；隔离 Test App 只接受其自身 `Info.plist` 声明的非 `3080` 测试端口，并同时要求 Test bundle ID（测试应用身份）与 Test 标记成立。两种构建都以各自当前 local service origin（本机服务来源）做精确匹配，不能借环境变量让正式 App 改用测试端口，也不能让 Test App 接入正式 `3080`。bridge 还要求协议版本 `1` 和精确字段集；只允许 capability（能力）查询、已验证 workspace 路径同步，以及精确的“当前无工作区”状态。显示／收起仅由 App 原生标题栏、菜单或快捷键发起，网页不能请求。协议没有 command、脚本、`eval`、环境变量或进程参数字段，任何未知 action（动作）或额外字段均拒绝。为了让右侧对话避开原生 dock，App 还会向当前页面单向发送版本化的布尔开关与已钳制高度；它不经过 reply bridge，客户端只在正式 composer footer slot 中把它渲染为不可交互空白，网页伪造该事件也无法显示／收起终端、执行命令或读取本机数据。普通浏览器和 external（外部已有）DSH 没有 bridge，因此终端插件安全 no-op（无操作）。同一 workspace 的每个终端标签都有独立 PTY 和 process group（进程组）；原生层不把终端输入、输出、环境变量或路径写入日志，也不把它们回传网页；关闭终端标签、终端内 shell 正常退出、App 退出或 ownership 丢失时会按对应 PTY process group 清理。

菜单中的 DeepSeek Harness 更新只面向来源已验证的全局 `@deepseek-ai/dsh` npm 安装。检查阶段只读取版本和 npm 全局目录；写入前必须由用户在原生弹窗明确确认。实现不经过 Shell（命令解释器），不拼接页面文本，不使用 `sudo` 或 `SIGKILL`，也不会停止 external（外部已有）服务。npm 包安装本身会执行上游包允许的 lifecycle scripts（生命周期脚本）；因此用户仍应只使用可信 registry（包注册表），并把 registry 劫持、包供应链异常或来源边界绕过作为安全问题报告。
