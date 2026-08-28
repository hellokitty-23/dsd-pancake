# 构建与运行

## 前置条件

需要一台 macOS 13 或更高版本的 Mac，并已安装：

- Swift Command Line Tools；
- 用户自己管理的 DSH 与其运行所需的 Node.js。

DSD Pancake 不会自动安装或升级这些依赖。它只查找已经存在且可执行的 `dsh`：上次手动选择的路径优先，其次是 `/opt/homebrew/bin/dsh` 和 `/usr/local/bin/dsh`。App 每小时分别静默检查 App 与 DSH 的可选更新，并只保存最近检查时间与最小版本缓存；发现更新时仅在壳的原生标题栏显示图标。App 菜单可立即统一检查两者；DSH 只有用户在原生确认中点击“更新 DSH”，且当前 `dsh` 已验证为 `@deepseek-ai/dsh` 的全局 npm 安装时，才会修改该安装。

当前开发与受控验证基线为 `@deepseek-ai/dsh 0.1.1-rc.2`。DSH 上游目前仍标注为 Developer preview（开发者预览），后续版本可能包含 breaking changes（破坏性变更）。基础壳与 DSH Web UI（网页界面）的兼容性，和 App 私有提醒／终端插件的兼容性需要分别判断：某项集成不可用时基础 Web UI 仍可能正常工作；只有带 App 私有覆盖层的 DSH 在页面就绪前退出时，App 才会自动重试一次不带插件的启动，不能据此推断未知 DSH 版本中的 client API（客户端接口）仍兼容。

## 编译与受控验证

在仓库根目录执行：

```zsh
zsh scripts/verify.zsh
```

该脚本会编译并验证状态机、单实例锁、日志脱敏、导航策略、受控 HTTP 服务和受控子进程。它明确不访问你当前正在使用的 `127.0.0.1:3080`；不要改用直接探测该地址的模式，除非你确实要对该服务做只读探测。

## 打包

```zsh
./scripts/local-release/build-release.zsh
```

一键脚本会依次构建 App、生成 DMG（磁盘映像），再只读挂载 DMG 检查其中的 App 签名、内容白名单和 `Applications` 快捷入口。它会生成：

```text
local-release/DSD Pancake.app
local-release/DSD Pancake.app.zip
local-release/DSD Pancake.build.plist
local-release/DSD-Pancake-v0.0.3-arm64.dmg
local-release/DSD-Pancake-v0.0.3-arm64.dmg.sha256
```

build plist（构建映射文件）的 `AppPath` 与 `ArchivePath` 只记录输出文件名，不记录构建机器的绝对路径；它仍是本地构建映射，不应作为运行时配置。

若目标目录已有同名产物，脚本会拒绝覆盖。请显式选择一个空目录，例如：

```zsh
DSHD_OUTPUT_DIR="$PWD/release/dev" ./scripts/local-release/build-release.zsh
```

如需逐步排障，可分别执行：

```zsh
./scripts/local-release/build-app.zsh
./scripts/local-release/verify-app.zsh "local-release/DSD Pancake.app"
./scripts/local-release/build-dmg.zsh "local-release/DSD Pancake.app"
./scripts/local-release/verify-dmg.zsh "local-release/DSD-Pancake-v0.0.3-arm64.dmg"
```

打包校验会拒绝包含 DSH、Node.js、`node_modules`（依赖目录）、第三方插件、网页资源、测试夹具或额外可执行文件的 App bundle（应用包）。唯一允许的插件内容是 App 自带提醒和终端包各自的四个已构建文件：`package.json`、`cordis.patch.yml`、`lib/index.js` 和 `lib/client.js`；另外只允许 SwiftTerm `1.20.0` 所需、由 `Bundle.main.resourceURL` 从标准 `Contents/Resources` 读取的 `SwiftTerm_SwiftTerm.bundle/Shaders.metal`。SwiftTerm 为 MIT License，完整声明见 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。

图标也分为两个职责：`Resources/AppIcon.png` 会生成 bundle 的 `PancakeAppIcon` 身份图标，供 Finder 和 macOS 原生通知使用；`Resources/DockIcon.png` 只在运行时显示于 Dock。两者独立生成，调整通知小图标的留白不会再缩小 Dock 图标。

## 安装到“应用程序”

`DSD Pancake.app` 本身就是一个可移动的 macOS App bundle（应用包）。项目使用标准 DMG 拖拽安装，不使用会登记系统安装回执或可能要求管理员权限的 PKG（系统安装包）。

1. 若已有 DSD Pancake 正在运行，先按一次 `⌘Q` 叫出确认层，再按一次 `⌘Q` 退出；不要覆盖正在运行的 `.app`。
2. 双击打开与版本对应的 `local-release/DSD-Pancake-v<version>-arm64.dmg`。公开分发时必须一并提供同名 `.sha256` sidecar（校验文件）；可用 `shasum -a 256` 手动核对，或先让 App 的更新 Popover 校验下载文件。
3. 将 `DSD Pancake.app` 拖到同一窗口内的 `Applications` 快捷入口；若 Finder（访达）询问，选择“替换”。
4. 从“应用程序”启动 `DSD Pancake`。

同一 bundle ID（App 身份）下的正常替换会保留壳自身的 WebKit 登录状态和窗口偏好。App 仍要求目标 Mac 已独立安装可运行的 `dsh`；复制这个 `.app` 不会复制、安装或升级 DSH、Node.js 或用户插件。它只携带两个随 App 使用的私有插件：完成提醒与底部终端。菜单中的显式 npm 更新是独立的用户确认操作，不属于 App 安装或替换流程。

本地构建会在 App 组装完成后执行 `codesign --sign -`：这是 macOS 自带的 ad-hoc（无身份）签名，用于绑定最终 App 的身份并使通知权限能够可靠登记。它不需要 Xcode、Apple 开发者账号、证书或公证；自己在构建机器上使用不需要额外步骤。DMG 只封装这份 App 并提供拖拽入口，不改变其信任等级。若把 DMG 或 ZIP 发给其他人，macOS 仍可能显示开发者验证提示；正式对外分发仍应另行配置 Developer ID（开发者身份）签名、hardened runtime（强化运行时）与 Apple notarization（公证）。

## 启动后的行为

1. App 先检查 `http://127.0.0.1:3080/`。
2. 若该地址已有服务，App 只在确认后显示或保留它，不会停止、重启或接管它。
3. 若端口空闲，App 才会启动当前找到的 `dsh`，并仅管理本次直接创建的进程。若 bundle 内私有插件可用，启动命令会是 `dsh --profile web --patch <提醒 patch> --patch <终端 patch> --no-open --host 127.0.0.1 --port 3080`；每个覆盖层都只作用于这一次子进程。
4. 关闭窗口只隐藏窗口；第一次 `⌘Q` 总会显示安全退出确认层。只有可验证为本次 App 创建的 DSH 才可能收到一次 `SIGTERM`。

确认层会说明本次退出的范围：四秒内再次按 `⌘Q` 时，若 DSH 是本次 App 创建且归属仍有效，会先请求停止它再退出；若服务是 App 打开前已存在的 external（外部已有）服务，或当前没有 DSH，则只退出 App，不会停止服务。`Esc`、取消、背景点击或超时都会取消退出，不发送信号。

## 检查可选更新

App 启动时及之后每隔约一小时会分别发起两个彼此独立的只读检查，并记录每一项最后一次尝试时间。它不弹窗、不下载、不安装；睡眠恢复后最多补一轮已到期检查。发现可选更新时，壳层标题栏左侧以强调色显示更新图标，点击后出现原生 Popover。菜单中的 `检查更新…` 会立即刷新并汇总两项结果；若确认当前没有可选更新，图标立即隐藏，后续仍可从菜单再次检查。一项网络或环境错误不会掩盖另一项结果。

### DSD Pancake

- 当前版本与 build（构建号）来自 App 自身的 `Info.plist`；
- 最新版本只向 `https://github.com/hellokitty-23/dsd-pancake/releases/latest` 发送 `HEAD`（仅响应头）请求，并读取最终重定向标签，不使用 GitHub REST API 的未登录速率额度。检查使用无 Cookie、无凭据缓存的临时 `URLSession`；只接受固定项目路径中的稳定 SemVer（语义版本）标签，DMG 地址按同一标签和固定 arm64 发布命名生成；
- 有新版本时，原生 Popover 显示当前／最新版本，并先只读取同一 tag 下的 `.sha256` sidecar；只有 sidecar 严格有效时才显示“下载更新”，用户点击后才接受 GitHub 明确受控的 Release 资产跳转并下载到同目录 `.part` 临时文件；
- App 对临时文件流式计算 SHA-256（安全散列算法），仅在 sidecar 的单行哈希和精确 DMG 文件名都匹配时，才原子移动到 Downloads（下载）目录。已有同名文件不会覆盖，会使用递增序号；
- sidecar 缺失、超大、格式错误、跳转不可信或哈希不匹配时，App 不会保留该下载，界面只允许用户打开发布页；
- 下载完成后，App 仍不会自动打开 DMG、挂载、安装、替换或重启。用户可点击“在 Finder 中显示”或“打开 DMG”，退出旧 App 后按上面的标准拖拽安装步骤完成替换。

### DeepSeek Harness

- 当前版本来自当前实际选择的绝对路径执行 `dsh --version`；
- 最新版本来自与该 DSH 同一安装前缀的 npm 查询 `@deepseek-ai/dsh` 的 `dist-tags.latest`；
- App 会把解析后的 `dsh` 路径约束在该 npm 的全局 `@deepseek-ai/dsh` 包目录中。手动选择的未知安装、源码 checkout（检出目录）和临时 `npx` 运行不会通过该边界；
- 有更新时，主窗口附属弹窗显示两个版本和 npm 绝对路径；它不会强制把后台 App 抢到前台。点击“稍后”不产生写操作；点击“更新 DSH”才进入停止和安装流程；
- 只有仍可验证归属的 owned（本应用拥有）DSH 会收到一次 `SIGTERM`。external（外部已有）服务不会被停止，也不会在其运行期间修改全局安装；
- 进程与两路日志自然收敛后，App 不经过 Shell（命令解释器），以固定参数执行 `npm install --global @deepseek-ai/dsh@latest --no-audit --no-fund`，最长等待十分钟；
- npm 成功后再次执行同一 `dsh --version`，确认安装版本不低于检查时的 `latest`，随后按正常启动流程重新探测并启动 DSH。

更新不会使用 `sudo`、不会请求管理员权限、不会发送 `SIGKILL`，也不会改写 `$DSH_HOME`。若 npm 全局目录对当前用户不可写，弹窗会显示失败原因，并重新走正常 DSH 启动流程。

## 完成提醒

提醒只存在于 DSD Pancake 自己创建的 DSH 进程：App 会为那一次 `--patch` 启动准备一个位于 `$DSH_HOME/profiles/node_modules/@dsd-pancake/` 的 App 命名空间符号链接，让 DSH 解析 bundle 内的私有插件。它不会修改默认 profile 的 package、bundle 或 patch 配置；手动运行 `dsh web` 和 App 发现的既有服务都不会加载该插件。普通浏览器若访问 App 已启动的同一个服务，会收到模块文件但没有 WebKit 原生桥，因此不订阅会话、不申请权限、不发送通知。

首次打开 DSD Pancake 时，macOS 会在需要时询问通知权限。授权后，只有 App 自己启动的 DSH 中，顶层会话的普通回复，或 goal（目标）进入完成／受阻，才会显示固定文案的系统通知。通知不含对话正文、任务标题、路径或 Cookie；在默认的“仅在未聚焦时”模式下，当 DSD Pancake 正在前台且窗口可见时，通知会被静默抑制，避免重复打扰。点击通知会恢复 App 主窗口。

如需调整，打开 macOS 菜单栏中的 `消息 → 完成提醒`。`永不` 会立即忽略新的桥事件；`仅在未聚焦时`（默认）会在 App 不在前台、窗口隐藏或最小化时投递；`一律` 会在所有状态下投递，并允许前台横幅。选择会立即生效且持久化；它不会重启 DSH、卸载私有插件或撤销 macOS 已授予的通知权限。

若私有插件文件缺失、链接路径被用户文件或仍指向可访问目录的链接占用，或带覆盖层的 DSH 在网页就绪前退出，App 仍会安全启动核心壳：前两种情况直接没有提醒，最后一种只自动退回一次不带插件的标准 `dsh web` 启动。保留命名空间内的失效旧链接会修复到当前 bundle，以支持移动／替换 App。不会安装插件、改写用户文件、反复重试或触碰已有服务。

## 底部终端

只有 App 本次创建、仍验证为 owned（本应用拥有）且终端 patch 已准备的 DSH 才会启用 App 原生标题栏右侧的底部终端按钮。普通浏览器、external（外部已有）服务和没有有效 workspace 的会话都不能开启该能力。

- 点击标题栏按钮、按 `⌘J` 或选择“视图 → 显示/隐藏终端”展开／收起；面板高度默认约 280px、最小约 160px、最高为可用窗口高度的 50%，可拖动分隔线调整；面板只从左侧工程栏右边开始停靠，工程栏始终保持完整可操作；右侧 DSH 对话流会为当前 dock 高度预留空间，因此消息和输入框会一起上移，而不会被终端覆盖；
- 标签栏中的 `+` 会在当前 workspace 新建独立 shell，点击标签可切换；收起只隐藏 panel（面板），不结束 shell；标签内 `×` 或终端内执行 `exit` 只终止该标签的 shell；App 退出或服务 ownership 丢失时会清理全部 App 创建的 PTY process group（进程组）；
- 同一 workspace 可以有多个独立 shell；同 workspace 的不同 DSH 会话恢复最后选择的标签，不同 workspace 使用互相隔离的标签；第一版仅在本次 App 运行中保存这些状态；
- 终端使用 SwiftTerm `1.20.0` 的真实 `forkpty`，支持 ANSI、交互输入、resize（尺寸变化）与 Ctrl-C。网页 bridge 不接受 command（命令）、脚本、`eval`、环境变量或任意进程参数，终端输入/输出不写日志。

## 本地数据与卸载

WebKit 的登录状态、Cookie 和缓存由 macOS 按 App bundle ID 存储。删除 `.app` 不会删除 DSH、Node.js、用户 DSH 插件或 DSH 数据；如需清除壳自身的网页数据，应先完全退出 App，再仅删除与该 bundle ID 对应的 WebKit／Application Support／Preferences 目录。App 为私有提醒和终端插件创建的命名空间符号链接不会加载到普通 DSH；如需手工移除，先退出 App 后删除 `$DSH_HOME/profiles/node_modules/@dsd-pancake/dsh-desktop-notifications` 和 `$DSH_HOME/profiles/node_modules/@dsd-pancake/dsh-desktop-terminal` 即可。

若你 fork（派生）本项目并要与原 App 并存，请在首次运行前改掉 [Resources/Info.plist](../Resources/Info.plist) 中的 `CFBundleIdentifier`。bundle ID 同时也是单实例锁与 WebKit 数据命名空间的一部分。
