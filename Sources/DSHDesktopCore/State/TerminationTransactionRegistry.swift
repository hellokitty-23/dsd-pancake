import Foundation

/// AppKit 异步退出事务的轻量编号器。
/// 它只管理“哪一次退出仍有效”和“是否已回复”，不保存 PID 或停止权。
public struct TerminationTransactionRegistry: Equatable, Sendable {
    public private(set) var latestID: UInt64 = 0
    public private(set) var activeID: UInt64?
    public private(set) var replySent = false
    private var gateBeforeTermination: TerminationGateSnapshot?
    private var signalRequested = false

    public init() {}

    @discardableResult
    public mutating func begin(originalGate: TerminationGateSnapshot) -> UInt64 {
        latestID &+= 1
        activeID = latestID
        replySent = false
        gateBeforeTermination = originalGate
        signalRequested = false
        return latestID
    }

    public func isActive(_ transactionID: UInt64) -> Bool {
        activeID == transactionID
    }

    /// 只有当前事务能标记已向 owned 主进程请求 SIGTERM。
    @discardableResult
    public mutating func markSignalRequested(for transactionID: UInt64) -> Bool {
        guard activeID == transactionID else { return false }
        signalRequested = true
        return true
    }

    /// 取消退出时可在不 await 的 MainActor 临界区恢复的门控快照。
    /// 一旦已经请求过 SIGTERM，停止权已不再可用，必须保守回到 cleanupPending。
    public func restoredGateAfterCancellation(for transactionID: UInt64) -> TerminationGateSnapshot? {
        guard activeID == transactionID, let gateBeforeTermination else { return nil }
        return signalRequested ? .cleanupPending : gateBeforeTermination
    }

    public func didRequestSignal(for transactionID: UInt64) -> Bool {
        activeID == transactionID && signalRequested
    }

    /// 取消只撤销当前活动事务；旧回调不能撤销后续事务。
    @discardableResult
    public mutating func cancel(_ transactionID: UInt64) -> Bool {
        guard activeID == transactionID else { return false }
        activeID = nil
        gateBeforeTermination = nil
        signalRequested = false
        return true
    }

    /// 同一事务最多允许一次 AppKit reply；历史事务也不能影响当前事务。
    @discardableResult
    public mutating func markReplySent(for transactionID: UInt64) -> Bool {
        guard latestID == transactionID, !replySent else { return false }
        replySent = true
        return true
    }
}

/// 退出确认弹框只允许当前事务被“确认”一次。第二次 `⌘Q` 取得该确认权后，
/// 同一弹框上的鼠标点击或后续重复按键都不能再次请求停止。
public struct TerminationConfirmationGate: Equatable, Sendable {
    private var presentedTransactionID: UInt64?

    public init() {}

    public mutating func present(for transactionID: UInt64) {
        presentedTransactionID = transactionID
    }

    /// 原子地取得当前弹框的确认权；取得后立即清空，避免重复退出请求。
    public mutating func takePresentedTransaction() -> UInt64? {
        defer { presentedTransactionID = nil }
        return presentedTransactionID
    }

    public mutating func clear(for transactionID: UInt64) {
        guard presentedTransactionID == transactionID else { return }
        presentedTransactionID = nil
    }
}
