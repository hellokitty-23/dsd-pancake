# 贡献说明

DSD Pancake 的目标是可靠的本机薄壳，不是功能越来越多的 DSH 替代品。提交前请先判断改动是否仍在这个边界内。

## 不变的边界

- 不捆绑、安装、升级或修改 DSH、Node.js、插件和用户数据；
- 不增加通用 Shell、任意命令执行、远程管理或全局进程扫描；
- 端口可达不等于进程归属。只有本次 App 直接创建并复核通过的进程才可被停止；
- 网页页面保持 DSH 自己控制。原生层不得读取会话、Cookie、输入或内容；
- 不能为了“更方便”把 external（App 打开前已有）服务变为可停止对象。

## 本地检查

```zsh
swift build -c release
zsh scripts/verify.zsh
zsh -n scripts/local-release/build-app.zsh
zsh -n scripts/local-release/verify-app.zsh
git diff --check
```

验证脚本固定跳过 `127.0.0.1:3080`，不会只读访问用户正在使用的 DSH 服务。

## 不应提交的内容

不要提交本机构建产物、`.app`、ZIP、`.build`、`local-release`、本地 DSH 配置、日志、Cookie、终端记录、截图、`.env` 或个人路径。`.gitignore` 已覆盖常见情况，但提交前仍应检查：

```zsh
git status --short
git diff --cached --check
```

## 文档和提交

- 修改启动、停止、网页导航或进程归属时，同步更新 [docs/architecture.md](./docs/architecture.md)；
- 修改打包行为时，同步更新 [docs/build-and-run.md](./docs/build-and-run.md)；
- 提交信息说明用户可感知的结果，不记录本机用户名、绝对路径或服务数据。
