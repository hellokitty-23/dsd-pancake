# DSD Pancake

DSD Pancake 是一个 macOS 薄壳：它把用户**已经安装**的 DSH Web UI 显示在原生 `WKWebView` 中，并在本机服务尚未运行时后台启动它。

本项目是独立的本地桌面壳，不是 DSH 的安装器、升级器或功能分支，也不代表 DSH 的官方发布。

## 它做什么

- 打开固定的本机地址 `http://127.0.0.1:3080/`；
- 端口空闲时，调用用户当前安装的 `dsh web --no-open --host 127.0.0.1 --port 3080`；
- 不打开 Terminal.app，不打开默认浏览器；
- 只会停止当前 App 会话亲自创建、并且仍能验证归属的 DSH 进程；
- 将同源 DSH 页面留在 App 内，把用户点击的外部链接交给默认浏览器；
- 提供标准 macOS 编辑快捷键、首次 `⌘Q` 退出确认，以及关闭窗口后继续保留当前网页会话的行为。

## 它明确不做什么

- 不打包、安装、升级、降级或修改 DSH、Node.js、插件、配置、数据库或账号数据；
- 不扫描、接管或停止已存在的本机服务；
- 不提供通用终端、任意命令执行、多标签页或远程 DSH 管理；
- 不收集遥测数据，也不将网页内容、Cookie 或会话数据写入项目日志。

## 前置条件

- macOS 13 或更高版本；
- 可用的 Swift Command Line Tools；
- 已独立安装可运行的 `dsh`，以及该 DSH 所需的 Node.js 环境。

App 会依次检查上次手动选择的可执行文件、`/opt/homebrew/bin/dsh` 和 `/usr/local/bin/dsh`。找不到时，界面会让用户手动选择现有的 `dsh` 可执行文件。

## 构建、打包与安装

完整说明见 [docs/build-and-run.md](./docs/build-and-run.md)。在仓库根目录执行：

```zsh
zsh scripts/verify.zsh
zsh scripts/local-release/build-app.zsh
zsh scripts/local-release/verify-app.zsh "local-release/DSD Pancake.app"
```

`scripts/verify.zsh` 会跳过对当前正在使用的 `127.0.0.1:3080` 的 HTTP 探测；其余检查只使用受控子进程和随机端口测试夹具。

打包完成后会得到 `local-release/DSD Pancake.app`。先退出正在运行的 DSD Pancake，再在 Finder（访达）中将这个 `.app` 拖入“应用程序（Applications）”文件夹；已有同名 App 时选择“替换”，随后从“应用程序”启动它。

打包脚本生成的是本地使用的未签名 `.app`，不会自动写入 `/Applications`，也不会安装 DSH。公开源码、对外分发二进制和 macOS 签名／公证是三件独立的事；若要向其他用户直接发布下载包，应另行建立签名与公证流程。

## 结构

```text
Sources/                    macOS 应用层、核心服务层与受控验证器
Resources/                  Info.plist 与应用图标
scripts/                    受控验证、本地 .app 打包与结构校验
docs/                       公开架构与使用文档
```

设计细节见 [docs/architecture.md](./docs/architecture.md)。贡献前请阅读 [CONTRIBUTING.md](./CONTRIBUTING.md)，安全问题请阅读 [SECURITY.md](./SECURITY.md)。

## 许可证

本项目采用 [MIT License](./LICENSE)。
