import Darwin
import Foundation

/// 可复核的主进程身份。它只来自当前会话创建后立即采集的系统数据。
public struct ProcessIdentity: Equatable, Sendable {
    public let pid: pid_t
    public let pgid: pid_t
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64

    public static func capture(pid: pid_t) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, Int32(PROC_PIDTBSDINFO), 0, &info, expectedSize)
        guard result == expectedSize else { return nil }
        let pgid = getpgid(pid)
        guard pgid > 0 else { return nil }
        return ProcessIdentity(
            pid: pid,
            pgid: pgid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }

    /// `capturing` 默认为真实系统查询；测试可传入受控实现，以验证“失去身份即撤权”
    /// 的安全路径，而不会伪造或控制任何外部进程。
    public func stillMatchesCurrentProcess(
        capturing: @Sendable (pid_t) -> ProcessIdentity? = { ProcessIdentity.capture(pid: $0) }
    ) -> Bool {
        guard let current = capturing(pid) else { return false }
        return current == self
    }

    /// 仅检查本次直接创建且身份仍匹配的 PID，绝不扫描或推断其他进程。
    /// 这用于区分“子进程仍活着”和“它实际占有目标监听端口”。
    public func ownsListeningLoopbackIPv4Port(_ port: UInt16) -> Bool {
        guard stillMatchesCurrentProcess(),
              let descriptors = Self.openFileDescriptors(for: pid) else {
            return false
        }

        var loopbackAddress = in_addr()
        let parsedLoopback = "127.0.0.1".withCString {
            inet_pton(AF_INET, $0, &loopbackAddress)
        }
        guard parsedLoopback == 1 else { return false }

        for descriptor in descriptors where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socketInfo = socket_fdinfo()
            let result = proc_pidfdinfo(
                pid,
                descriptor.proc_fd,
                PROC_PIDFDSOCKETINFO,
                &socketInfo,
                Int32(MemoryLayout<socket_fdinfo>.size)
            )
            guard result == Int32(MemoryLayout<socket_fdinfo>.size),
                  socketInfo.psi.soi_kind == SOCKINFO_TCP else {
                continue
            }

            let tcp = socketInfo.psi.soi_proto.pri_tcp
            let endpoint = tcp.tcpsi_ini
            let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: endpoint.insi_lport))
            guard tcp.tcpsi_state == TSI_S_LISTEN,
                  localPort == port,
                  endpoint.insi_vflag == UInt8(INI_IPV4),
                  endpoint.insi_laddr.ina_46.i46a_addr4.s_addr == loopbackAddress.s_addr else {
                continue
            }
            return true
        }
        return false
    }

    private static func openFileDescriptors(for pid: pid_t) -> [proc_fdinfo]? {
        let requiredBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard requiredBytes > 0 else { return nil }

        let stride = MemoryLayout<proc_fdinfo>.stride
        let capacity = Int(requiredBytes) / stride
        guard capacity > 0 else { return nil }

        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let receivedBytes = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard receivedBytes > 0 else { return nil }
        return Array(descriptors.prefix(Int(receivedBytes) / stride))
    }
}
