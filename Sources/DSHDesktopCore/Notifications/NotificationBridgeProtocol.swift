import Foundation

/// DSH 可选插件与原生 App 之间的最小桥协议。事件不携带消息正文、标题、路径或 Cookie。
public enum DesktopNotificationBridge {
    public static let messageName = "dsdPancakeNotifications"
    public static let protocolVersion = 1

    /// 严格解析来自 WebKit 的 JSON 形对象。未知字段一律拒绝，避免桥接口在未来被悄然扩大。
    public static func decode(_ body: Any) -> DesktopNotificationBridgeAction? {
        guard let dictionary = body as? [String: Any],
              integer(dictionary["version"]) == protocolVersion,
              let action = dictionary["action"] as? String else {
            return nil
        }

        switch action {
        case "capabilities":
            guard Set(dictionary.keys) == ["version", "action"] else { return nil }
            return .capabilities

        case "requestAuthorization":
            guard Set(dictionary.keys) == ["version", "action"] else { return nil }
            return .requestAuthorization

        case "notify":
            guard Set(dictionary.keys) == ["version", "action", "eventID", "kind"],
                  let eventID = dictionary["eventID"] as? String,
                  let rawKind = dictionary["kind"] as? String,
                  let kind = DesktopNotificationKind(rawValue: rawKind),
                  let event = DesktopNotificationEvent(eventID: eventID, kind: kind) else {
                return nil
            }
            return .notify(event)

        default:
            return nil
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue.rounded(.towardZero) == doubleValue,
              doubleValue >= Double(Int.min),
              doubleValue <= Double(Int.max) else {
            return nil
        }
        return Int(doubleValue)
    }
}

public enum DesktopNotificationBridgeAction: Equatable, Sendable {
    case capabilities
    case requestAuthorization
    case notify(DesktopNotificationEvent)
}

public enum DesktopNotificationKind: String, CaseIterable, Equatable, Sendable {
    case reply
    case goalComplete = "goal-complete"
    case goalBlocked = "goal-blocked"

    /// 固定文案避免把用户对话、任务标题或本机路径写进锁屏和通知中心。
    public var body: String {
        switch self {
        case .reply:
            "对话已有回复"
        case .goalComplete:
            "任务已完成"
        case .goalBlocked:
            "任务需要你处理"
        }
    }
}

public struct DesktopNotificationEvent: Equatable, Sendable {
    public let eventID: String
    public let kind: DesktopNotificationKind

    public init?(eventID: String, kind: DesktopNotificationKind) {
        guard Self.isOpaqueEventID(eventID) else { return nil }
        self.eventID = eventID
        self.kind = kind
    }

    /// DSH 的 UUID/修订号组合即可满足这个格式；不接受自由文本，从源头缩小隐私面。
    private static func isOpaqueEventID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 192 else { return false }
        return bytes.allSatisfy { byte in
            switch byte {
            case 48 ... 57, 65 ... 90, 97 ... 122, 45, 46, 58, 95:
                true
            default:
                false
            }
        }
    }
}

/// 仅在前台且主窗口可见时压制提醒，避免用户正在阅读同一页面时又收到横幅。
public enum DesktopNotificationPresentationPolicy {
    public static func shouldPresent(
        applicationIsActive: Bool,
        mainWindowIsVisible: Bool,
        mainWindowIsMiniaturized: Bool
    ) -> Bool {
        !(applicationIsActive && mainWindowIsVisible && !mainWindowIsMiniaturized)
    }
}

/// App 内对完成提醒的三种持久化投递模式。它只影响这层 App 私有 bridge，
/// 不改写 macOS 的授权状态，也不会修改 DSH 或让已运行的服务重启。
public enum DesktopNotificationDeliveryMode: String, CaseIterable, Equatable, Hashable, Sendable {
    case never
    case whenUnfocused
    case always
}

public enum DesktopNotificationDeliveryPolicy {
    public static func shouldDeliver(
        mode: DesktopNotificationDeliveryMode,
        applicationIsActive: Bool,
        mainWindowIsVisible: Bool,
        mainWindowIsMiniaturized: Bool
    ) -> Bool {
        switch mode {
        case .never:
            false
        case .whenUnfocused:
            DesktopNotificationPresentationPolicy.shouldPresent(
                applicationIsActive: applicationIsActive,
                mainWindowIsVisible: mainWindowIsVisible,
                mainWindowIsMiniaturized: mainWindowIsMiniaturized
            )
        case .always:
            true
        }
    }
}

/// App 生命周期内的有界去重；不落盘，也不保留会话内容。
public struct RecentNotificationEventIDs: Equatable, Sendable {
    private let capacity: Int
    private var orderedIDs: [String] = []
    private var knownIDs: Set<String> = []

    public init(capacity: Int = 128) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    /// 仅首次出现的 ID 返回 `true`。
    @discardableResult
    public mutating func insertIfNew(_ eventID: String) -> Bool {
        guard !knownIDs.contains(eventID) else { return false }
        orderedIDs.append(eventID)
        knownIDs.insert(eventID)

        if orderedIDs.count > capacity {
            let removed = orderedIDs.removeFirst()
            knownIDs.remove(removed)
        }
        return true
    }
}
