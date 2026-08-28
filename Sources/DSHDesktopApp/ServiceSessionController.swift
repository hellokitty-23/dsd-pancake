import DSHDesktopCore
import Foundation

/// DSH service session（服务会话）的进程与生命周期边界。AppCoordinator 只投递
/// 用户意图和展示结果；generation、活动句柄及 reducer 状态由此处统一持有。
@MainActor
final class ServiceSessionController {
    private let probeClient = ServiceProbe()
    private let locator = DSHLocator()
    private let supervisor = ProcessSupervisor()

    private(set) var state = CoordinatedState()
    private(set) var currentHandle: SpawnHandle?
    private(set) var verifiedListenerHandle: SpawnHandle?

    var generation: UInt64 { state.generation }

    @discardableResult
    func beginStartupGeneration() -> UInt64 {
        let generation = state.generation &+ 1
        transition(.beginProbe(generation: generation))
        return generation
    }

    func transition(_ action: AppAction) {
        state = StateReducer.reduce(state, action: action)
    }

    func recordProbe(_ result: ProbeResult, generation: UInt64) {
        transition(.probeCompleted(generation: generation, result: result))
    }

    func beginPreflight(generation: UInt64) {
        transition(.beginPreflight(generation: generation))
    }

    @discardableResult
    func beginSpawn() -> Bool {
        let previous = state
        transition(.beginSpawn)
        return state != previous && state.phase == .spawning
    }

    func installSpawnedHandle(_ handle: SpawnHandle) {
        currentHandle = handle
        verifiedListenerHandle = nil
        transition(.spawned)
    }

    func adoptHandleForCleanup(_ handle: SpawnHandle) {
        currentHandle = handle
        verifiedListenerHandle = nil
        transition(.adoptedHandleForCleanup)
    }

    func clearHandle(cleanup: ProcessCleanupState = .clear) {
        currentHandle = nil
        verifiedListenerHandle = nil
        transition(.handleCleared(cleanup: cleanup))
        if cleanup == .clear {
            transition(.pipesDrained)
        }
    }

    /// 异步回调只能清理由自己开始监督的 handle。若期间已经安装了后继 handle，
    /// 迟到的 monitor/reconcile 只返回失败，绝不清除后继会话及其 listener 授权。
    @discardableResult
    func clearHandle(
        ifExpected expectedHandle: SpawnHandle,
        cleanup: ProcessCleanupState = .clear
    ) -> Bool {
        guard currentHandle == expectedHandle else { return false }
        clearHandle(cleanup: cleanup)
        return true
    }

    func probe(timeout: TimeInterval? = nil) async -> ProbeResult {
        if let timeout {
            return await probeClient.probe(timeout: timeout)
        }
        return await probeClient.probe()
    }

    func locateExecutable(lastChosenPath: String?) -> DSHExecutable? {
        locator.locate(lastChosenPath: lastChosenPath)
    }

    func canSpawn() async -> Bool {
        guard state.mayStartNewProcess else { return false }
        return await supervisor.canSpawn()
    }

    func spawn(_ spec: LaunchSpec) async throws -> SpawnHandle {
        try await supervisor.spawn(spec)
    }

    func checkExit(_ handle: SpawnHandle) async -> ProcessExitObservation {
        await supervisor.checkExit(handle)
    }

    func verifyOwnership(_ handle: SpawnHandle) async -> OwnershipVerification {
        await supervisor.verifyOwnership(handle)
    }

    func verifyLocalServiceOwnership(_ handle: SpawnHandle) async -> LocalServiceOwnershipVerification {
        await supervisor.verifyLocalServiceOwnership(handle, port: UInt16(LocalService.port))
    }

    /// `verifiedListenerHandle` 只记录已经通过“子进程身份 + loopback listener”复核的
    /// 同一个 spawn handle。它与进程停止权分开：listener 丢失后仍可安全监督自己的
    /// 子进程，但不能继续把端口网页视为 owned，也不能保留 native bridge。
    @discardableResult
    func markVerifiedListener(for handle: SpawnHandle) -> Bool {
        guard currentHandle == handle else { return false }
        verifiedListenerHandle = handle
        return true
    }

    func hasVerifiedListener(for handle: SpawnHandle) -> Bool {
        verifiedListenerHandle == handle
    }

    func revokeVerifiedListener(for handle: SpawnHandle? = nil) {
        guard handle == nil || verifiedListenerHandle == handle else { return }
        verifiedListenerHandle = nil
    }

    func cleanupState(_ handle: SpawnHandle) async -> ProcessCleanupState {
        await supervisor.cleanupState(handle)
    }

    func cleanupComplete() async -> Bool {
        await supervisor.cleanupComplete()
    }

    func terminalIncompatibilityError() async -> Int32? {
        await supervisor.terminalIncompatibilityError()
    }

    func requestTermination(_ handle: SpawnHandle) async -> TerminationRequestResult {
        await supervisor.requestTermination(handle)
    }

    func logSnapshot() async -> [LogEntry] {
        await supervisor.logSnapshot()
    }
}
