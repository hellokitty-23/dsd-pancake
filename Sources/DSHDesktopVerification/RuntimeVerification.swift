import Darwin
import Dispatch
import Foundation
import DSHDesktopCore
import WebKit
@preconcurrency import SwiftTerm

extension DSHDesktopVerification {
    static func verifyPTYProcessGroupCleanup() async throws {
        let delegate = PTYFixtureDelegate()
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "io.github.hellokitty-23.dsd-pancake.verify.pty")
        )
        defer { process.terminate() }

        // `LocalProcess` / `forkpty` 是与 App 内 LocalProcessTerminalView 相同的 PTY
        // 后端。后台 sleep 用来证明我们清理的是 shell 所在的完整 process group，而
        // 不是只向直接 shell PID 发送一个普通信号。
        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "sleep 30 & child=$!; printf '__DSD_PTY_CHILD__:%s\\n' \"$child\"; wait"],
            environment: [
                "PATH=/usr/bin:/bin",
                "HOME=/tmp",
                "TERM=xterm-256color",
                "LANG=en_US.UTF-8",
            ],
            execName: "-sh",
            currentDirectory: "/tmp"
        )

        let childPID = try await delegate.waitForChildPID(timeoutNanoseconds: 3_000_000_000)
        let shellPID = process.shellPid
        try expect(shellPID > 1, "真实 PTY 未返回 shell PID")
        let shellGroup = getpgid(shellPID)
        let childGroup = getpgid(childPID)
        try expect(shellGroup > 1 && shellGroup == childGroup, "PTY shell 与子进程不在同一 process group")

        try expect(TerminalProcessGroup.send(SIGTERM, to: shellGroup), "无法向 PTY process group 发送 SIGTERM")
        // 当前测试进程有时继承了忽略 SIGTERM 的 disposition（信号处理状态）；这正是
        // App 终端控制器必须有 SIGKILL 兜底的原因。先给正常退出窗口，再验证兜底能
        // 清理仍存活的完整 group。
        try? await Task.sleep(nanoseconds: 400_000_000)
        if Darwin.kill(childPID, 0) == 0 {
            try expect(
                TerminalProcessGroup.send(SIGKILL, to: shellGroup),
                "PTY process group 未响应 SIGTERM 时无法执行 SIGKILL 兜底"
            )
        }
        process.terminate()
        try expect(
            await waitForDirectChildToReap(shellPID, timeoutNanoseconds: 3_000_000_000),
            "关闭终端后 shell 没有被 waitpid 回收"
        )
        try expect(
            await waitForProcessToExit(childPID, timeoutNanoseconds: 3_000_000_000),
            "关闭终端后 PTY 子进程仍然存活"
        )
    }

    static func waitForDirectChildToReap(_ processID: pid_t, timeoutNanoseconds: UInt64) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while true {
            switch TerminalProcessGroup.reapIfExited(processID) {
            case .reaped, .noChild:
                return true
            case .running:
                break
            case .failed:
                return false
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    static func waitForProcessToExit(_ processID: pid_t, timeoutNanoseconds: UInt64) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while true {
            if Darwin.kill(processID, 0) != 0, errno == ESRCH {
                return true
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    static func verifySIGCHLDDispositionAndSingleInstanceLock() throws {
        var action = sigaction()
        try expect(sigaction(SIGCHLD, nil, &action) == 0, "无法读取 SIGCHLD disposition")
        let currentHandler = unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self)
        let ignoredHandler = unsafeBitCast(SIG_IGN, to: UInt.self)
        try expect(currentHandler != ignoredHandler, "SIGCHLD 不得设为 SIG_IGN")
        try expect((action.sa_flags & Int32(SA_NOCLDWAIT)) == 0, "SIGCHLD 不得设置 SA_NOCLDWAIT")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dshdesktop-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try SingleInstanceLock.acquire(
            bundleIdentifier: "io.github.hellokitty-23.dsd-pancake.verification",
            rootDirectory: root
        )
        try expect(first != nil, "首实例未能取得测试锁")
        let second = try SingleInstanceLock.acquire(
            bundleIdentifier: "io.github.hellokitty-23.dsd-pancake.verification",
            rootDirectory: root
        )
        try expect(second == nil, "第二实例错误取得了启动权")
        withExtendedLifetime(first) {}
    }

    static func verifyRingLogAndNavigationPolicy() throws {
        let log = RingLog(lineLimit: 2, byteLimit: 256)
        log.append(Data("first\nsecond".utf8), stream: .stdout)
        log.finish(stream: .stdout)
        log.append(Data("token=secret\nthird\n".utf8), stream: .stderr)
        let entries = log.snapshot()
        try expect(entries.count == 2, "环形日志未按行数上限覆盖")
        try expect(entries.contains { $0.text.contains("[REDACTED]") }, "敏感键值未遮盖")
        let redactedText = entries.map(\.text).joined(separator: "\n")
        try expect(!redactedText.contains("secret"), "普通敏感键值泄漏到日志")
        try expect(log.bytes <= 256, "环形日志超出字节上限")

        let authorizationLog = RingLog(lineLimit: 4, byteLimit: 1_024)
        authorizationLog.append(
            Data("Authorization: Bearer auth-secret\nAuthorization: Basic basic-secret\nCookie: session=session-secret; csrf=csrf-secret\nSet-Cookie: session-cookie-secret; Path=/\n".utf8),
            stream: .stderr
        )
        authorizationLog.finish(stream: .stderr)
        let authorizationText = authorizationLog.snapshot().map(\.text).joined(separator: "\n")
        try expect(!authorizationText.contains("auth-secret"), "Authorization Bearer 值泄漏到日志")
        try expect(!authorizationText.contains("basic-secret"), "Authorization Basic 值泄漏到日志")
        // `Set-Cookie` 可能在日志里被拆成多行；逐条断言而非拼接后跨行匹配，
        // 以验证每个原始头值都已在自己的输出行中遮盖。
        try expect(
            !authorizationLog.snapshot().contains {
                $0.text.contains("session-secret")
                    || $0.text.contains("csrf-secret")
                    || $0.text.contains("session-cookie-secret")
            },
            "Cookie 值泄漏到日志"
        )

        let byteBoundedLog = RingLog(lineLimit: 10, byteLimit: 64)
        byteBoundedLog.append(Data(repeating: 0x61, count: 512), stream: .stdout)
        byteBoundedLog.finish(stream: .stdout)
        try expect(byteBoundedLog.bytes <= 64, "单条超长日志未受字节上限约束")

        let oneByteLog = RingLog(lineLimit: 1, byteLimit: 1)
        oneByteLog.append(Data("😀".utf8), stream: .stdout)
        oneByteLog.finish(stream: .stdout)
        try expect(oneByteLog.bytes <= 1, "多字节日志在极小上限下越界")

        let noNewlineLog = RingLog(lineLimit: 4, byteLimit: 256)
        noNewlineLog.append(Data(repeating: 0x78, count: 512 * 1_024), stream: .stdout)
        try expect(
            noNewlineLog.retainedBytes <= 256,
            "无换行输出使日志驻留内存突破字节上限：\(noNewlineLog.retainedBytes)"
        )
        noNewlineLog.finish(stream: .stdout)
        try expect(noNewlineLog.retainedBytes <= 256, "无换行输出 finish 后仍突破内存上限")

        let fragmentedHeaderLog = RingLog(lineLimit: 8, byteLimit: 1_024)
        let delayedSecret = String(repeating: "p", count: 160) + "fragmented-cookie-secret"
        fragmentedHeaderLog.append(
            Data("Cookie: session=\(delayedSecret)\n".utf8),
            stream: .stdout
        )
        fragmentedHeaderLog.finish(stream: .stdout)
        try expect(
            !fragmentedHeaderLog.snapshot().contains { $0.text.contains("fragmented-cookie-secret") },
            "被切开的超长 Cookie 后半段泄漏到日志"
        )

        let twoStreamLog = RingLog(lineLimit: 32, byteLimit: 256)
        var twoStreamLine = Data(repeating: 0x6F, count: 224)
        twoStreamLine.append(0x0A)
        twoStreamLog.append(twoStreamLine, stream: .stdout)
        twoStreamLog.append(Data(repeating: 0x61, count: 32), stream: .stdout)
        twoStreamLog.append(Data(repeating: 0x62, count: 32), stream: .stderr)
        try expect(twoStreamLog.retainedBytes <= 256, "两路 pending 共同突破日志内存上限")

        let policy = WebNavigationPolicy()
        try expect(
            policy.decision(for: LocalService.url, isMainFrame: true, isUserInitiated: false) == .allowInWebView,
            "同源顶层导航应留在 WebView"
        )
        try expect(
            policy.decision(for: URL(string: "https://example.com")!, isMainFrame: true, isUserInitiated: true) == .openInDefaultBrowser,
            "用户点击外链应交给默认浏览器"
        )
        if case .cancelAndExplain = policy.decision(for: URL(string: "https://example.com")!, isMainFrame: true, isUserInitiated: false) {
            // 预期结果。
        } else {
            throw VerificationError("非用户触发的外链未被阻止")
        }
        if case .cancelAndExplain = policy.decision(for: URL(string: "mailto:test@example.com")!, isMainFrame: true, isUserInitiated: true) {
            // 预期结果。
        } else {
            throw VerificationError("未知协议未被阻止")
        }
        try expect(
            policy.decision(for: URL(string: "https://example.com/image.png")!, isMainFrame: false, isUserInitiated: false) == .allowInWebView,
            "子资源请求不应被顶层导航策略误拦截"
        )
    }

    @MainActor
    static func verifyPersistentWebsiteDataStore() throws {
        try expect(WKWebsiteDataStore.default().isPersistent, "默认 WKWebsiteDataStore 必须为持久化存储")
        try expect(
            !WKWebsiteDataStore.nonPersistent().isPersistent,
            "隔离 Test App 的 WKWebsiteDataStore 不应持久化"
        )
    }

    @MainActor
    static func verifyStandardEditMenu() throws {
        let menu = StandardEditMenu.makeMenu()
        try expect(menu.title == "编辑", "标准编辑菜单标题不正确")

        let expectedItems: [(String, String, String, NSEvent.ModifierFlags)] = [
            ("撤销", "undo:", "z", .command),
            ("重做", "redo:", "z", [.command, .shift]),
            ("剪切", "cut:", "x", .command),
            ("拷贝", "copy:", "c", .command),
            ("粘贴", "paste:", "v", .command),
            ("全选", "selectAll:", "a", .command),
        ]
        for (title, selectorName, keyEquivalent, modifiers) in expectedItems {
            guard let item = menu.items.first(where: { $0.title == title }) else {
                throw VerificationError("编辑菜单缺少 \(title)")
            }
            try expect(item.action == Selector(selectorName), "\(title) 没有标准 selector")
            try expect(item.keyEquivalent == keyEquivalent, "\(title) 快捷键不正确")
            try expect(item.keyEquivalentModifierMask == modifiers, "\(title) 修饰键不正确")
            try expect(item.target == nil, "\(title) 不应绕过 responder chain 设置固定 target")
        }
    }

    static func verifyServiceProbeFixtures() async throws {
        let dshServer = try FixtureHTTPServer { path in
            switch path {
            case "/": .html()
            case "/manifest.webmanifest": .manifest()
            default: .response(status: 404, headers: ["Content-Type": "text/plain"], body: Data())
            }
        }
        defer { dshServer.close() }
        try expect(await ServiceProbe(rootURL: dshServer.rootURL).probe() == .dshLikely, "正常 DSH fixture 未被识别")

        let unknownServer = try FixtureHTTPServer { path in
            switch path {
            case "/": .html()
            case "/manifest.webmanifest": .response(status: 404, headers: ["Content-Type": "text/plain"], body: Data())
            default: .response(status: 404, headers: ["Content-Type": "text/plain"], body: Data())
            }
        }
        defer { unknownServer.close() }
        try expect(
            await ServiceProbe(rootURL: unknownServer.rootURL).probe() == .reachableUnknown(.manifestMissing),
            "manifest 缺失未进入确认分支"
        )

        let nonHTMLServer = try FixtureHTTPServer { _ in
            .response(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        }
        defer { nonHTMLServer.close() }
        try expect(
            await ServiceProbe(rootURL: nonHTMLServer.rootURL).probe() == .reachableNonHTML(.rootNotHTML("application/json")),
            "非 HTML 根响应未进入端口异常分支"
        )

        let statusServer = try FixtureHTTPServer { _ in
            .response(status: 503, headers: ["Content-Type": "text/html"], body: Data("down".utf8))
        }
        defer { statusServer.close() }
        try expect(
            await ServiceProbe(rootURL: statusServer.rootURL).probe() == .reachableNonHTML(.rootNon2xx(503)),
            "非 2xx 根响应未阻止 spawn"
        )

        let sameOriginRedirectServer = try FixtureHTTPServer { path in
            switch path {
            case "/": .response(status: 302, headers: ["Location": "/ready"], body: Data())
            case "/ready": .html()
            case "/manifest.webmanifest": .manifest()
            default: .response(status: 404, headers: ["Content-Type": "text/plain"], body: Data())
            }
        }
        defer { sameOriginRedirectServer.close() }
        try expect(
            await ServiceProbe(rootURL: sameOriginRedirectServer.rootURL).probe() == .dshLikely,
            "同源重定向后的 HTML 未继续软识别"
        )

        let redirectTarget = try FixtureHTTPServer { _ in .html() }
        defer { redirectTarget.close() }
        let crossOriginRedirectServer = try FixtureHTTPServer { _ in
            .response(
                status: 302,
                headers: ["Location": redirectTarget.rootURL.absoluteString],
                body: Data()
            )
        }
        defer { crossOriginRedirectServer.close() }
        let crossOriginResult = await ServiceProbe(rootURL: crossOriginRedirectServer.rootURL).probe()
        try expect(
            crossOriginResult == .reachableNonHTML(.rootCrossOriginRedirect),
            "跨源重定向未进入端口异常分支：\(crossOriginResult)"
        )

        let manifestRedirectTarget = try FixtureHTTPServer { _ in .manifest() }
        defer { manifestRedirectTarget.close() }
        let manifestRedirectServer = try FixtureHTTPServer { path in
            switch path {
            case "/": .html()
            case "/manifest.webmanifest": .response(
                status: 302,
                headers: ["Location": manifestRedirectTarget.rootURL.absoluteString],
                body: Data()
            )
            default: .response(status: 404, headers: ["Content-Type": "text/plain"], body: Data())
            }
        }
        defer { manifestRedirectServer.close() }
        try expect(
            await ServiceProbe(rootURL: manifestRedirectServer.rootURL).probe() == .reachableUnknown(.manifestRedirectRejected),
            "manifest 跨源重定向未进入确认分支"
        )

        let largeBodyServer = try FixtureHTTPServer { _ in
            .response(
                status: 200,
                headers: ["Content-Type": "text/html", "Content-Length": "600000"],
                body: Data()
            )
        }
        defer { largeBodyServer.close() }
        try expect(
            await ServiceProbe(rootURL: largeBodyServer.rootURL).probe() == .reachableNonHTML(.rootBodyTooLarge),
            "超大根响应未被有界读取拒绝"
        )

        let timeoutServer = try FixtureHTTPServer { _ in .holdOpen(microseconds: 5_000_000) }
        defer { timeoutServer.close() }
        let timeoutResult = await ServiceProbe(rootURL: timeoutServer.rootURL).probe()
        try expect(
            timeoutResult == .unavailable(.totalTimeoutBeforeHTTPResponse),
            "无 HTTP 响应的总超时未归类为 unavailable：\(timeoutResult)"
        )
    }

    static func verifyCurrentExternalProbe() async throws {
        let result = await ServiceProbe().probe()
        switch result {
        case .dshLikely:
            // 当前 external DSH 可被软识别；这是本轮开发机的常见状态。
            return
        case .unavailable:
            // owned Finder 验收前，用户可以明确提供一个临时空闲 3080；
            // 验证程序只读检查，不应把这一合法前置条件误报为失败。
            return
        case .reachableUnknown, .reachableNonHTML:
            throw VerificationError("当前 3080 有非 DSH 的 HTTP 响应：\(result)")
        }
    }

}

/// 真实 PTY fixture 的输出只在内存中短暂保存，且仅接受我们固定脚本输出的数字 PID。
/// 它不执行任何来自网页或用户输入的命令。
private final class PTYFixtureDelegate: NSObject, LocalProcessDelegate {
    private let lock = NSLock()
    private var output = ""
    private var childPID: pid_t?

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {}

    func dataReceived(slice: ArraySlice<UInt8>) {
        guard let text = String(bytes: slice, encoding: .utf8) else { return }
        lock.withLock {
            output.append(text)
            guard childPID == nil,
                  let range = output.range(of: "__DSD_PTY_CHILD__:") else {
                return
            }
            let suffix = output[range.upperBound...]
            let digits = suffix.prefix { $0.isNumber }
            if let parsed = Int32(digits), parsed > 1 {
                childPID = pid_t(parsed)
            }
        }
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    }

    func waitForChildPID(timeoutNanoseconds: UInt64) async throws -> pid_t {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let childPID = lock.withLock({ childPID }) {
                return childPID
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        throw VerificationError("真实 PTY fixture 未在期限内报告子进程 PID")
    }
}
