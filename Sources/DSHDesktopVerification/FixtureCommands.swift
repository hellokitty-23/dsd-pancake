import Darwin
import Dispatch
import Foundation
import DSHDesktopCore
import WebKit
@preconcurrency import SwiftTerm

extension DSHDesktopVerification {
    static func runInjectedTerminalUnavailableFixture() async -> Int32 {
        var original = sigaction()
        guard sigaction(SIGCHLD, nil, &original) == 0 else {
            print("TERMINAL_INJECTED_ERROR_SIGCHLD_READ_FAILED")
            return 64
        }
        var ignored = original
        ignored.__sigaction_u.__sa_handler = SIG_IGN
        ignored.sa_flags = 0
        guard sigaction(SIGCHLD, &ignored, nil) == 0 else {
            print("TERMINAL_INJECTED_ERROR_SIGCHLD_SET_FAILED")
            return 65
        }
        defer {
            var restored = original
            _ = sigaction(SIGCHLD, &restored, nil)
        }

        guard let executable = DSHExecutable(url: URL(fileURLWithPath: "/bin/sh")) else {
            print("TERMINAL_INJECTED_ERROR_EXECUTABLE_MISSING")
            return 66
        }

        let supervisor = ProcessSupervisor(
            testingHooks: ProcessSupervisorTestingHooks(waitErrorForPID: { _ in EINVAL })
        )
        do {
            let handle = try await supervisor.spawn(
                LaunchSpec(
                    executable: executable.url,
                    arguments: ["-c", "printf 'terminal injected fixture\\n'; exit 0"],
                    workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    environment: ProcessInfo.processInfo.environment
                )
            )
            guard await supervisor.terminalIncompatibilityError() == EINVAL else {
                print("TERMINAL_INJECTED_ERROR_NOT_RECORDED")
                return 67
            }
            guard await supervisor.checkExit(handle) == .terminalUnavailable(EINVAL) else {
                print("TERMINAL_INJECTED_ERROR_CHECK_EXIT_FAILED")
                return 68
            }
            guard await supervisor.requestTermination(handle) == .terminalUnavailable(EINVAL) else {
                print("TERMINAL_INJECTED_ERROR_SIGNAL_NOT_REVOKED")
                return 69
            }
            do {
                try await waitUntil("内层 injected terminal pipe EOF") {
                    await supervisor.cleanupComplete()
                }
            } catch {
                print("TERMINAL_INJECTED_ERROR_PIPE_TIMEOUT")
                return 70
            }
            guard !(await supervisor.canSpawn()) else {
                print("TERMINAL_INJECTED_ERROR_SPAWN_NOT_BLOCKED")
                return 71
            }
            print("TERMINAL_INJECTED_ERROR_OK")
            return 0
        } catch {
            print("TERMINAL_INJECTED_ERROR_UNEXPECTED")
            return 72
        }
    }

    static func runLockProbe(arguments: [String]) -> Int32 {
        guard arguments.count == 2 else {
            print("LOCK_PROBE_INVALID_ARGUMENTS")
            return 64
        }

        let lockPath = arguments[0]
        let readyPath = arguments[1]
        for _ in 0 ..< 100 {
            if FileManager.default.fileExists(atPath: readyPath) { break }
            usleep(50_000)
        }
        guard FileManager.default.fileExists(atPath: readyPath) else {
            print("LOCK_PROBE_READY_TIMEOUT")
            return 65
        }

        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            print("LOCK_PROBE_OPEN_FAILED")
            return 66
        }
        defer { _ = close(descriptor) }

        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            print("LOCK_PROBE_ACQUIRED")
            return 0
        }
        print("LOCK_PROBE_CONFLICT")
        return 67
    }

    static func runTermStateProbe() -> Int32 {
        var action = sigaction()
        guard sigaction(SIGTERM, nil, &action) == 0 else {
            print("TERM_STATE_ACTION_FAILED")
            return 64
        }
        var mask = sigset_t()
        guard pthread_sigmask(SIG_SETMASK, nil, &mask) == 0 else {
            print("TERM_STATE_MASK_FAILED")
            return 65
        }

        let handlerAddress: UInt = unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self)
        let defaultHandlerAddress: UInt = unsafeBitCast(SIG_DFL, to: UInt.self)
        let usesDefault = handlerAddress == defaultHandlerAddress
        let isUnblocked = sigismember(&mask, SIGTERM) == 0
        print("TERM_DEFAULT=\(usesDefault ? 1 : 0) TERM_UNBLOCKED=\(isUnblocked ? 1 : 0)")
        return usesDefault && isUnblocked ? 0 : 66
    }

    static func runListener(arguments: [String]) -> Int32 {
        guard arguments.count == 3,
              let requestedPort = UInt16(arguments[0]) else {
            print("LISTENER_INVALID_ARGUMENTS")
            return 64
        }

        let readyURL = URL(fileURLWithPath: arguments[1])
        let stopURL = URL(fileURLWithPath: arguments[2])
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            print("LISTENER_SOCKET_FAILED")
            return 65
        }
        defer { _ = Darwin.close(descriptor) }

        var reuseAddress: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            print("LISTENER_SETSOCKOPT_FAILED")
            return 66
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requestedPort.bigEndian
        let parsedLoopback = "127.0.0.1".withCString {
            inet_pton(AF_INET, $0, &address.sin_addr)
        }
        guard parsedLoopback == 1 else {
            print("LISTENER_ADDRESS_FAILED")
            return 67
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(descriptor, SOMAXCONN) == 0 else {
            print("LISTENER_BIND_FAILED")
            return 68
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            print("LISTENER_NAME_FAILED")
            return 69
        }

        let boundPort = UInt16(bigEndian: boundAddress.sin_port)
        do {
            try Data("\(boundPort)\n".utf8).write(to: readyURL, options: .withoutOverwriting)
        } catch {
            print("LISTENER_READY_FAILED")
            return 70
        }

        while true {
            if FileManager.default.fileExists(atPath: stopURL.path) {
                return 0
            }
            usleep(50_000)
        }
    }

    /// 仅供 App 级端口竞争验收使用。它固定绑定调用方给出的 loopback 端口，
    /// 并返回最小 HTML/未知 manifest 响应；实际停机仍由外层受控 fixture 决定。
    static func runHTTPListener(arguments: [String]) -> Int32 {
        guard arguments.count == 3,
              let requestedPort = UInt16(arguments[0]) else {
            print("HTTP_LISTENER_INVALID_ARGUMENTS")
            return 64
        }

        let readyURL = URL(fileURLWithPath: arguments[1])
        let stopURL = URL(fileURLWithPath: arguments[2])
        let server: FixtureHTTPServer
        do {
            server = try FixtureHTTPServer(port: requestedPort) { path in
                switch path {
                case "/":
                    return .html()
                case "/manifest.webmanifest":
                    return .response(
                        status: 404,
                        headers: ["Content-Type": "text/plain"],
                        body: Data()
                    )
                default:
                    return .response(
                        status: 404,
                        headers: ["Content-Type": "text/plain"],
                        body: Data()
                    )
                }
            }
        } catch {
            print("HTTP_LISTENER_BIND_FAILED")
            return 65
        }
        defer { server.close() }

        do {
            try Data("\(server.port)\n".utf8).write(to: readyURL, options: .withoutOverwriting)
        } catch {
            print("HTTP_LISTENER_READY_FAILED")
            return 66
        }

        while !FileManager.default.fileExists(atPath: stopURL.path) {
            usleep(50_000)
        }
        return 0
    }

    static func requestListenerFixtureExit(at stopURL: URL) throws {
        try Data().write(to: stopURL, options: .withoutOverwriting)
    }
}
