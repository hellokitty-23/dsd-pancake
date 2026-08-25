import Foundation

/// DSH 服务在当前 App 会话中的归属。仅 `owned` 可申请停止。
public enum ServiceOwnership: Equatable, Sendable {
    case external
    case owned
}

/// 清理状态与服务归属正交，避免把“网页还可访问”误当成停止权。
public enum ProcessCleanupState: Equatable, Sendable {
    case clear
    case supervisionOnly
    case terminalUnavailable
    case awaitingReap
    case drainingPipes
    case orphanDrainIncompatible

    public var blocksNewSpawn: Bool {
        self != .clear
    }
}

/// AppKit 同步退出回调可读取的最小镜像；不保存 PID，也不授予信号权。
public enum TerminationGateSnapshot: Equatable, Sendable {
    case clear
    case spawnTransaction
    case stoppable
    case cleanupPending
    case quitPending

    public var requiresDeferredTermination: Bool {
        self != .clear
    }

    /// spawn 已经进入资源准备/系统调用边界，但 `SpawnHandle` 尚未安装时，
    /// AppKit 退出协议必须等待这笔事务成功或失败后再回复，不能提前放行。
    public var waitsForSpawnResult: Bool {
        self == .spawnTransaction
    }
}

public enum AppPhase: Equatable, Sendable {
    case idle
    case acquiringInstance
    case probing(generation: UInt64)
    case awaitingConsent(ProbeResult)
    case locating
    case preflightProbe(generation: UInt64)
    case spawning
    case waitingReady
    case readinessTimedOut
    case running(ServiceOwnership)
    case disconnectedOwned
    case portAbnormal(ReachableNonHTMLReason)
    case launchFailed(String)
    case serviceStopped
    case drainingProcessCleanup
    case confirmingQuit
    case stoppingOwnedService
    case stopTimedOut
}

public struct CoordinatedState: Equatable, Sendable {
    public private(set) var phase: AppPhase
    public private(set) var generation: UInt64
    public private(set) var cleanup: ProcessCleanupState
    public private(set) var hasActiveHandle: Bool

    public init(
        phase: AppPhase = .idle,
        generation: UInt64 = 0,
        cleanup: ProcessCleanupState = .clear,
        hasActiveHandle: Bool = false
    ) {
        self.phase = phase
        self.generation = generation
        self.cleanup = cleanup
        self.hasActiveHandle = hasActiveHandle
    }

    public var mayStartNewProcess: Bool {
        !hasActiveHandle && !cleanup.blocksNewSpawn
    }

    mutating func replace(
        phase: AppPhase? = nil,
        generation: UInt64? = nil,
        cleanup: ProcessCleanupState? = nil,
        hasActiveHandle: Bool? = nil
    ) {
        if let phase { self.phase = phase }
        if let generation { self.generation = generation }
        if let cleanup { self.cleanup = cleanup }
        if let hasActiveHandle { self.hasActiveHandle = hasActiveHandle }
    }
}

public enum AppAction: Equatable, Sendable {
    case beginProbe(generation: UInt64)
    case probeCompleted(generation: UInt64, result: ProbeResult)
    case acceptedUnknownService
    case rejectedUnknownService
    case beginLocate
    case beginPreflight(generation: UInt64)
    case beginSpawn
    case spawned
    case readinessTimedOut
    case serviceReady(ownership: ServiceOwnership)
    case ownershipLost
    case processExited
    case pipesDrained
    case launchFailed(String)
    case beginQuit
    case stopTimedOut
    case cancelQuit
}

public enum StateReducer {
    /// 纯 reducer（状态归约器）只接受当前 generation 的异步结果。
    public static func reduce(_ state: CoordinatedState, action: AppAction) -> CoordinatedState {
        var next = state

        switch action {
        case let .beginProbe(generation):
            next.replace(phase: .probing(generation: generation), generation: generation)

        case let .probeCompleted(generation, result) where generation == state.generation:
            switch result {
            case .unavailable:
                next.replace(phase: .locating)
            case .dshLikely:
                next.replace(phase: .running(.external))
            case .reachableUnknown:
                next.replace(phase: .awaitingConsent(result))
            case let .reachableNonHTML(reason):
                next.replace(phase: .portAbnormal(reason))
            }

        case .acceptedUnknownService:
            if case .awaitingConsent = state.phase {
                next.replace(phase: .running(.external))
            }

        case .rejectedUnknownService:
            if case .awaitingConsent = state.phase {
                next.replace(phase: .idle)
            }

        case .beginLocate where state.mayStartNewProcess:
            next.replace(phase: .locating)

        case let .beginPreflight(generation) where state.mayStartNewProcess:
            next.replace(phase: .preflightProbe(generation: generation), generation: generation)

        case .beginSpawn where state.mayStartNewProcess:
            next.replace(phase: .spawning)

        case .spawned:
            if case .spawning = state.phase {
                next.replace(phase: .waitingReady, hasActiveHandle: true)
            }

        case .readinessTimedOut where state.hasActiveHandle:
            next.replace(phase: .readinessTimedOut)

        case let .serviceReady(ownership) where state.hasActiveHandle || ownership == .external:
            next.replace(phase: .running(ownership))

        case .ownershipLost where state.hasActiveHandle:
            next.replace(
                phase: .running(.external),
                cleanup: .supervisionOnly
            )

        case .processExited where state.hasActiveHandle:
            next.replace(
                phase: .drainingProcessCleanup,
                cleanup: .drainingPipes,
                hasActiveHandle: false
            )

        case .pipesDrained:
            next.replace(cleanup: .clear)
            if case .drainingProcessCleanup = state.phase {
                next.replace(phase: .serviceStopped)
            }

        case let .launchFailed(message):
            next.replace(phase: .launchFailed(message))

        case .beginQuit:
            next.replace(phase: .confirmingQuit)

        case .stopTimedOut:
            next.replace(phase: .stopTimedOut)

        case .cancelQuit:
            if state.hasActiveHandle {
                next.replace(phase: .running(.owned))
            } else if state.cleanup.blocksNewSpawn {
                next.replace(phase: .drainingProcessCleanup)
            } else {
                next.replace(phase: .idle)
            }

        default:
            break
        }

        return next
    }
}
