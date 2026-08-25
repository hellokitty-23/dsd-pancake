# 构建与运行

## 前置条件

需要一台 macOS 13 或更高版本的 Mac，并已安装：

- Swift Command Line Tools；
- 用户自己管理的 DSH 与其运行所需的 Node.js。

DSD Pancake 不会安装或升级这些依赖。它只查找已经存在且可执行的 `dsh`：上次手动选择的路径优先，其次是 `/opt/homebrew/bin/dsh` 和 `/usr/local/bin/dsh`。

## 编译与受控验证

在仓库根目录执行：

```zsh
zsh scripts/verify.zsh
```

该脚本会编译并验证状态机、单实例锁、日志脱敏、导航策略、受控 HTTP 服务和受控子进程。它明确不访问你当前正在使用的 `127.0.0.1:3080`；不要改用直接探测该地址的模式，除非你确实要对该服务做只读探测。

## 打包

```zsh
./scripts/local-release/build-app.zsh
./scripts/local-release/verify-app.zsh "local-release/DSD Pancake.app"
```

脚本会生成：

```text
local-release/DSD Pancake.app
local-release/DSD Pancake.app.zip
local-release/DSD Pancake.build.plist
```

若目标目录已有同名产物，脚本会拒绝覆盖。请显式选择一个空目录，例如：

```zsh
DSHD_OUTPUT_DIR="$PWD/release/dev" ./scripts/local-release/build-app.zsh
```

打包校验会拒绝包含 DSH、Node.js、插件、网页资源、测试夹具或额外可执行文件的 App bundle（应用包）。

## 安装到“应用程序”

`DSD Pancake.app` 本身就是一个可移动的 macOS App bundle（应用包），不需要额外安装器。

1. 若已有 DSD Pancake 正在运行，先按一次 `⌘Q` 叫出确认层，再按一次 `⌘Q` 退出；不要覆盖正在运行的 `.app`。
2. 在 Finder（访达）中打开仓库的 `local-release` 文件夹。
3. 将 `DSD Pancake.app` 拖入“应用程序（Applications）”文件夹；若 Finder 询问，选择“替换”。
4. 从“应用程序”启动 `DSD Pancake`。

同一 bundle ID（App 身份）下的正常替换会保留壳自身的 WebKit 登录状态和窗口偏好。App 仍要求目标 Mac 已独立安装可运行的 `dsh`；复制这个 `.app` 不会复制、安装或升级 DSH、Node.js 或插件。

本地构建的包未签名。自己在构建机器上使用不需要额外步骤；若把 ZIP 发给其他人，macOS 可能显示开发者验证提示，正式对外分发应另行配置签名和公证。

## 启动后的行为

1. App 先检查 `http://127.0.0.1:3080/`。
2. 若该地址已有服务，App 只在确认后显示或保留它，不会停止、重启或接管它。
3. 若端口空闲，App 才会启动当前找到的 `dsh`，并仅管理本次直接创建的进程。
4. 关闭窗口只隐藏窗口；第一次 `⌘Q` 总会显示安全退出确认层。只有可验证为本次 App 创建的 DSH 才可能收到一次 `SIGTERM`。

确认层会说明本次退出的范围：四秒内再次按 `⌘Q` 时，若 DSH 是本次 App 创建且归属仍有效，会先请求停止它再退出；若服务是 App 打开前已存在的 external（外部已有）服务，或当前没有 DSH，则只退出 App，不会停止服务。`Esc`、取消、背景点击或超时都会取消退出，不发送信号。

## 本地数据与卸载

WebKit 的登录状态、Cookie 和缓存由 macOS 按 App bundle ID 存储。删除 `.app` 不会删除 DSH、Node.js、DSH 插件或 DSH 数据；如需清除壳自身的网页数据，应先完全退出 App，再仅删除与该 bundle ID 对应的 WebKit／Application Support／Preferences 目录。

若你 fork（派生）本项目并要与原 App 并存，请在首次运行前改掉 [Resources/Info.plist](../Resources/Info.plist) 中的 `CFBundleIdentifier`。bundle ID 同时也是单实例锁与 WebKit 数据命名空间的一部分。
