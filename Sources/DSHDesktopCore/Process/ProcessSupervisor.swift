import Darwin
import Dispatch
import Foundation

public struct SpawnHandle: Equatable, Sendable {
    public let generation: UInt64
    public let pid: pid_t
    public let pgid: pid_t

    fileprivate init(generation: UInt64, pid: pid_t, pgid: pid_t) {
        self.generation = generation
        self.pid = pid
        self.pgid = pgid
    }
}

public enum ProcessExitStatus: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
    case other(Int32)
}

public enum ProcessExitObservation: Equatable, Sendable {
    case running
    case reaped(ProcessExitStatus)
    case terminalUnavailable(Int32)
    case staleHandle
}

public enum OwnershipVerification: Equatable, Sendable {
    case verified
    case lost
    case staleHandle
}

/// 同时确认本次直接创建的主进程身份，以及它实际监听了目标 loopback 端口。
/// 未验证时绝不把端口上的网页服务标为 `owned`。
public enum LocalServiceOwnershipVerification: Equatable, Sendable {
    case verified
    case notListening
    case ownershipLost
    case alreadyExited(ProcessExitStatus)
    case terminalUnavailable(Int32)
    case staleHandle
}

public enum TerminationRequestResult: Equatable, Sendable {
    case signalSent
    case alreadyExited(ProcessExitStatus)
    case ownershipLost
    case terminalUnavailable(Int32)
    case signalFailed(Int32)
    case staleHandle
}

public enum ProcessSupervisorError: Error, Equatable, Sendable {
    case cleanupPending
    case terminalIncompatible(Int32)
    case invalidExecutable
    case pipeFailed(Int32)
    case closeOnExecFailed(Int32)
    case spawnAttributeFailed(Int32)
    case fileActionFailed(Int32)
    case spawnFailed(Int32)
    case noIdentityAfterSpawn
}

/// 仅供验证 target 注入 `waitpid` 的不可恢复错误。生产构造不传入该值，始终直接
/// 调用 Darwin `waitpid`；它不提供 PID 猜测、外部进程控制或信号注入能力。
public struct ProcessSupervisorTestingHooks: Sendable {
    public let waitErrorForPID: @Sendable (pid_t) -> Int32?

    public init(waitErrorForPID: @escaping @Sendable (pid_t) -> Int32?) {
        self.waitErrorForPID = waitErrorForPID
    }
}

/// 每个 `ReapCoordinator` 只管理一个当前会话直接创建的 DSH 主进程。
/// 唯一的 actor 串行域独占 `waitpid`、停止权复核和 `SIGTERM` 决策。
public actor ReapCoordinator {
    public let ringLog: RingLog

    private var nextGeneration: UInt64 = 0
    private var managed: ManagedProcess?
    /// 主进程可能在 `spawn` 返回前就退出，且两路 pipe 也可能在 App
    /// 安装 `SpawnHandle` 前自然 EOF。此时仍需让同一 handle 观察到一次
    /// 已回收状态，供上层显示真实退出码；它不保留停止权，也不阻止下一次 spawn。
    private var lastCompletedReap: CompletedReap?
    /// `waitpid` 无法再证明回收时，本 App 会话不能重新取得启动权。
    private var terminalIncompatibility: Int32?
    private let notificationQueue = DispatchQueue(label: "com.dshdesktop.process-exit", qos: .utility)
    private let identityCapture: @Sendable (pid_t) -> ProcessIdentity?
    private let testingWaitErrorForPID: (@Sendable (pid_t) -> Int32?)?

    /// `identityCapture` 在生产中始终使用 Darwin 的真实进程信息；保留注入点只用于
    /// 验证身份查询失败时会撤销停止权，而不是根据 PID 或命令文字猜测归属。
    public init(
        ringLog: RingLog = RingLog(),
        identityCapture: @escaping @Sendable (pid_t) -> ProcessIdentity? = { ProcessIdentity.capture(pid: $0) },
        testingHooks: ProcessSupervisorTestingHooks? = nil
    ) {
        self.ringLog = ringLog
        self.identityCapture = identityCapture
        self.testingWaitErrorForPID = testingHooks?.waitErrorForPID
    }

    deinit {
        if let managed {
            managed.exitSource?.cancel()
            managed.stdout.readabilityHandler = nil
            managed.stderr.readabilityHandler = nil
        }
    }

    public func canSpawn() -> Bool {
        managed == nil && terminalIncompatibility == nil
    }

    public func logSnapshot() -> [LogEntry] {
        ringLog.snapshot()
    }

    /// 两路 pipe 已自然 EOF 且本地 handler 已释放；这不等价于允许再次 spawn。
    public func cleanupComplete() -> Bool {
        managed == nil
    }

    public func terminalIncompatibilityError() -> Int32? {
        terminalIncompatibility
    }

    public func spawn(_ spec: LaunchSpec) throws -> SpawnHandle {
        if let terminalIncompatibility {
            throw ProcessSupervisorError.terminalIncompatible(terminalIncompatibility)
        }
        guard managed == nil else { throw ProcessSupervisorError.cleanupPending }
        guard spec.executable.isFileURL,
              FileManager.default.isExecutableFile(atPath: spec.executable.path) else {
            throw ProcessSupervisorError.invalidExecutable
        }

        nextGeneration &+= 1
        lastCompletedReap = nil
        let generation = nextGeneration
        var stdoutPipe = PipeDescriptors()
        var stderrPipe = PipeDescriptors()
        var attributes: posix_spawnattr_t? = nil
        var actions: posix_spawn_file_actions_t? = nil
        var attributesInitialized = false
        var actionsInitialized = false

        defer {
            if actionsInitialized { _ = posix_spawn_file_actions_destroy(&actions) }
            if attributesInitialized { _ = posix_spawnattr_destroy(&attributes) }
        }

        // 即使第二条 pipe 或其后续配置失败，也要关闭已成功创建的父端。
        defer {
            stdoutPipe.closeAllOpen()
            stderrPipe.closeAllOpen()
        }

        let attrResult = posix_spawnattr_init(&attributes)
        guard attrResult == 0 else { throw ProcessSupervisorError.spawnAttributeFailed(attrResult) }
        attributesInitialized = true

        let actionResult = posix_spawn_file_actions_init(&actions)
        guard actionResult == 0 else { throw ProcessSupervisorError.fileActionFailed(actionResult) }
        actionsInitialized = true

        try stdoutPipe.create()
        try stderrPipe.create()

        try setCloseOnExec(stdoutPipe.read)
        try setCloseOnExec(stderrPipe.read)

        // LaunchServices 启动的 GUI App 可能继承忽略或屏蔽的终止信号。
        // 本 App 只会在身份复核后向自己的直接子 PID 发送 SIGTERM；因此子进程
        // 必须以可接收且默认处理 SIGTERM 的状态启动，不能沿用父进程的信号状态。
        var defaultSignals = sigset_t()
        guard sigemptyset(&defaultSignals) == 0,
              sigaddset(&defaultSignals, SIGTERM) == 0 else {
            throw ProcessSupervisorError.spawnAttributeFailed(errno)
        }
        let signalDefaultResult = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        guard signalDefaultResult == 0 else { throw ProcessSupervisorError.spawnAttributeFailed(signalDefaultResult) }

        var emptySignalMask = sigset_t()
        guard sigemptyset(&emptySignalMask) == 0 else {
            throw ProcessSupervisorError.spawnAttributeFailed(errno)
        }
        let signalMaskResult = posix_spawnattr_setsigmask(&attributes, &emptySignalMask)
        guard signalMaskResult == 0 else { throw ProcessSupervisorError.spawnAttributeFailed(signalMaskResult) }

        let spawnFlags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_CLOEXEC_DEFAULT
        )
        let flagResult = posix_spawnattr_setflags(&attributes, spawnFlags)
        guard flagResult == 0 else { throw ProcessSupervisorError.spawnAttributeFailed(flagResult) }
        let groupResult = posix_spawnattr_setpgroup(&attributes, 0)
        guard groupResult == 0 else { throw ProcessSupervisorError.spawnAttributeFailed(groupResult) }

        let cwdResult = spec.workingDirectory.path.withCString {
            posix_spawn_file_actions_addchdir_np(&actions, $0)
        }
        guard cwdResult == 0 else { throw ProcessSupervisorError.fileActionFailed(cwdResult) }

        for result in [
            posix_spawn_file_actions_adddup2(&actions, stdoutPipe.write, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stderrPipe.write, STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, stdoutPipe.read),
            posix_spawn_file_actions_addclose(&actions, stderrPipe.read),
            posix_spawn_file_actions_addclose(&actions, stdoutPipe.write),
            posix_spawn_file_actions_addclose(&actions, stderrPipe.write),
        ] {
            guard result == 0 else { throw ProcessSupervisorError.fileActionFailed(result) }
        }

        let argv = [spec.executable.path] + spec.arguments
        let environment = spec.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var pid: pid_t = 0
        let spawnResult = try withCStringArray(argv) { argvPointer in
            try withCStringArray(environment) { environmentPointer in
                spec.executable.path.withCString { executablePointer in
                    posix_spawn(&pid, executablePointer, &actions, &attributes, argvPointer, environmentPointer)
                }
            }
        }
        guard spawnResult == 0 else { throw ProcessSupervisorError.spawnFailed(spawnResult) }

        stdoutPipe.closeWrite()
        stderrPipe.closeWrite()
        let stdout = stdoutPipe.takeReadHandle()
        let stderr = stderrPipe.takeReadHandle()
        guard let identity = identityCapture(pid), identity.pgid == pid else {
            // 已创建的进程仍必须被纳管和排空，但不授予停止权。
            let fallbackIdentity = identityCapture(pid)
            let process = ManagedProcess(
                generation: generation,
                pid: pid,
                identity: fallbackIdentity,
                stdout: stdout,
                stderr: stderr,
                signalCapability: false
            )
            install(process)
            return SpawnHandle(generation: generation, pid: pid, pgid: fallbackIdentity?.pgid ?? 0)
        }

        let process = ManagedProcess(
            generation: generation,
            pid: pid,
            identity: identity,
            stdout: stdout,
            stderr: stderr,
            signalCapability: true
        )
        install(process)
        return SpawnHandle(generation: generation, pid: pid, pgid: identity.pgid)
    }

    public func checkExit(_ handle: SpawnHandle) -> ProcessExitObservation {
        guard matches(handle) else {
            if let completed = completedReap(matching: handle) {
                return .reaped(completed.status)
            }
            return .staleHandle
        }
        return checkExitInternally()
    }

    public func verifyOwnership(_ handle: SpawnHandle) -> OwnershipVerification {
        guard matches(handle) else {
            return completedReap(matching: handle) == nil ? .staleHandle : .lost
        }
        return verifyOwnershipInternally()
    }

    /// 在唯一 `ReapCoordinator` 串行域中完成 exit、身份和监听端口复核。
    /// 只读取该 `SpawnHandle` 对应 PID 的文件描述符，不扫描其他进程。
    public func verifyLocalServiceOwnership(
        _ handle: SpawnHandle,
        port: UInt16
    ) -> LocalServiceOwnershipVerification {
        guard matches(handle) else { return .staleHandle }

        switch checkExitInternally() {
        case let .reaped(status):
            return .alreadyExited(status)
        case let .terminalUnavailable(error):
            return .terminalUnavailable(error)
        case .staleHandle:
            return .staleHandle
        case .running:
            break
        }

        guard verifyOwnershipInternally() == .verified,
              let identity = managed?.identity else {
            return .ownershipLost
        }
        return identity.ownsListeningLoopbackIPv4Port(port) ? .verified : .notListening
    }

    /// 从同一串行域先做 WNOHANG，再复核身份，最后才可能对直接子 PID 发送一次 SIGTERM。
    public func requestTermination(_ handle: SpawnHandle) -> TerminationRequestResult {
        guard matches(handle) else {
            if let completed = completedReap(matching: handle) {
                return .alreadyExited(completed.status)
            }
            return .staleHandle
        }

        switch checkExitInternally() {
        case let .reaped(status):
            return .alreadyExited(status)
        case let .terminalUnavailable(error):
            return .terminalUnavailable(error)
        case .staleHandle:
            return .staleHandle
        case .running:
            break
        }

        guard verifyOwnershipInternally() == .verified, let process = managed else {
            return .ownershipLost
        }
        guard process.signalCapability else { return .ownershipLost }

        if kill(process.pid, SIGTERM) == 0 {
            process.signalCapability = false
            return .signalSent
        }

        let signalError = errno
        if signalError == ESRCH {
            switch checkExitInternally() {
            case let .reaped(status): return .alreadyExited(status)
            case let .terminalUnavailable(error): return .terminalUnavailable(error)
            default: return .ownershipLost
            }
        }
        process.signalCapability = false
        return .signalFailed(signalError)
    }

    public func cleanupState(_ handle: SpawnHandle) -> ProcessCleanupState {
        guard matches(handle), let process = managed else {
            if completedReap(matching: handle) != nil {
                return .clear
            }
            return terminalIncompatibility == nil ? .clear : .terminalUnavailable
        }
        switch process.reapState {
        case .active:
            return process.signalCapability ? .awaitingReap : .supervisionOnly
        case .reaped:
            return process.pipesAtEOF ? .clear : .drainingPipes
        case .terminalUnavailable:
            return process.pipesAtEOF ? .clear : .terminalUnavailable
        }
    }

    public func pipesAtEOF(_ handle: SpawnHandle) -> Bool {
        (matches(handle) && managed?.pipesAtEOF == true) || completedReap(matching: handle) != nil
    }

    public func isReaped(_ handle: SpawnHandle) -> Bool {
        if completedReap(matching: handle) != nil { return true }
        guard matches(handle), let managed else { return false }
        if case .reaped = managed.reapState { return true }
        return false
    }

    private func install(_ process: ManagedProcess) {
        managed = process
        installReadabilityHandler(for: process.stdout, stream: .stdout, generation: process.generation)
        installReadabilityHandler(for: process.stderr, stream: .stderr, generation: process.generation)

        let source = DispatchSource.makeProcessSource(
            identifier: process.pid,
            eventMask: .exit,
            queue: notificationQueue
        )
        source.setEventHandler { [weak self] in
            Task { [weak self] in
                await self?.handleExitNotification(generation: process.generation)
            }
        }
        process.exitSource = source
        source.resume()

        // 覆盖子进程在通知源注册前已经退出的窗口；唯一 reaper 仍是此 actor。
        _ = checkExitInternally()
    }

    private func installReadabilityHandler(for fileHandle: FileHandle, stream: LogStream, generation: UInt64) {
        let ringLog = self.ringLog
        fileHandle.readabilityHandler = { [weak self, ringLog] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // 生命周期状态仍只能由 actor 修改；EOF 最多每路一次，因此不会形成
                // 输出高峰时的 Task 积压。
                Task { [weak self] in
                    await self?.finishReadabilityStream(stream: stream, generation: generation)
                }
                return
            }

            // RingLog 自身有锁且有严格字节上限。直接在读取回调中写入，避免 DSH
            // 大量输出时为每个数据块向 actor 投递一个 Task，造成额外调度与内存压力。
            ringLog.append(data, stream: stream)
        }
    }

    private func finishReadabilityStream(stream: LogStream, generation: UInt64) {
        guard let process = managed, process.generation == generation else { return }
        switch stream {
        case .stdout:
            guard !process.stdoutEOF else { return }
            process.stdoutEOF = true
            process.stdout.readabilityHandler = nil
            try? process.stdout.close()
            ringLog.finish(stream: .stdout)
        case .stderr:
            guard !process.stderrEOF else { return }
            process.stderrEOF = true
            process.stderr.readabilityHandler = nil
            try? process.stderr.close()
            ringLog.finish(stream: .stderr)
        }
        releaseIfFullyDrained()
    }

    private func handleExitNotification(generation: UInt64) {
        guard managed?.generation == generation else { return }
        _ = checkExitInternally()
    }

    private func checkExitInternally() -> ProcessExitObservation {
        guard let process = managed else { return .staleHandle }
        switch process.reapState {
        case let .reaped(status):
            return .reaped(status)
        case let .terminalUnavailable(error):
            return .terminalUnavailable(error)
        case .active:
            break
        }

        if let injectedError = testingWaitErrorForPID?(process.pid) {
            return markTerminalUnavailable(process: process, error: injectedError)
        }

        var rawStatus: Int32 = 0
        while true {
            let result = waitpid(process.pid, &rawStatus, WNOHANG)
            if result == 0 {
                return .running
            }
            if result == process.pid {
                let status = Self.exitStatus(from: rawStatus)
                process.reapState = .reaped(status)
                process.signalCapability = false
                process.exitSource?.cancel()
                process.exitSource = nil
                releaseIfFullyDrained()
                return .reaped(status)
            }
            if result == -1 && errno == EINTR {
                continue
            }
            return markTerminalUnavailable(process: process, error: errno)
        }
    }

    private func markTerminalUnavailable(
        process: ManagedProcess,
        error: Int32
    ) -> ProcessExitObservation {
        process.reapState = .terminalUnavailable(error)
        terminalIncompatibility = error
        process.signalCapability = false
        process.exitSource?.cancel()
        process.exitSource = nil
        releaseIfFullyDrained()
        return .terminalUnavailable(error)
    }

    private func verifyOwnershipInternally() -> OwnershipVerification {
        guard let process = managed else { return .staleHandle }
        guard case .active = process.reapState else { return .lost }
        guard process.signalCapability,
              let identity = process.identity,
              identity.pgid == process.pid,
              identity.stillMatchesCurrentProcess(capturing: identityCapture) else {
            process.signalCapability = false
            return .lost
        }
        return .verified
    }

    private func releaseIfFullyDrained() {
        guard let process = managed, process.pipesAtEOF else { return }
        switch process.reapState {
        case .active:
            return
        case let .reaped(status):
            process.exitSource?.cancel()
            process.exitSource = nil
            lastCompletedReap = CompletedReap(
                handle: SpawnHandle(generation: process.generation, pid: process.pid, pgid: process.identity?.pgid ?? 0),
                status: status
            )
            managed = nil
        case .terminalUnavailable:
            process.exitSource?.cancel()
            process.exitSource = nil
            managed = nil
        }
    }

    private func matches(_ handle: SpawnHandle) -> Bool {
        guard let process = managed else { return false }
        return process.generation == handle.generation && process.pid == handle.pid
    }

    private func completedReap(matching handle: SpawnHandle) -> CompletedReap? {
        guard managed == nil,
              let lastCompletedReap,
              lastCompletedReap.handle == handle else {
            return nil
        }
        return lastCompletedReap
    }

    private static func exitStatus(from status: Int32) -> ProcessExitStatus {
        let signal = status & 0x7F
        if signal == 0 {
            return .exited((status >> 8) & 0xFF)
        }
        if signal != 0x7F {
            return .signaled(signal)
        }
        return .other(status)
    }

    private func setCloseOnExec(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw ProcessSupervisorError.closeOnExecFailed(errno)
        }
    }
}

private struct CompletedReap: Sendable {
    let handle: SpawnHandle
    let status: ProcessExitStatus
}

/// 进程监管的公开业务名称；其唯一串行执行域就是 `ReapCoordinator`。
public typealias ProcessSupervisor = ReapCoordinator

private final class ManagedProcess: @unchecked Sendable {
    enum ReapState {
        case active
        case reaped(ProcessExitStatus)
        case terminalUnavailable(Int32)
    }

    let generation: UInt64
    let pid: pid_t
    let identity: ProcessIdentity?
    let stdout: FileHandle
    let stderr: FileHandle
    var signalCapability: Bool
    var reapState: ReapState = .active
    var stdoutEOF = false
    var stderrEOF = false
    var exitSource: DispatchSourceProcess?

    init(
        generation: UInt64,
        pid: pid_t,
        identity: ProcessIdentity?,
        stdout: FileHandle,
        stderr: FileHandle,
        signalCapability: Bool
    ) {
        self.generation = generation
        self.pid = pid
        self.identity = identity
        self.stdout = stdout
        self.stderr = stderr
        self.signalCapability = signalCapability
    }

    var pipesAtEOF: Bool {
        stdoutEOF && stderrEOF
    }
}

private struct PipeDescriptors {
    var read: Int32 = -1
    var write: Int32 = -1

    mutating func create() throws {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            throw ProcessSupervisorError.pipeFailed(errno)
        }
        read = descriptors[0]
        write = descriptors[1]
    }

    mutating func closeWrite() {
        guard write >= 0 else { return }
        _ = close(write)
        write = -1
    }

    mutating func closeAllOpen() {
        if read >= 0 {
            _ = close(read)
            read = -1
        }
        closeWrite()
    }

    mutating func takeReadHandle() -> FileHandle {
        let descriptor = read
        read = -1
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

private func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
) throws -> Result {
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    pointers.reserveCapacity(strings.count + 1)
    for string in strings {
        guard !string.utf8.contains(0), let pointer = strdup(string) else {
            pointers.forEach { free($0) }
            throw ProcessSupervisorError.invalidExecutable
        }
        pointers.append(pointer)
    }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return try pointers.withUnsafeMutableBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { throw ProcessSupervisorError.invalidExecutable }
        return try body(baseAddress)
    }
}
