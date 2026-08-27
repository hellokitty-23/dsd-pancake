import Foundation
import DSHDesktopCore

@MainActor
final class UserPreferences {
    private enum Key {
        static let selectedDSHPath = "selectedDSHPath"
        static let completionNotificationMode = "completionNotificationMode"
        static let legacyCompletionNotificationsEnabled = "completionNotificationsEnabled"
        static let lastAppUpdateCheckAt = "lastAppUpdateCheckAt"
        static let lastDSHUpdateCheckAt = "lastDSHUpdateCheckAt"
        static let cachedAppUpdateLatestVersion = "cachedAppUpdateLatestVersion"
        static let cachedDSHUpdateExecutablePath = "cachedDSHUpdateExecutablePath"
        static let cachedDSHUpdateCurrentVersion = "cachedDSHUpdateCurrentVersion"
        static let cachedDSHUpdateLatestVersion = "cachedDSHUpdateLatestVersion"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedDSHPath: String? {
        get { defaults.string(forKey: Key.selectedDSHPath) }
        set { defaults.set(newValue, forKey: Key.selectedDSHPath) }
    }

    /// 没有历史值时默认只在未聚焦时提醒。旧版的布尔开关会无损映射：开启变为
    /// `.whenUnfocused`，关闭变为 `.never`，因此升级不改变用户已选择的行为。
    var completionNotificationMode: DesktopNotificationDeliveryMode {
        get {
            if let rawValue = defaults.string(forKey: Key.completionNotificationMode),
               let mode = DesktopNotificationDeliveryMode(rawValue: rawValue) {
                return mode
            }

            guard defaults.object(forKey: Key.legacyCompletionNotificationsEnabled) != nil else {
                return .whenUnfocused
            }
            return defaults.bool(forKey: Key.legacyCompletionNotificationsEnabled)
                ? .whenUnfocused
                : .never
        }
        set { defaults.set(newValue.rawValue, forKey: Key.completionNotificationMode) }
    }

    /// 时间只用于决定下一次静默检查是否到期，不用于行为分析或遥测。
    var lastAppUpdateCheckAt: Date? {
        get { defaults.object(forKey: Key.lastAppUpdateCheckAt) as? Date }
        set { setDate(newValue, forKey: Key.lastAppUpdateCheckAt) }
    }

    var lastDSHUpdateCheckAt: Date? {
        get { defaults.object(forKey: Key.lastDSHUpdateCheckAt) as? Date }
        set { setDate(newValue, forKey: Key.lastDSHUpdateCheckAt) }
    }

    /// 仅保存版本号；恢复时由固定仓库地址重新生成 Release 和下载 URL，避免将带签名的
    /// 重定向地址或任何远端响应正文留在本机偏好中。
    var cachedAppUpdate: CachedAppUpdate? {
        get {
            guard let rawValue = defaults.string(forKey: Key.cachedAppUpdateLatestVersion),
                  let version = SemanticVersion(rawValue),
                  !version.isPrerelease else {
                return nil
            }
            return CachedAppUpdate(latestVersion: version)
        }
        set {
            if let newValue {
                defaults.set(newValue.latestVersion.rawValue, forKey: Key.cachedAppUpdateLatestVersion)
            } else {
                defaults.removeObject(forKey: Key.cachedAppUpdateLatestVersion)
            }
        }
    }

    /// DSH 缓存绑定实际可执行文件路径和当时版本；任一值不匹配时调用方会丢弃它。
    var cachedDSHUpdate: CachedDSHUpdate? {
        get {
            guard let executablePath = defaults.string(forKey: Key.cachedDSHUpdateExecutablePath),
                  let currentRawValue = defaults.string(forKey: Key.cachedDSHUpdateCurrentVersion),
                  let latestRawValue = defaults.string(forKey: Key.cachedDSHUpdateLatestVersion),
                  let currentVersion = SemanticVersion(currentRawValue),
                  let latestVersion = SemanticVersion(latestRawValue),
                  !latestVersion.isPrerelease else {
                return nil
            }
            return CachedDSHUpdate(
                executablePath: executablePath,
                currentVersion: currentVersion,
                latestVersion: latestVersion
            )
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.cachedDSHUpdateExecutablePath)
                defaults.removeObject(forKey: Key.cachedDSHUpdateCurrentVersion)
                defaults.removeObject(forKey: Key.cachedDSHUpdateLatestVersion)
                return
            }
            defaults.set(newValue.executablePath, forKey: Key.cachedDSHUpdateExecutablePath)
            defaults.set(newValue.currentVersion.rawValue, forKey: Key.cachedDSHUpdateCurrentVersion)
            defaults.set(newValue.latestVersion.rawValue, forKey: Key.cachedDSHUpdateLatestVersion)
        }
    }

    private func setDate(_ value: Date?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
