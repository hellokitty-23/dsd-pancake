# DSD Pancake Notifications

这是 DSD Pancake 随 App 运行时加载的最小 DSH client plugin（浏览器侧插件）。它只观察 DSH 的公开会话摘要：顶层会话从 `running`（运行中）变为完成，以及 goal（目标）进入 `complete`（完成）或 `blocked`（受阻）。

它不读取消息正文、标题、工作目录、Cookie 或网页 DOM（文档对象模型），也不轮询端口或页面。普通 `dsh web` 不会加载此插件；只有 DSD Pancake 以 `--patch` 启动自己的 DSH 进程时才会挂载它。若普通浏览器访问的是这一个 App 启动的服务，DSH 会传送客户端模块，但因为不存在 WebKit 原生桥，它不会申请权限、读取会话或发送通知。

`lib/client.js` 是 DSH 的已构建浏览器模块格式。项目不随插件提交 Node.js、`node_modules`（依赖目录）或构建工具。
