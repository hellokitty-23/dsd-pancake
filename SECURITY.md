# 安全说明

DSD Pancake 会启动用户明确安装的本机 `dsh`，并把本机网页放入 `WKWebView`。它不应获取网页内容、账号信息、Cookie 或 API 密钥。

如果发现以下问题，请不要在公开 Issue 中附上真实凭据、Cookie、完整日志或个人路径：

- App 可能停止非本次创建的进程；
- 日志可能未脱敏；
- 页面内容或 Cookie 可能泄露给原生层；
- 外部链接或非本机页面可能绕过导航边界。
- terminal bridge（终端通信桥）可能接受命令、脚本、非预期字段或非本机／非主 frame（主页面）消息；
- App 创建的 PTY（伪终端）或其子进程在关闭终端、失去 DSH ownership（进程归属）或 App 退出后遗留。

仓库启用 GitHub Private Security Advisories（私密安全通报）后，请优先通过仓库的 **Security** 页面提交报告。若该入口尚未启用，只提交最小可复现描述，并要求维护者提供私下沟通渠道。

本项目不处理 DSH、Node.js 或第三方插件自身的安全漏洞；这些问题应报告给相应上游项目。

DSD Pancake 自身的更新检查只向固定公开仓库的 GitHub `/releases/latest` 页面发送 `HEAD`（仅响应头）请求，不调用需要未登录速率额度的 REST API；它验证最终重定向的项目路径和稳定 SemVer 标签，再生成同一标签下固定命名的 arm64 DMG 地址。它不会下载、解包、安装、替换或重启 App；若返回地址离开固定 GitHub 项目路径，结果会被拒绝。

底部终端只在本 App 创建且已验证归属的 DSH，并且本次私有 terminal patch（覆盖层）已准备时启用。其 WebKit reply bridge（可回复通信桥）要求 `127.0.0.1:3080` 的主 frame、版本 `1` 和精确字段集；只允许 capability（能力）查询、已验证 workspace 路径同步，以及精确的“当前无工作区”状态。显示／收起仅由 App 原生标题栏、菜单或快捷键发起，网页不能请求。协议没有 command、脚本、`eval`、环境变量或进程参数字段，任何未知 action（动作）或额外字段均拒绝。为了让右侧对话避开原生 dock，App 还会向当前页面单向发送版本化的布尔开关与已钳制高度；它不经过 reply bridge，客户端只在正式 composer footer slot 中把它渲染为不可交互空白，网页伪造该事件也无法显示／收起终端、执行命令或读取本机数据。普通浏览器和 external（外部已有）DSH 没有 bridge，因此终端插件安全 no-op（无操作）。同一 workspace 的每个终端标签都有独立 PTY 和 process group（进程组）；原生层不把终端输入、输出、环境变量或路径写入日志，也不把它们回传网页；关闭终端标签、终端内 shell 正常退出、App 退出或 ownership 丢失时会按对应 PTY process group 清理。

菜单中的 DeepSeek Harness 更新只面向来源已验证的全局 `@deepseek-ai/dsh` npm 安装。检查阶段只读取版本和 npm 全局目录；写入前必须由用户在原生弹窗明确确认。实现不经过 Shell（命令解释器），不拼接页面文本，不使用 `sudo` 或 `SIGKILL`，也不会停止 external（外部已有）服务。npm 包安装本身会执行上游包允许的 lifecycle scripts（生命周期脚本）；因此用户仍应只使用可信 registry（包注册表），并把 registry 劫持、包供应链异常或来源边界绕过作为安全问题报告。
