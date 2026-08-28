import DSHDesktopCore
import Foundation

struct PrivatePluginBridgeCapabilities: Equatable {
    var notification = false
    var terminal = false

    static let disabled = PrivatePluginBridgeCapabilities()
}

/// 管理四个 App 私有插件的一次启动状态。resolver 准备、spawn 句柄绑定和
/// bridge capability（通信能力）授权是三个分离步骤，调用方不能从第一步跳到第三步。
@MainActor
final class PrivatePluginController {
    private(set) var launchState = PrivatePluginLaunchState()
    private(set) var bridgeCapabilities = PrivatePluginBridgeCapabilities.disabled

    func beginStartup() {
        bridgeCapabilities = .disabled
        launchState.reset(clearScheduledFallback: false)
    }

    func preparePatches(
        baseEnvironment: [String: String],
        homeDirectory: URL,
        resourceRoot: URL?
    ) -> PrivatePluginPatchSet {
        guard launchState.beginPreparation(), let resourceRoot else {
            return PrivatePluginPatchSet()
        }

        var patches = PrivatePluginPatchSet()
        prepareNotification(
            into: &patches,
            resourceRoot: resourceRoot,
            baseEnvironment: baseEnvironment,
            homeDirectory: homeDirectory
        )
        prepareTerminal(
            into: &patches,
            resourceRoot: resourceRoot,
            baseEnvironment: baseEnvironment,
            homeDirectory: homeDirectory
        )
        prepareOperationFolding(
            into: &patches,
            resourceRoot: resourceRoot,
            baseEnvironment: baseEnvironment,
            homeDirectory: homeDirectory
        )
        prepareShortcut(
            into: &patches,
            resourceRoot: resourceRoot,
            baseEnvironment: baseEnvironment,
            homeDirectory: homeDirectory
        )
        return patches
    }

    func bindPreparedPatches(to handle: SpawnHandle) {
        launchState.bindPreparedPlugins(to: handle)
    }

    /// 只有 `verifyLocalServiceOwnership` 的 verified 结果和相同句柄才能开启桥。
    func authorizeBridges(
        ownershipVerification: LocalServiceOwnershipVerification,
        handle: SpawnHandle
    ) -> PrivatePluginBridgeCapabilities {
        bridgeCapabilities = PrivatePluginBridgeCapabilities(
            notification: PrivatePluginBridgeAdmission.mayEnable(
                .notification,
                ownershipVerification: ownershipVerification,
                launchState: launchState,
                handle: handle
            ),
            terminal: PrivatePluginBridgeAdmission.mayEnable(
                .terminal,
                ownershipVerification: ownershipVerification,
                launchState: launchState,
                handle: handle
            )
        )
        return bridgeCapabilities
    }

    func revokeBridges() -> PrivatePluginBridgeCapabilities {
        bridgeCapabilities = .disabled
        return bridgeCapabilities
    }

    func markReady(for handle: SpawnHandle) {
        launchState.markReady(for: handle)
    }

    func scheduleFallbackIfNeeded(for handle: SpawnHandle, quitPending: Bool) -> Bool {
        let scheduled = launchState.scheduleFallbackIfNeeded(
            for: handle,
            quitPending: quitPending
        )
        if scheduled { bridgeCapabilities = .disabled }
        return scheduled
    }

    func reset() {
        launchState.reset()
        bridgeCapabilities = .disabled
    }

    private func prepareNotification(
        into patches: inout PrivatePluginPatchSet,
        resourceRoot: URL,
        baseEnvironment: [String: String],
        homeDirectory: URL
    ) {
        guard let plugin = DSHNotificationPlugin(
            directory: resourceRoot.appendingPathComponent(
                DSHNotificationPlugin.resourcesDirectoryName,
                isDirectory: true
            )
        ) else { return }
        do {
            try plugin.prepareResolver(
                baseEnvironment: baseEnvironment,
                workingDirectory: homeDirectory,
                homeDirectory: homeDirectory
            )
            patches[.notification] = plugin.patchURL
            launchState.recordPrepared(.notification)
        } catch {}
    }

    private func prepareTerminal(
        into patches: inout PrivatePluginPatchSet,
        resourceRoot: URL,
        baseEnvironment: [String: String],
        homeDirectory: URL
    ) {
        guard let plugin = DSHTerminalPlugin(
            directory: resourceRoot.appendingPathComponent(
                DSHTerminalPlugin.resourcesDirectoryName,
                isDirectory: true
            )
        ) else { return }
        do {
            try plugin.prepareResolver(
                baseEnvironment: baseEnvironment,
                workingDirectory: homeDirectory,
                homeDirectory: homeDirectory
            )
            patches[.terminal] = plugin.patchURL
            launchState.recordPrepared(.terminal)
        } catch {}
    }

    private func prepareOperationFolding(
        into patches: inout PrivatePluginPatchSet,
        resourceRoot: URL,
        baseEnvironment: [String: String],
        homeDirectory: URL
    ) {
        guard let plugin = DSHOperationFoldingPlugin(
            directory: resourceRoot.appendingPathComponent(
                DSHOperationFoldingPlugin.resourcesDirectoryName,
                isDirectory: true
            )
        ) else { return }
        do {
            try plugin.prepareResolver(
                baseEnvironment: baseEnvironment,
                workingDirectory: homeDirectory,
                homeDirectory: homeDirectory
            )
            patches[.operationFolding] = plugin.patchURL
            launchState.recordPrepared(.operationFolding)
        } catch {}
    }

    private func prepareShortcut(
        into patches: inout PrivatePluginPatchSet,
        resourceRoot: URL,
        baseEnvironment: [String: String],
        homeDirectory: URL
    ) {
        guard let plugin = DSHShortcutPlugin(
            directory: resourceRoot.appendingPathComponent(
                DSHShortcutPlugin.resourcesDirectoryName,
                isDirectory: true
            )
        ) else { return }
        do {
            try plugin.prepareResolver(
                baseEnvironment: baseEnvironment,
                workingDirectory: homeDirectory,
                homeDirectory: homeDirectory
            )
            patches[.shortcut] = plugin.patchURL
            launchState.recordPrepared(.shortcut)
        } catch {}
    }
}
