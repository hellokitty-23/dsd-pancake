import Foundation

/// native bridge（原生通信桥）的唯一进程级准入判断。resolver prepare 只记录候选
/// patch；必须同时满足 listener 归属复核成功、句柄完全匹配、对应插件确实随该句柄启动。
public enum PrivatePluginBridgeAdmission {
    public static func mayEnable(
        _ kind: PrivatePluginKind,
        ownershipVerification: LocalServiceOwnershipVerification,
        launchState: PrivatePluginLaunchState,
        handle: SpawnHandle
    ) -> Bool {
        ownershipVerification == .verified
            && launchState.isPrepared(kind, for: handle)
    }
}
