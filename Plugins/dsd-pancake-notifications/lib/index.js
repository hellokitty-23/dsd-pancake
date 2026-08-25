// 节点侧仅占据 DSH Loader entry；全部完成观察逻辑在浏览器 client bundle 内。
// 因此插件不注册路由、不读取本地文件，也不保存任何 DSH 数据。
export function apply() {}
