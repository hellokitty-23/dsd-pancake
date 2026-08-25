import Foundation
import DSHDesktopCore

@MainActor
final class UserPreferences {
    private enum Key {
        static let selectedDSHPath = "selectedDSHPath"
        static let completionNotificationMode = "completionNotificationMode"
        static let legacyCompletionNotificationsEnabled = "completionNotificationsEnabled"
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
}
