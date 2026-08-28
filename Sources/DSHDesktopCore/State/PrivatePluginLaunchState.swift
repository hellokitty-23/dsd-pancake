import Foundation

/// App 随一次受控 DSH 启动附加的私有插件。枚举顺序同时定义 `--patch` 的稳定顺序。
public enum PrivatePluginKind: String, CaseIterable, Hashable, Sendable {
    case notification
    case terminal
    case operationFolding
    case shortcut
}

/// 一次启动实际准备成功的插件 patch。缺失某个插件只会关闭对应增强，不阻断 DSH。
public struct PrivatePluginPatchSet: Equatable, Sendable {
    private var storage: [PrivatePluginKind: URL]

    public init(_ storage: [PrivatePluginKind: URL] = [:]) {
        self.storage = storage
    }

    public subscript(kind: PrivatePluginKind) -> URL? {
        get { storage[kind] }
        set { storage[kind] = newValue }
    }

    public var isEmpty: Bool { storage.isEmpty }

    public var kinds: Set<PrivatePluginKind> {
        Set(storage.keys)
    }

    public var orderedURLs: [URL] {
        PrivatePluginKind.allCases.compactMap { storage[$0] }
    }
}

/// 私有插件只属于一次 spawn transaction（创建进程事务）。准备 resolver 不授予任何
/// native bridge；只有准备集合绑定到真实 `SpawnHandle` 后，准入层才可能开启 capability。
public struct PrivatePluginLaunchState: Equatable, Sendable {
    public private(set) var preparedKinds: Set<PrivatePluginKind> = []
    public private(set) var preparedHandle: SpawnHandle?
    public private(set) var skipsNextPreparation = false

    public init() {}

    /// 开始新一轮 resolver 准备，并一次性消费无插件回退标记。
    /// 返回 `false` 时本轮必须使用标准 DSH 启动参数。
    @discardableResult
    public mutating func beginPreparation() -> Bool {
        preparedKinds.removeAll()
        preparedHandle = nil
        guard !skipsNextPreparation else {
            skipsNextPreparation = false
            return false
        }
        return true
    }

    public mutating func recordPrepared(_ kind: PrivatePluginKind) {
        preparedKinds.insert(kind)
    }

    /// `SpawnHandle` 只能在 `ProcessSupervisor.spawn` 成功后绑定，resolver prepare
    /// 阶段没有句柄，因此不能通过 bridge admission（桥准入）。
    public mutating func bindPreparedPlugins(to handle: SpawnHandle) {
        preparedHandle = preparedKinds.isEmpty ? nil : handle
    }

    public func isPrepared(_ kind: PrivatePluginKind, for handle: SpawnHandle) -> Bool {
        preparedHandle == handle && preparedKinds.contains(kind)
    }

    /// 页面已经由该 owned listener 提供后，覆盖层不再属于“启动前失败”的回退窗口。
    public mutating func markReady(for handle: SpawnHandle) {
        guard preparedHandle == handle else { return }
        preparedKinds.removeAll()
        preparedHandle = nil
    }

    /// 覆盖层导致页面就绪前退出时，只安排一次全部插件关闭的下一轮启动。
    @discardableResult
    public mutating func scheduleFallbackIfNeeded(
        for handle: SpawnHandle,
        quitPending: Bool
    ) -> Bool {
        guard preparedHandle == handle,
              !preparedKinds.isEmpty,
              !quitPending else {
            return false
        }
        preparedKinds.removeAll()
        preparedHandle = nil
        skipsNextPreparation = true
        return true
    }

    public mutating func reset(clearScheduledFallback: Bool = true) {
        preparedKinds.removeAll()
        preparedHandle = nil
        if clearScheduledFallback {
            skipsNextPreparation = false
        }
    }
}
