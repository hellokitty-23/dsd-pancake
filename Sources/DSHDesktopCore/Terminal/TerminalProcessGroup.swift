import Darwin
import Foundation

/// App 私有 PTY（伪终端）所创建进程组的最小生命周期工具。
///
/// 它只作用于调用方已经保存的直接子进程 PID / process group ID（进程组 ID），
/// 不扫描系统进程、不按命令行猜测 PID，也不接受网页输入。`reapIfExited` 只能回收
/// 当前进程自己的直接子进程，因此可用于确认 SwiftTerm 启动的 shell 已被回收。
public enum TerminalProcessGroup {
    public enum ReapResult: Equatable, Sendable {
        /// 直接子进程仍在运行，或尚未变成可回收状态。
        case running
        /// `waitpid` 已回收该直接子进程。
        case reaped
        /// 该 PID 已由其它已知路径回收；不应再把它当作活跃 shell。
        case noChild
        /// 发生了不能安全忽略的 `waitpid` 错误。
        case failed(Int32)
    }

    /// 向精确的 process group 发送信号。`ESRCH` 表示目标已不存在，也应视为终止
    /// 路径成功完成；其余错误由调用方作为清理异常处理或记录为失败状态。
    @discardableResult
    public static func send(_ signal: Int32, to processGroupID: pid_t) -> Bool {
        guard processGroupID > 1 else { return false }
        guard Darwin.kill(-processGroupID, signal) != 0 else { return true }
        return errno == ESRCH
    }

    /// `kill(-pgid, 0)` 只用来确认已知 App 私有 group 是否仍存在，绝不用于枚举
    /// 或控制其它进程。
    public static func exists(_ processGroupID: pid_t) -> Bool {
        guard processGroupID > 1 else { return false }
        guard Darwin.kill(-processGroupID, 0) != 0 else { return true }
        return errno == EPERM
    }

    /// 非阻塞回收当前进程的已知直接子 shell。`ECHILD` 表示 shell 已经由
    /// SwiftTerm 的退出监听回收；这同样满足“不会遗留 zombie（僵尸进程）”。
    public static func reapIfExited(_ processID: pid_t) -> ReapResult {
        guard processID > 1 else { return .noChild }
        var status: Int32 = 0
        let result = Darwin.waitpid(processID, &status, WNOHANG)
        switch result {
        case processID:
            return .reaped
        case 0:
            return .running
        case -1 where errno == EINTR:
            // 信号中断不是 child 生命周期结论；下一轮继续做非阻塞回收。
            return .running
        case -1 where errno == ECHILD:
            return .noChild
        case -1:
            return .failed(errno)
        default:
            return .failed(ECHILD)
        }
    }
}
