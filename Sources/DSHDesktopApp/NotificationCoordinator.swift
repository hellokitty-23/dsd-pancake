import AppKit
import DSHDesktopCore
import OSLog
import UserNotifications

/// 原生通知的唯一副作用边界。DSH 插件只提交最小事件；授权、前台抑制、去重和通知点击都留在 App 内。
@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private static let presentWhenActiveKey = "dsdPancakePresentWhenActive"

    private enum Authorization: String {
        case authorized
        case denied
        case notDetermined
    }

    private let center: UNUserNotificationCenter
    private let shouldDeliver: () -> Bool
    private let shouldPresentWhenActive: () -> Bool
    private let restoreMainWindow: () -> Void
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.hellokitty-23.dsd-pancake",
        category: "notifications"
    )
    private var recentEventIDs = RecentNotificationEventIDs()
    private var authorizationRequestTask: Task<Authorization, Never>?

    init(
        center: UNUserNotificationCenter = .current(),
        shouldDeliver: @escaping () -> Bool,
        shouldPresentWhenActive: @escaping () -> Bool,
        restoreMainWindow: @escaping () -> Void
    ) {
        self.center = center
        self.shouldDeliver = shouldDeliver
        self.shouldPresentWhenActive = shouldPresentWhenActive
        self.restoreMainWindow = restoreMainWindow
        super.init()
        center.delegate = self
    }

    /// 授权属于 App 级偏好，启动时直接询问一次；它不依赖网页插件先完成桥握手，
    /// 因此不会因网页初始化顺序而漏掉 macOS 的系统授权提示。
    func activateIfNeeded() {
        logger.debug("Evaluating notification authorization for an App-owned DSH service.")
        Task { [weak self] in
            guard let self else { return }
            let status = await self.requestAuthorizationIfNeeded()
            self.logger.notice("Notification authorization resolved as \(status.rawValue, privacy: .public).")
        }
    }

    func handle(_ action: DesktopNotificationBridgeAction) async -> [String: Any] {
        switch action {
        case .capabilities:
            return response(authorization: await authorization())

        case .requestAuthorization:
            return response(authorization: await requestAuthorizationIfNeeded())

        case let .notify(event):
            let current = await authorization()
            guard current == .authorized else {
                return response(authorization: current, accepted: false)
            }
            guard shouldDeliver() else {
                return response(authorization: current, accepted: false)
            }
            guard recentEventIDs.insertIfNew(event.eventID) else {
                return response(authorization: current, accepted: false)
            }

            do {
                try await addNotification(for: event)
                return response(authorization: current, accepted: true)
            } catch {
                return response(authorization: current, accepted: false)
            }
        }
    }

    private func response(authorization: Authorization, accepted: Bool? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "version": DesktopNotificationBridge.protocolVersion,
            "supported": true,
            "authorization": authorization.rawValue,
        ]
        if let accepted {
            payload["accepted"] = accepted
        }
        return payload
    }

    private func authorization() async -> Authorization {
        let rawStatus: Int = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            center.getNotificationSettings { settings in
                // `UNNotificationSettings` 是 Objective-C 可变引用类型；只跨并发边界
                // 传递稳定的整数状态，避免把整个对象移交给 MainActor。
                continuation.resume(returning: settings.authorizationStatus.rawValue)
            }
        }

        guard let status = UNAuthorizationStatus(rawValue: rawStatus) else {
            return .denied
        }
        return switch status {
        case .authorized, .provisional, .ephemeral:
            .authorized
        case .denied:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            .denied
        }
    }

    /// 将原生启动路径与网页 bridge 的并发请求合并为同一项系统授权操作，避免两个
    /// requestAuthorization 调用竞争，也保证 bridge 收到最终状态而非中间的
    /// `notDetermined`。
    private func requestAuthorizationIfNeeded() async -> Authorization {
        let task: Task<Authorization, Never>
        if let authorizationRequestTask {
            task = authorizationRequestTask
        } else {
            let createdTask = Task { @MainActor [weak self] in
                guard let self else { return Authorization.denied }
                let current = await self.authorization()
                guard current == .notDetermined else { return current }
                self.logger.debug("Requesting macOS notification authorization.")
                let granted = await self.requestAuthorization()
                self.logger.notice("macOS notification authorization completion granted=\(granted, privacy: .public).")
                return await self.authorization()
            }
            authorizationRequestTask = createdTask
            task = createdTask
        }

        let result = await task.value
        authorizationRequestTask = nil
        return result
    }

    private func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func addNotification(for event: DesktopNotificationEvent) async throws {
        let content = UNMutableNotificationContent()
        content.title = "DSD Pancake"
        content.body = event.kind.body
        // 该标记只描述本次请求能否在前台展示，不携带网页或用户数据。它让
        // `willPresent` 可在非 MainActor（主 actor）回调中安全地决定横幅策略。
        content.userInfo = [Self.presentWhenActiveKey: shouldPresentWhenActive()]

        let request = UNNotificationRequest(
            // event ID 已受桥协议约束为不透明 ASCII；不用 UUID，避免建立另一份
            // 无法复核的事件标识，也让系统同一事件的重投递天然合并。
            identifier: "dsd-pancake-notification-\(event.eventID)",
            content: content,
            trigger: nil
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // “仅在未聚焦时”在竞态下回到前台仍不显示；“一律”在创建请求时写入
        // 这个无敏感标记，因此不需要从非隔离回调访问 MainActor 状态。
        let shouldPresent = notification.request.content.userInfo[Self.presentWhenActiveKey] as? Bool == true
        completionHandler(shouldPresent ? [.banner] : [])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // 先在回调线程完成系统要求的 reply，再把纯 UI 动作转交给 MainActor。
        completionHandler()
        Task { @MainActor [weak self] in
            self?.restoreMainWindow()
        }
    }
}
