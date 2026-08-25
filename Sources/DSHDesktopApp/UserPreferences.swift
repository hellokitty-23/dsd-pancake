import Foundation

@MainActor
final class UserPreferences {
    private enum Key {
        static let selectedDSHPath = "selectedDSHPath"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedDSHPath: String? {
        get { defaults.string(forKey: Key.selectedDSHPath) }
        set { defaults.set(newValue, forKey: Key.selectedDSHPath) }
    }
}
