# 贡献说明

DSD Pancake 的目标是可靠的本机薄壳，不是功能越来越多的 DSH 替代品。提交前请先判断改动是否仍在这个边界内。

## 不变的边界

- 不捆绑或自动安装 DSH、Node.js、用户／第三方插件和用户数据；App 自带的提醒、终端、操作折叠、双 `Esc` 快捷键四个私有插件只作为当前壳的一部分随包发布，最多在保留命名空间维护解析链接，绝不改写用户 profile（配置档）的 package、bundle 或 patch 配置；菜单中的 DSH 更新仅允许在来源已验证且用户再次确认后执行固定的全局 npm 更新流程；
- 不增加网页可调用的通用 Shell、任意 bridge 命令执行、远程管理或全局进程扫描；
- 端口可达不等于进程归属。只有本次 App 直接创建并复核通过的进程才可被停止；
- 网页页面保持 DSH 自己控制。页面内私有插件只可通过 DSH 公开 session snapshot（会话快照）和正式 slot（插槽）实现只读投影；原生层不得接收对话正文、账号、Cookie、输入内容或 API 密钥，视觉桥只允许布局尺寸与已计算表面颜色；
- 终端 bridge 只能携带经过 DSH 正式 service（服务）得到的最小 workspace 标识与“当前无工作区”状态；显示／收起只能由原生壳发起，不得增加 command、脚本、`eval`、环境变量或任意进程参数；如需为原生 dock 调整对话布局，只能使用 App 到页面的版本化纯视觉状态和 DSH 正式 slot，不得扫描或改写 DSH DOM；
- 收起终端不能结束 shell；关闭当前终端标签、终端内 shell 正常退出、App 退出和 ownership 丢失必须回收对应 PTY process group（进程组）；不同 workspace 不得共用 PTY，同一 workspace 的不同标签也不得共用 PTY；
- 不能为了“更方便”把 external（App 打开前已有）服务变为可停止对象。

## 本地检查

```zsh
zsh scripts/verify.zsh
zsh -n scripts/local-release/build-app.zsh
zsh -n scripts/local-release/build-dmg.zsh
zsh -n scripts/local-release/build-release.zsh
zsh -n scripts/local-release/build-test-app.zsh
zsh -n scripts/local-release/verify-app.zsh
zsh -n scripts/local-release/verify-dmg.zsh
git diff --check
```

验证脚本固定跳过 `127.0.0.1:3080`，不会只读访问用户正在使用的 DSH 服务。

## 不应提交的内容

不要提交本机构建产物、`.app`、DMG（磁盘映像）、ZIP、`.build`、`local-release`、本地 DSH 配置、日志、Cookie、终端记录、截图、`.env` 或个人路径。`.gitignore` 已覆盖常见情况，但提交前仍应检查：

```zsh
git status --short
git diff --cached --check
```

## 文档和提交

项目按下表维护 single source of truth（单一事实源），不要在多个文档中各自维护会漂移的当前版本或完整实现细节：

| 改动内容 | Canonical source（权威来源） | 必须同步检查 |
| --- | --- | --- |
| 用户可见能力、限制与快速开始 | [README.md](./README.md) | 行为变化时检查架构、安全与构建文档是否仍成立 |
| 启动／停止、进程归属、bridge、插件、终端和更新状态流 | [docs/architecture.md](./docs/architecture.md) 与对应实现／验证 | 更新 README 中的用户结果；安全边界变化时更新 SECURITY |
| 构建命令、产物、bundle identity（应用身份）与 Test 隔离 | [docs/build-and-run.md](./docs/build-and-run.md) 与 `scripts/local-release/` | 同步打包白名单、验证脚本和 fork 清单 |
| 信任边界、敏感数据、网络与下载约束 | [SECURITY.md](./SECURITY.md) | 同步 bridge／下载实现和负例验证 |
| App 当前版本与 build number（构建号） | [Resources/Info.plist](./Resources/Info.plist) | 文档只写 `<version>`；发布产物名由脚本读取，不再手写数字版本 |
| 四个 App 私有插件的打包清单与元数据 | [scripts/private-plugins.json](./scripts/private-plugins.json) | 同步 Core 插件声明、资源、table-driven verifier（表驱动验证器）与用户文档中的能力名称 |

- 提交信息说明用户可感知的结果，不记录本机用户名、绝对路径或服务数据。
