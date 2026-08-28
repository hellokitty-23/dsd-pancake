import Darwin
import Dispatch
import Foundation
import DSHDesktopCore
import WebKit
@preconcurrency import SwiftTerm

extension DSHDesktopVerification {
    static func verifyNotificationPluginAndBridgeProtocol() throws {
        let replyEvent = DesktopNotificationEvent(eventID: "reply:session-1:42", kind: .reply)
        try expect(replyEvent != nil, "有效提醒事件 ID 被拒绝")
        let expectedReply = DesktopNotificationBridgeAction.notify(replyEvent!)
        let replyBody: [String: Any] = [
            "version": NSNumber(value: DesktopNotificationBridge.protocolVersion),
            "action": "notify",
            "eventID": "reply:session-1:42",
            "kind": "reply",
        ]
        try expect(DesktopNotificationBridge.decode(replyBody) == expectedReply, "有效 reply 桥事件未被解析")
        try expect(
            DesktopNotificationBridgeAdmission.decode(
                replyBody,
                bridgeEnabled: true,
                isMainFrame: true,
                originScheme: LocalService.url.scheme ?? "",
                originHost: LocalService.host,
                originPort: LocalService.port
            ) == expectedReply,
            "已授权主 frame 的本地通知桥事件未被准入"
        )
        try expect(
            DesktopNotificationBridgeAdmission.decode(
                replyBody,
                bridgeEnabled: false,
                isMainFrame: true,
                originScheme: LocalService.url.scheme ?? "",
                originHost: LocalService.host,
                originPort: LocalService.port
            ) == nil,
            "未授权的通知桥事件未被拒绝"
        )
        try expect(
            DesktopNotificationBridgeAdmission.decode(
                replyBody,
                bridgeEnabled: true,
                isMainFrame: false,
                originScheme: LocalService.url.scheme ?? "",
                originHost: LocalService.host,
                originPort: LocalService.port
            ) == nil,
            "子 frame 的通知桥事件未被拒绝"
        )
        try expect(
            DesktopNotificationBridgeAdmission.decode(
                replyBody,
                bridgeEnabled: true,
                isMainFrame: true,
                originScheme: "https",
                originHost: "example.invalid",
                originPort: 443
            ) == nil,
            "非本地 origin 的通知桥事件未被拒绝"
        )
        try expect(
            DesktopNotificationBridge.decode([
                "version": NSNumber(value: true),
                "action": "capabilities",
            ]) == nil,
            "Boolean 被错误接受为协议版本"
        )
        try expect(
            DesktopNotificationBridge.decode([
                "version": NSNumber(value: DesktopNotificationBridge.protocolVersion),
                "action": "capabilities",
                "extra": "forbidden",
            ]) == nil,
            "未知桥字段未被拒绝"
        )
        try expect(
            DesktopNotificationBridge.decode([
                "version": NSNumber(value: DesktopNotificationBridge.protocolVersion),
                "action": "notify",
                "eventID": "含有自由文本",
                "kind": "reply",
            ]) == nil,
            "自由文本事件 ID 未被拒绝"
        )
        try expect(
            DesktopNotificationKind.goalComplete.body == "任务已完成"
                && DesktopNotificationKind.goalBlocked.body == "任务需要你处理",
            "通知正文不应从网页携带内容"
        )
        try expect(
            !DesktopNotificationPresentationPolicy.shouldPresent(
                applicationIsActive: true,
                mainWindowIsVisible: true,
                mainWindowIsMiniaturized: false
            ),
            "前台可见窗口仍会显示重复提醒"
        )
        try expect(
            DesktopNotificationPresentationPolicy.shouldPresent(
                applicationIsActive: true,
                mainWindowIsVisible: false,
                mainWindowIsMiniaturized: false
            ) && DesktopNotificationPresentationPolicy.shouldPresent(
                applicationIsActive: false,
                mainWindowIsVisible: true,
                mainWindowIsMiniaturized: false
            ) && DesktopNotificationPresentationPolicy.shouldPresent(
                applicationIsActive: true,
                mainWindowIsVisible: true,
                mainWindowIsMiniaturized: true
            ),
            "窗口隐藏、失焦或最小化时应允许提醒"
        )
        try expect(
            !DesktopNotificationDeliveryPolicy.shouldDeliver(
                mode: .never,
                applicationIsActive: false,
                mainWindowIsVisible: false,
                mainWindowIsMiniaturized: false
            ),
            "永不模式仍允许投递"
        )
        try expect(
            DesktopNotificationDeliveryPolicy.shouldDeliver(
                mode: .whenUnfocused,
                applicationIsActive: false,
                mainWindowIsVisible: true,
                mainWindowIsMiniaturized: false
            ),
            "仅在未聚焦时模式错误阻断失焦提醒"
        )
        try expect(
            !DesktopNotificationDeliveryPolicy.shouldDeliver(
                mode: .whenUnfocused,
                applicationIsActive: true,
                mainWindowIsVisible: true,
                mainWindowIsMiniaturized: false
            ),
            "仅在未聚焦时模式错误允许前台可见提醒"
        )
        try expect(
            DesktopNotificationDeliveryPolicy.shouldDeliver(
                mode: .always,
                applicationIsActive: true,
                mainWindowIsVisible: true,
                mainWindowIsMiniaturized: false
            ),
            "一律模式错误阻断前台可见提醒"
        )

        var recent = RecentNotificationEventIDs(capacity: 2)
        try expect(recent.insertIfNew("one"), "首个事件未被接受")
        try expect(!recent.insertIfNew("one"), "重复事件未去重")
        try expect(recent.insertIfNew("two") && recent.insertIfNew("three"), "有界去重未接受新事件")
        try expect(recent.insertIfNew("one"), "超出容量后最旧事件未允许重新出现")

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("dsd-pancake-notification-plugin-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let pluginDirectory = root.appendingPathComponent("plugin", isDirectory: true)
        try fileManager.createDirectory(
            at: pluginDirectory.appendingPathComponent("lib", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{\"name\":\"@dsd-pancake/dsh-desktop-notifications\"}".utf8)
            .write(to: pluginDirectory.appendingPathComponent("package.json"))
        try Data("[]\n".utf8).write(to: pluginDirectory.appendingPathComponent("cordis.patch.yml"))
        try Data("export function apply() {}\n".utf8)
            .write(to: pluginDirectory.appendingPathComponent("lib/index.js"))
        try Data("window.__ModuleLoader__.load({})\n".utf8)
            .write(to: pluginDirectory.appendingPathComponent("lib/client.js"))

        guard let plugin = DSHNotificationPlugin(directory: pluginDirectory) else {
            throw VerificationError("完整的 App 私有提醒插件未被识别")
        }
        let workingDirectory = root.appendingPathComponent("workspace", isDirectory: true)
        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let configuredHome = root.appendingPathComponent("dsh-home", isDirectory: true)
        try plugin.prepareResolver(
            baseEnvironment: ["DSH_HOME": configuredHome.path],
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        let resolverLink = configuredHome
            .appendingPathComponent("profiles/node_modules/@dsd-pancake/dsh-desktop-notifications")
        let linkedPath = try fileManager.destinationOfSymbolicLink(atPath: resolverLink.path)
        try expect(
            URL(fileURLWithPath: linkedPath, isDirectory: true).standardizedFileURL == pluginDirectory.standardizedFileURL,
            "提醒插件 resolver 链接未指向 App 私有插件"
        )
        try plugin.prepareResolver(
            baseEnvironment: ["DSH_HOME": configuredHome.path],
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        try expect(plugin.patchURL.lastPathComponent == "cordis.patch.yml", "提醒覆盖层路径不正确")

        try expect(
            DSHNotificationPlugin.resolveDSHHome(
                baseEnvironment: ["DSH_HOME": "relative-home"],
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory
            ) == workingDirectory.appendingPathComponent("relative-home", isDirectory: true).standardizedFileURL,
            "相对 DSH_HOME 没有按 DSH 工作目录解析"
        )
        try expect(
            DSHNotificationPlugin.resolveDSHHome(
                baseEnvironment: ["DSH_HOME": "~/custom-dsh"],
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory
            ) == homeDirectory.appendingPathComponent("custom-dsh", isDirectory: true).standardizedFileURL,
            "波浪号 DSH_HOME 没有按用户目录展开"
        )

        let occupiedHome = root.appendingPathComponent("occupied-home", isDirectory: true)
        let occupiedPath = occupiedHome
            .appendingPathComponent("profiles/node_modules/@dsd-pancake/dsh-desktop-notifications")
        try fileManager.createDirectory(at: occupiedPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a symlink".utf8).write(to: occupiedPath)
        do {
            try plugin.prepareResolver(
                baseEnvironment: ["DSH_HOME": occupiedHome.path],
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
            throw VerificationError("占用的 resolver 路径被错误覆盖")
        } catch let error as DSHNotificationPluginError {
            guard case .resolverPathOccupied = error else {
                throw VerificationError("占用 resolver 路径返回了错误类型：\(error)")
            }
        }

        let foreignHome = root.appendingPathComponent("foreign-link-home", isDirectory: true)
        let foreignTarget = root.appendingPathComponent("foreign-plugin", isDirectory: true)
        try fileManager.createDirectory(at: foreignTarget, withIntermediateDirectories: true)
        try Data("{\"name\":\"@someone-else/plugin\"}".utf8)
            .write(to: foreignTarget.appendingPathComponent("package.json"))
        let foreignLink = foreignHome
            .appendingPathComponent("profiles/node_modules/@dsd-pancake/dsh-desktop-notifications")
        try fileManager.createDirectory(at: foreignLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: foreignLink.path, withDestinationPath: foreignTarget.path)
        do {
            try plugin.prepareResolver(
                baseEnvironment: ["DSH_HOME": foreignHome.path],
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
            throw VerificationError("未知 resolver 符号链接被错误覆盖")
        } catch let error as DSHNotificationPluginError {
            guard case .resolverPathOccupied = error else {
                throw VerificationError("未知 resolver 符号链接返回了错误类型：\(error)")
            }
        }
        try expect(
            try fileManager.destinationOfSymbolicLink(atPath: foreignLink.path) == foreignTarget.path,
            "未知 resolver 符号链接被修改"
        )

        let sameNameHome = root.appendingPathComponent("same-name-link-home", isDirectory: true)
        let sameNameTarget = root.appendingPathComponent("same-name-plugin", isDirectory: true)
        try fileManager.createDirectory(at: sameNameTarget, withIntermediateDirectories: true)
        try Data("{\"name\":\"@dsd-pancake/dsh-desktop-notifications\"}".utf8)
            .write(to: sameNameTarget.appendingPathComponent("package.json"))
        let sameNameLink = sameNameHome
            .appendingPathComponent("profiles/node_modules/@dsd-pancake/dsh-desktop-notifications")
        try fileManager.createDirectory(at: sameNameLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: sameNameLink.path, withDestinationPath: sameNameTarget.path)
        do {
            try plugin.prepareResolver(
                baseEnvironment: ["DSH_HOME": sameNameHome.path],
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
            throw VerificationError("现存同名 resolver 符号链接被错误覆盖")
        } catch let error as DSHNotificationPluginError {
            guard case .resolverPathOccupied = error else {
                throw VerificationError("现存同名 resolver 符号链接返回了错误类型：\(error)")
            }
        }
        try expect(
            try fileManager.destinationOfSymbolicLink(atPath: sameNameLink.path) == sameNameTarget.path,
            "现存同名 resolver 符号链接被修改"
        )

        let symlinkScopeHome = root.appendingPathComponent("symlink-scope-home", isDirectory: true)
        let externalScope = root.appendingPathComponent("external-resolver-scope", isDirectory: true)
        try fileManager.createDirectory(at: externalScope, withIntermediateDirectories: true)
        let symlinkScope = symlinkScopeHome
            .appendingPathComponent("profiles/node_modules/@dsd-pancake", isDirectory: true)
        try fileManager.createDirectory(at: symlinkScope.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: symlinkScope.path, withDestinationPath: externalScope.path)
        let escapedResolver = externalScope
            .appendingPathComponent("dsh-desktop-notifications", isDirectory: false)
        do {
            try plugin.prepareResolver(
                baseEnvironment: ["DSH_HOME": symlinkScopeHome.path],
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
            throw VerificationError("符号链接 scope 错误允许写入外部目录")
        } catch let error as DSHNotificationPluginError {
            guard case let .resolverPathOccupied(path) = error, path == symlinkScope.path else {
                throw VerificationError("符号链接 scope 返回了错误类型或路径：\(error)")
            }
        }
        try expect(
            !fileManager.fileExists(atPath: escapedResolver.path),
            "符号链接 scope 在外部目录创建了 resolver"
        )
        try expect(
            try fileManager.destinationOfSymbolicLink(atPath: symlinkScope.path) == externalScope.path,
            "符号链接 scope 被修改"
        )

        let staleHome = root.appendingPathComponent("stale-link-home", isDirectory: true)
        let staleLink = staleHome
            .appendingPathComponent("profiles/node_modules/@dsd-pancake/dsh-desktop-notifications")
        try fileManager.createDirectory(at: staleLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            atPath: staleLink.path,
            withDestinationPath: root.appendingPathComponent("missing-old-app-plugin").path
        )
        try plugin.prepareResolver(
            baseEnvironment: ["DSH_HOME": staleHome.path],
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        try expect(
            try fileManager.destinationOfSymbolicLink(atPath: staleLink.path) == pluginDirectory.path,
            "移动 App 后的失效 resolver 链接未被修复"
        )
    }

    static func verifyTerminalPluginBridgeAndDockLayout() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("dsd-pancake-terminal-plugin-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        guard let request = DesktopTerminalWorkspaceRequest(
            sessionID: "session-42",
            workspacePath: workspaceURL.path
        ), let workspace = DesktopTerminalWorkspace(request: request, fileManager: fileManager) else {
            throw VerificationError("有效终端 workspace 请求未通过本机目录校验")
        }

        let syncBody: [String: Any] = [
            "version": NSNumber(value: DesktopTerminalBridge.protocolVersion),
            "action": "syncWorkspace",
            "sessionID": request.sessionID,
            "workspacePath": request.workspacePath,
        ]
        try expect(
            DesktopTerminalBridge.decode(syncBody) == .syncWorkspace(request),
            "有效终端 workspace bridge 请求未被解析"
        )
        try expect(
            DesktopTerminalBridge.decode([
                "version": NSNumber(value: DesktopTerminalBridge.protocolVersion),
                "action": "clearWorkspace",
            ]) == .clearWorkspace,
            "有效终端 workspace 清除请求未被解析"
        )
        try expect(
            DesktopTerminalBridge.decode([
                "version": NSNumber(value: true),
                "action": "capabilities",
            ]) == nil,
            "Boolean 被错误接受为终端 bridge 协议版本"
        )
        try expect(
            DesktopTerminalBridge.decode([
                "version": NSNumber(value: DesktopTerminalBridge.protocolVersion),
                "action": "syncWorkspace",
                "sessionID": request.sessionID,
                "workspacePath": request.workspacePath,
                "command": "echo forbidden",
            ]) == nil,
            "包含 command 的终端 bridge 请求未被拒绝"
        )
        try expect(
            DesktopTerminalBridge.decode([
                "version": NSNumber(value: DesktopTerminalBridge.protocolVersion),
                "action": "syncWorkspace",
                "sessionID": request.sessionID,
                "workspacePath": "relative/workspace",
            ]) == nil,
            "相对 workspace path 被终端 bridge 接受"
        )
        try expect(
            DesktopTerminalBridge.decode([
                "version": NSNumber(value: DesktopTerminalBridge.protocolVersion),
                "action": "toggle",
                "sessionID": request.sessionID,
                "workspacePath": request.workspacePath,
            ]) == nil,
            "网页仍可通过 bridge 请求显示或隐藏原生终端"
        )
        try expect(
            DesktopTerminalWorkspaceRequest(
                sessionID: "session-42",
                workspacePath: workspaceURL.path + "\nunsafe"
            ) == nil,
            "带控制字符的 workspace path 被终端 bridge 接受"
        )

        try expect(
            DesktopTerminalBridgeAdmission.decode(
                syncBody,
                bridgeEnabled: false,
                isMainFrame: true,
                originScheme: LocalService.url.scheme ?? "",
                originHost: LocalService.host,
                originPort: LocalService.port
            ) == nil,
            "bridge 被禁用时仍接收终端操作"
        )
        try expect(
            DesktopTerminalBridgeAdmission.decode(
                syncBody,
                bridgeEnabled: true,
                isMainFrame: false,
                originScheme: LocalService.url.scheme ?? "",
                originHost: LocalService.host,
                originPort: LocalService.port
            ) == nil,
            "非主 frame 的终端 bridge 消息被接收"
        )
        try expect(
            DesktopTerminalBridgeAdmission.decode(
                syncBody,
                bridgeEnabled: true,
                isMainFrame: true,
                originScheme: "https",
                originHost: "example.com",
                originPort: 443
            ) == nil,
            "错误 origin 的终端 bridge 消息被接收"
        )
        try expect(
            DesktopTerminalBridgeAdmission.decode(
                syncBody,
                bridgeEnabled: true,
                isMainFrame: true,
                originScheme: LocalService.url.scheme ?? "",
                originHost: LocalService.host,
                originPort: LocalService.port
            ) == .syncWorkspace(request),
            "已启用的本地主 frame 终端 bridge 消息未通过"
        )
        try expect(
            DesktopTerminalWorkspace(
                request: DesktopTerminalWorkspaceRequest(
                    sessionID: "session-42",
                    workspacePath: root.appendingPathComponent("missing", isDirectory: true).path
                )!,
                fileManager: fileManager
            ) == nil,
            "不存在的 workspace 允许启动终端"
        )

        let response = DesktopTerminalBridgeResponse.payload(supported: false, isOpen: false, workspaceAccepted: false)
        try expect(
            response["supported"] as? Bool == false
                && response["open"] as? Bool == false
                && response["workspacePath"] == nil,
            "终端 bridge 禁用响应泄漏路径或状态错误"
        )
        var state = WorkspaceTerminalState()
        try expect(state.show(workspace: workspace) == .created, "首个 workspace 没有创建独立终端")
        guard let firstTab = state.activeTab else {
            throw VerificationError("首个 workspace 没有激活终端标签")
        }
        state.hide()
        try expect(
            !state.isPanelVisible && state.knownWorkspaces.contains(workspace) && state.tabs(for: workspace) == [firstTab],
            "收起面板错误结束了 shell 身份"
        )
        try expect(state.show(workspace: workspace) == .reused, "同一 workspace 切换 session 时没有复用终端")
        let secondTab = state.createTab(workspace: workspace)
        try expect(
            secondTab.id != firstTab.id
                && secondTab.ordinal == 2
                && state.tabs(for: workspace).count == 2
                && state.activeTab == secondTab,
            "新建终端标签没有创建独立 shell 身份"
        )
        try expect(
            state.select(tabID: firstTab.id) == firstTab && state.activeTab == firstTab,
            "同一 workspace 的终端标签不能切换"
        )
        try expect(
            state.close(tabID: firstTab.id) == firstTab
                && state.activeTab == secondTab
                && state.isPanelVisible,
            "关闭一个终端标签错误结束了同 workspace 的其它 shell"
        )

        let secondWorkspaceURL = root.appendingPathComponent("workspace-two", isDirectory: true)
        try fileManager.createDirectory(at: secondWorkspaceURL, withIntermediateDirectories: true)
        let secondRequest = DesktopTerminalWorkspaceRequest(
            sessionID: "session-43",
            workspacePath: secondWorkspaceURL.path
        )!
        let secondWorkspace = DesktopTerminalWorkspace(request: secondRequest, fileManager: fileManager)!
        try expect(state.show(workspace: secondWorkspace) == .created, "不同 workspace 错误复用了第一个终端")
        guard let secondWorkspaceTab = state.activeTab else {
            throw VerificationError("第二个 workspace 没有创建终端标签")
        }
        try expect(state.knownWorkspaces.count == 2, "不同 workspace 没有隔离终端状态")
        state.synchronize(workspace: workspace)
        try expect(
            !state.isPanelVisible && state.activeWorkspace == workspace && state.activeTab == secondTab,
            "workspace 切换时旧终端仍显示在新会话"
        )
        try expect(
            state.select(tabID: secondWorkspaceTab.id) == nil && state.activeTab == secondTab,
            "其它 workspace 的终端标签能显示在当前会话"
        )
        state.clearActiveWorkspace()
        try expect(
            !state.isPanelVisible && state.activeWorkspace == nil && state.knownWorkspaces.count == 2,
            "没有有效 workspace 时错误结束了已有 shell 或保留了旧会话身份"
        )
        state.synchronize(workspace: workspace)
        try expect(state.closeActiveTab() == secondTab, "关闭当前终端标签未返回正确标签")
        try expect(!state.knownWorkspaces.contains(workspace) && state.knownWorkspaces.contains(secondWorkspace), "关闭一个标签错误影响其它 workspace")
        try expect(state.closeAll() == Set([secondWorkspace]), "关闭全部终端没有精确返回待清理 workspace")

        let collapsed = TerminalDockLayout.collapsed(totalHeight: 700)
        let expanded = TerminalDockLayout.expanded(totalHeight: 700, requestedPanelHeight: 280)
        let oversized = TerminalDockLayout.expanded(totalHeight: 700, requestedPanelHeight: 9_999)
        let undersized = TerminalDockLayout.expanded(totalHeight: 700, requestedPanelHeight: 1)
        try expect(
            collapsed.webHeight == 700 && collapsed.panelHeight == 0,
            "收起状态没有让 WebView 占满原生内容区"
        )
        try expect(
            expanded.panelHeight == 280 && expanded.webHeight == collapsed.webHeight,
            "展开终端错误缩短了同时承载 DSH 侧栏的 WKWebView"
        )
        try expect(
            collapsed.conversationReservedHeight == 0
                && expanded.conversationReservedHeight == expanded.panelHeight + expanded.dividerHeight,
            "终端 dock 没有为右侧对话流提供与原生面板一致的预留高度"
        )
        try expect(
            oversized.panelHeight <= (700 - TerminalDockLayout.dividerHeight) * TerminalDockLayout.maximumFraction,
            "终端面板突破窗口 50% 高度上限"
        )
        try expect(
            TerminalDockLayout.dividerHeight == 1,
            "终端 dock 的可见分隔线必须保持为 1pt，避免割裂对话与终端"
        )
        try expect(TerminalDockLayout.maximumFraction == 0.5, "终端高度上限必须固定为可用窗口高度的 50%")
        try expect(
            undersized.panelHeight >= TerminalDockLayout.minimumPanelHeight,
            "常规窗口下终端面板未遵守 160px 最小高度"
        )
        let contentRegion = TerminalDockLayout.contentRegion(totalWidth: 1_280, sidebarWidth: 368)
        try expect(
            contentRegion.leading == 368 && contentRegion.width == 912,
            "终端 dock 没有从 DSH 左侧工程栏右边开始"
        )
        let fallbackRegion = TerminalDockLayout.contentRegion(totalWidth: 500, sidebarWidth: nil)
        try expect(
            fallbackRegion.leading == 260 && fallbackRegion.width == TerminalDockLayout.minimumContentWidth,
            "网页侧栏宽度尚未到达时的终端 dock 回退区域不安全"
        )

        let pluginDirectory = root.appendingPathComponent("plugin", isDirectory: true)
        try fileManager.createDirectory(
            at: pluginDirectory.appendingPathComponent("lib", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{\"name\":\"@dsd-pancake/dsh-desktop-terminal\"}".utf8)
            .write(to: pluginDirectory.appendingPathComponent("package.json"))
        try Data("[]\n".utf8).write(to: pluginDirectory.appendingPathComponent("cordis.patch.yml"))
        try Data("export function apply() {}\n".utf8)
            .write(to: pluginDirectory.appendingPathComponent("lib/index.js"))
        try Data("window.__ModuleLoader__.load({})\n".utf8)
            .write(to: pluginDirectory.appendingPathComponent("lib/client.js"))

        guard let plugin = DSHTerminalPlugin(directory: pluginDirectory, fileManager: fileManager) else {
            throw VerificationError("完整的 App 私有终端插件未被识别")
        }
        let configuredHome = root.appendingPathComponent("dsh-home", isDirectory: true)
        try plugin.prepareResolver(
            baseEnvironment: ["DSH_HOME": configuredHome.path],
            workingDirectory: workspaceURL,
            homeDirectory: root.appendingPathComponent("home", isDirectory: true),
            fileManager: fileManager
        )
        let resolverLink = configuredHome
            .appendingPathComponent("profiles/node_modules/@dsd-pancake/dsh-desktop-terminal")
        try expect(
            URL(
                fileURLWithPath: try fileManager.destinationOfSymbolicLink(atPath: resolverLink.path),
                isDirectory: true
            ).standardizedFileURL == pluginDirectory.standardizedFileURL,
            "终端插件 resolver 链接未指向 App 私有插件"
        )
        try expect(plugin.patchURL.lastPathComponent == "cordis.patch.yml", "终端覆盖层路径不正确")
    }

    static func verifyOperationFoldingPlugin() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("dsd-pancake-operation-folding-plugin-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let pluginDirectory = root.appendingPathComponent("plugin", isDirectory: true)
        try fileManager.createDirectory(
            at: pluginDirectory.appendingPathComponent("lib", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{\"name\":\"@dsd-pancake/dsh-desktop-operation-folding\"}".utf8)
            .write(to: pluginDirectory.appendingPathComponent("package.json"))
        try Data("[]\n".utf8).write(to: pluginDirectory.appendingPathComponent("cordis.patch.yml"))
        try Data("export function apply() {}\n".utf8)
            .write(to: pluginDirectory.appendingPathComponent("lib/index.js"))
        try Data("window.__ModuleLoader__.load({})\n".utf8)
            .write(to: pluginDirectory.appendingPathComponent("lib/client.js"))

        guard let plugin = DSHOperationFoldingPlugin(directory: pluginDirectory, fileManager: fileManager) else {
            throw VerificationError("完整的 App 私有执行操作折叠插件未被识别")
        }
        let configuredHome = root.appendingPathComponent("dsh-home", isDirectory: true)
        try plugin.prepareResolver(
            baseEnvironment: ["DSH_HOME": configuredHome.path],
            workingDirectory: root,
            homeDirectory: root.appendingPathComponent("home", isDirectory: true),
            fileManager: fileManager
        )
        let resolverLink = configuredHome
            .appendingPathComponent("profiles/node_modules/@dsd-pancake/dsh-desktop-operation-folding")
        try expect(
            URL(
                fileURLWithPath: try fileManager.destinationOfSymbolicLink(atPath: resolverLink.path),
                isDirectory: true
            ).standardizedFileURL == pluginDirectory.standardizedFileURL,
            "操作折叠插件 resolver 链接未指向 App 私有插件"
        )
        try expect(plugin.patchURL.lastPathComponent == "cordis.patch.yml", "操作折叠覆盖层路径不正确")
    }

    static func verifyShortcutPlugin() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("dsd-pancake-shortcut-plugin-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let pluginDirectory = root.appendingPathComponent("plugin", isDirectory: true)
        try fileManager.createDirectory(
            at: pluginDirectory.appendingPathComponent("lib", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{\"name\":\"@dsd-pancake/dsh-desktop-shortcuts\"}".utf8)
            .write(to: pluginDirectory.appendingPathComponent("package.json"))
        try Data("[]\n".utf8).write(to: pluginDirectory.appendingPathComponent("cordis.patch.yml"))
        try Data("export function apply() {}\n".utf8)
            .write(to: pluginDirectory.appendingPathComponent("lib/index.js"))
        try Data("window.__ModuleLoader__.load({})\n".utf8)
            .write(to: pluginDirectory.appendingPathComponent("lib/client.js"))

        guard let plugin = DSHShortcutPlugin(directory: pluginDirectory, fileManager: fileManager) else {
            throw VerificationError("完整的 App 私有快捷键插件未被识别")
        }
        let configuredHome = root.appendingPathComponent("dsh-home", isDirectory: true)
        try plugin.prepareResolver(
            baseEnvironment: ["DSH_HOME": configuredHome.path],
            workingDirectory: root,
            homeDirectory: root.appendingPathComponent("home", isDirectory: true),
            fileManager: fileManager
        )
        let resolverLink = configuredHome
            .appendingPathComponent("profiles/node_modules/@dsd-pancake/dsh-desktop-shortcuts")
        try expect(
            URL(
                fileURLWithPath: try fileManager.destinationOfSymbolicLink(atPath: resolverLink.path),
                isDirectory: true
            ).standardizedFileURL == pluginDirectory.standardizedFileURL,
            "快捷键插件 resolver 链接未指向 App 私有插件"
        )
        try expect(plugin.patchURL.lastPathComponent == "cordis.patch.yml", "快捷键覆盖层路径不正确")
    }

}
