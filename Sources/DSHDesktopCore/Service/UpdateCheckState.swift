import Foundation

/// 自动检查只记录每个独立来源最近一次尝试的时间。App 从睡眠恢复后只重新计算“是否到期”，
/// 不补跑睡眠期间错过的每一个时间点。
public struct AutomaticUpdateCheckSchedule: Equatable, Sendable {
    public static let hourly = Self(interval: 60 * 60)

    public let interval: TimeInterval

    public init(interval: TimeInterval) {
        self.interval = max(1, interval)
    }

    public func isDue(lastCheckAt: Date?, now: Date) -> Bool {
        guard let lastCheckAt else { return true }
        return now >= lastCheckAt.addingTimeInterval(interval)
    }

    public func dueSources(
        lastAppCheckAt: Date?,
        lastDSHCheckAt: Date?,
        now: Date
    ) -> AutomaticUpdateCheckSources {
        var result: AutomaticUpdateCheckSources = []
        if isDue(lastCheckAt: lastAppCheckAt, now: now) {
            result.insert(.app)
        }
        if isDue(lastCheckAt: lastDSHCheckAt, now: now) {
            result.insert(.dsh)
        }
        return result
    }

    /// 返回下一次单次 Timer（计时器）应触发的时间。调用方每次检查完成后重新安排一个
    /// Timer，因此睡眠恢复后最多只会补一轮到期检查。
    public func nextCheckAt(
        lastAppCheckAt: Date?,
        lastDSHCheckAt: Date?,
        now: Date
    ) -> Date {
        min(
            nextCheckAt(lastCheckAt: lastAppCheckAt, now: now),
            nextCheckAt(lastCheckAt: lastDSHCheckAt, now: now)
        )
    }

    private func nextCheckAt(lastCheckAt: Date?, now: Date) -> Date {
        guard let lastCheckAt else { return now }
        return max(now, lastCheckAt.addingTimeInterval(interval))
    }
}

public struct AutomaticUpdateCheckSources: OptionSet, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let app = Self(rawValue: 1 << 0)
    public static let dsh = Self(rawValue: 1 << 1)
}

/// UserDefaults（用户偏好存储）只持久化这个最小信息；固定 GitHub 地址可在恢复时重新推导，
/// 不保存远端响应正文、下载链接中的签名参数或任何网页数据。
public struct CachedAppUpdate: Equatable, Sendable {
    public let latestVersion: SemanticVersion

    public init(latestVersion: SemanticVersion) {
        self.latestVersion = latestVersion
    }

    public func applies(to currentVersion: SemanticVersion) -> Bool {
        currentVersion < latestVersion
    }
}

/// DSH 缓存必须绑定产生它的可执行文件和当前版本。路径或版本一旦变化，旧缓存就不能继续
/// 作为更新提示的依据，避免将另一份 DSH 安装误显示为可更新。
public struct CachedDSHUpdate: Equatable, Sendable {
    public let executablePath: String
    public let currentVersion: SemanticVersion
    public let latestVersion: SemanticVersion

    public init(executablePath: String, currentVersion: SemanticVersion, latestVersion: SemanticVersion) {
        self.executablePath = executablePath
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
    }

    public var isUpdateAvailable: Bool {
        currentVersion < latestVersion
    }

    public func applies(to executablePath: String, currentVersion: SemanticVersion) -> Bool {
        self.executablePath == executablePath && self.currentVersion == currentVersion && isUpdateAvailable
    }
}

/// 一次来源检查对最小缓存的纯状态影响。失败刻意不携带错误文本，避免把网络、npm 或
/// 本机命令细节写进偏好；调用方可在内存中单独展示手动检查结果。
public enum AutomaticUpdateCheckResult<Value: Equatable & Sendable>: Equatable, Sendable {
    case available(Value)
    case current
    case failed
}

/// 不依赖 AppKit、网络或文件系统的自动更新缓存归约器。App 层把它的字段映射到
/// `UserDefaults`，因此可用注入的时间戳验证首次启动、手动刷新与独立失败分支，而不必
/// 真的等待一小时或访问 GitHub／npm。
public struct AutomaticUpdateCheckState: Equatable, Sendable {
    public private(set) var lastAppCheckAt: Date?
    public private(set) var lastDSHCheckAt: Date?
    public private(set) var appUpdate: CachedAppUpdate?
    public private(set) var dshUpdate: CachedDSHUpdate?

    public init(
        lastAppCheckAt: Date? = nil,
        lastDSHCheckAt: Date? = nil,
        appUpdate: CachedAppUpdate? = nil,
        dshUpdate: CachedDSHUpdate? = nil
    ) {
        self.lastAppCheckAt = lastAppCheckAt
        self.lastDSHCheckAt = lastDSHCheckAt
        self.appUpdate = appUpdate
        self.dshUpdate = dshUpdate
    }

    /// `nil` 表示该来源本轮没有启动；非 nil（包括失败）都表示已尝试，因此更新对应
    /// 时间。失败保留之前已经确认的提示，成功判定为 current 才清除它。
    public mutating func apply(
        appResult: AutomaticUpdateCheckResult<CachedAppUpdate>?,
        dshResult: AutomaticUpdateCheckResult<CachedDSHUpdate>?,
        checkedAt: Date
    ) {
        if let appResult {
            lastAppCheckAt = checkedAt
            switch appResult {
            case let .available(update):
                appUpdate = update
            case .current:
                appUpdate = nil
            case .failed:
                break
            }
        }

        if let dshResult {
            lastDSHCheckAt = checkedAt
            switch dshResult {
            case let .available(update):
                dshUpdate = update
            case .current:
                dshUpdate = nil
            case .failed:
                break
            }
        }
    }

    /// App 更新只在本机版本仍低于缓存 latest 时成立；追平或高于时立即清除。
    public mutating func invalidateAppUpdate(for currentVersion: SemanticVersion) {
        guard let appUpdate, !appUpdate.applies(to: currentVersion) else { return }
        self.appUpdate = nil
    }

    /// DSH 缓存只对生成它的同一路径、同一当前版本成立。找不到可执行文件时调用方传
    /// `nil`，也会清除提示而不是把另一份安装误显示为可更新。
    public mutating func invalidateDSHUpdate(
        executablePath: String?,
        currentVersion: SemanticVersion?
    ) {
        guard let dshUpdate else { return }
        guard let executablePath,
              let currentVersion,
              dshUpdate.applies(to: executablePath, currentVersion: currentVersion) else {
            self.dshUpdate = nil
            return
        }
    }

    public var availableUpdateCount: Int {
        (appUpdate == nil ? 0 : 1) + (dshUpdate == nil ? 0 : 1)
    }
}

/// 原生标题栏只需一个稳定、可访问的短标签；网页与私有插件不会参与这个状态。
public enum UpdateIndicatorPresentation {
    /// 图标是“存在可选更新”的状态提示，而非检查更新的常驻入口。手动检查结果由当次
    /// 原生确认弹窗呈现；确认没有可选更新后，标题栏必须立刻回到无图标状态。
    public static func isVisible(forAvailableUpdateCount count: Int) -> Bool {
        count > 0
    }

    public static func label(forAvailableUpdateCount count: Int) -> String? {
        if count > 0 {
            return "发现 \(count) 项可选更新"
        }
        return nil
    }
}
