import AppKit
import DSHDesktopCore

enum AppCheckResult {
    case available(AppUpdateCheck)
    case current(AppUpdateCheck)
    case failed(String)

    var hasUpdate: Bool {
        if case .available = self { return true }
        return false
    }

    var summary: String {
        switch self {
        case let .available(check):
            return "DSD Pancake：可选更新 \(check.currentVersion) → \(check.latestVersion)"
        case let .current(check):
            switch check.disposition {
            case .upToDate:
                return "DSD Pancake：已是最新版本 \(check.currentVersion) (\(check.currentBuild))"
            case .newerThanLatest:
                return "DSD Pancake：当前版本 \(check.currentVersion) 高于 GitHub latest \(check.latestVersion)"
            case .updateAvailable:
                return "DSD Pancake：发现可选更新 \(check.latestVersion)"
            }
        case let .failed(message):
            return "DSD Pancake：检查失败\n\(message)"
        }
    }
}

enum DSHCheckResult {
    case available(DSHUpdateCheck)
    case current(DSHUpdateCheck)
    case failed(String)

    var hasUpdate: Bool {
        if case .available = self { return true }
        return false
    }

    var summary: String {
        switch self {
        case let .available(check):
            return "DeepSeek Harness：可选更新 \(check.currentVersion) → \(check.latestVersion)"
        case let .current(check):
            switch check.disposition {
            case .upToDate:
                return "DeepSeek Harness：已是最新版本 \(check.currentVersion)"
            case .newerThanLatest:
                return "DeepSeek Harness：当前版本 \(check.currentVersion) 高于 npm latest \(check.latestVersion)"
            case .updateAvailable:
                return "DeepSeek Harness：发现可选更新 \(check.latestVersion)"
            }
        case let .failed(message):
            return "DeepSeek Harness：检查失败\n\(message)"
        }
    }
}

struct UpdateCheckReport {
    let app: AppCheckResult
    let dsh: DSHCheckResult

    var hasOptionalUpdate: Bool {
        app.hasUpdate || dsh.hasUpdate
    }

    var summary: String {
        app.summary + "\n\n" + dsh.summary
    }
}

/// 原生标题栏只需要知道是否存在可选更新，不能接触网页、下载任务或 npm 安装细节。
struct UpdateAvailability: Equatable {
    var app: AppUpdateCheck?
    var dsh: CachedDSHUpdate?

    static let none = Self(app: nil, dsh: nil)

    var count: Int {
        (app == nil ? 0 : 1) + (dsh == nil ? 0 : 1)
    }

    var hasUpdates: Bool {
        count > 0
    }
}

/// 集中管理两种只读更新检查的时间表与最小缓存。它从不弹窗、下载或安装；UI 只在用户
/// 点击壳层标题栏图标或菜单时才显示结果／后续操作。
@MainActor
final class UpdateStatusController {
    private let preferences: UserPreferences
    private let appUpdateService: AppUpdateService
    private let dshUpdateService: DSHUpdateService
    private let dshLocator: DSHLocator
    private let schedule: AutomaticUpdateCheckSchedule
    private var automaticTimer: Timer?
    private var automaticTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var isStarted = false

    private(set) var availability = UpdateAvailability.none {
        didSet {
            guard availability != oldValue else { return }
            onAvailabilityChange?(availability)
        }
    }
    private(set) var isChecking = false
    var onAvailabilityChange: ((UpdateAvailability) -> Void)? {
        didSet { onAvailabilityChange?(availability) }
    }

    init(
        preferences: UserPreferences,
        appUpdateService: AppUpdateService = AppUpdateService(),
        dshUpdateService: DSHUpdateService = DSHUpdateService(),
        dshLocator: DSHLocator = DSHLocator(),
        schedule: AutomaticUpdateCheckSchedule = .hourly
    ) {
        self.preferences = preferences
        self.appUpdateService = appUpdateService
        self.dshUpdateService = dshUpdateService
        self.dshLocator = dshLocator
        self.schedule = schedule
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        installWakeObserver()
        restoreCachedAppUpdate()

        let now = Date()
        let dueSources = schedule.dueSources(
            lastAppCheckAt: preferences.lastAppUpdateCheckAt,
            lastDSHCheckAt: preferences.lastDSHUpdateCheckAt,
            now: now
        )
        if !dueSources.isEmpty {
            beginAutomaticCheck(sources: dueSources)
        } else {
            validateCachedDSHUpdateThenSchedule()
        }
    }

    func stop() {
        isStarted = false
        automaticTimer?.invalidate()
        automaticTimer = nil
        automaticTask?.cancel()
        automaticTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// 菜单的显式操作仍返回完整的两项结果；与后台轮询共用同一读路径和缓存规则，
    /// 但不会自动选择、下载或更新其中任何一项。
    func checkManually() async -> UpdateCheckReport? {
        guard !isChecking else { return nil }
        automaticTimer?.invalidate()
        automaticTimer = nil
        isChecking = true
        defer {
            isChecking = false
            scheduleNextAutomaticCheck()
        }

        let (appResult, dshResult) = await check(sources: [.app, .dsh])
        guard !Task.isCancelled else { return nil }
        let checkedAt = Date()
        apply(appResult: appResult, dshResult: dshResult, checkedAt: checkedAt)
        return UpdateCheckReport(
            app: appResult ?? .failed("检查没有启动。"),
            dsh: dshResult ?? .failed("检查没有启动。")
        )
    }

    /// 从 Popover 点击“更新 DSH”前必须重新读取本机版本和 npm latest，不能直接使用
    /// 缓存版本进入写入流程。该显式操作只检查 DSH，不会顺带安装或下载 App。
    func checkDSHForExplicitUpdate() async -> DSHCheckResult? {
        guard !isChecking else { return nil }
        automaticTimer?.invalidate()
        automaticTimer = nil
        isChecking = true
        defer {
            isChecking = false
            scheduleNextAutomaticCheck()
        }
        let result = await checkDSHIfNeeded(true)
        guard !Task.isCancelled, let result else { return nil }
        apply(appResult: nil, dshResult: result, checkedAt: Date())
        return result
    }

    /// DSH 安装后立即移除旧版本提示，避免旧缓存与重新启动后的实际可执行文件不一致。
    func clearCachedDSHUpdate() {
        preferences.cachedDSHUpdate = nil
        availability.dsh = nil
    }

    private func installWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runAutomaticCheckIfDue()
            }
        }
    }

    private func restoreCachedAppUpdate() {
        guard let cached = preferences.cachedAppUpdate else { return }
        let identity = appIdentity()
        guard let currentVersion = SemanticVersion(identity.version),
              cached.applies(to: currentVersion),
              let check = AppUpdateService.cachedCheck(
                  currentVersion: identity.version,
                  currentBuild: identity.build,
                  latestVersion: cached.latestVersion.rawValue
              ), check.disposition == .updateAvailable else {
            preferences.cachedAppUpdate = nil
            return
        }
        availability.app = check
    }

    private func validateCachedDSHUpdateThenSchedule() {
        guard isStarted else { return }
        guard let cached = preferences.cachedDSHUpdate else {
            scheduleNextAutomaticCheck()
            return
        }
        guard !isChecking else { return }
        isChecking = true
        automaticTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isChecking = false
                self.automaticTask = nil
                self.scheduleNextAutomaticCheck()
            }
            guard let executable = self.dshLocator.locate(lastChosenPath: self.preferences.selectedDSHPath),
                  executable.url.path == cached.executablePath else {
                self.preferences.cachedDSHUpdate = nil
                self.availability.dsh = nil
                return
            }
            do {
                let currentVersion = try await self.dshUpdateService.currentVersion(executable: executable)
                if cached.applies(to: executable.url.path, currentVersion: currentVersion) {
                    self.availability.dsh = cached
                } else {
                    self.preferences.cachedDSHUpdate = nil
                    self.availability.dsh = nil
                }
            } catch is CancellationError {
                return
            } catch {
                // 已确认路径没有改变但本次版本读取失败时，不把已有的有效提示伪装成
                // “无更新”；下次到期后仍会独立重试。路径／版本已确认变化的分支才清除。
            }
        }
    }

    private func runAutomaticCheckIfDue() {
        guard isStarted, !isChecking else { return }
        let sources = schedule.dueSources(
            lastAppCheckAt: preferences.lastAppUpdateCheckAt,
            lastDSHCheckAt: preferences.lastDSHUpdateCheckAt,
            now: Date()
        )
        guard !sources.isEmpty else {
            scheduleNextAutomaticCheck()
            return
        }
        beginAutomaticCheck(sources: sources)
    }

    private func beginAutomaticCheck(sources: AutomaticUpdateCheckSources) {
        guard isStarted, !sources.isEmpty, !isChecking else { return }
        automaticTimer?.invalidate()
        automaticTimer = nil
        isChecking = true
        automaticTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.finishAutomaticCheck(sources: sources)
            }
            let (appResult, dshResult) = await self.check(sources: sources)
            guard !Task.isCancelled else { return }
            self.apply(appResult: appResult, dshResult: dshResult, checkedAt: Date())
        }
    }

    private func scheduleNextAutomaticCheck() {
        automaticTimer?.invalidate()
        automaticTimer = nil
        guard isStarted, !isChecking else { return }

        let fireDate = schedule.nextCheckAt(
            lastAppCheckAt: preferences.lastAppUpdateCheckAt,
            lastDSHCheckAt: preferences.lastDSHUpdateCheckAt,
            now: Date()
        )
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runAutomaticCheckIfDue()
            }
        }
        timer.tolerance = min(60, schedule.interval / 10)
        automaticTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func check(
        sources: AutomaticUpdateCheckSources
    ) async -> (AppCheckResult?, DSHCheckResult?) {
        async let appResult = checkAppIfNeeded(sources.contains(.app))
        async let dshResult = checkDSHIfNeeded(sources.contains(.dsh))
        return await (appResult, dshResult)
    }

    private func checkAppIfNeeded(_ required: Bool) async -> AppCheckResult? {
        guard required else { return nil }
        let identity = appIdentity()
        do {
            let check = try await appUpdateService.check(
                currentVersion: identity.version,
                currentBuild: identity.build
            )
            return check.disposition == .updateAvailable ? .available(check) : .current(check)
        } catch is CancellationError {
            return .failed("检查已取消。")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func checkDSHIfNeeded(_ required: Bool) async -> DSHCheckResult? {
        guard required else { return nil }
        guard let executable = dshLocator.locate(lastChosenPath: preferences.selectedDSHPath) else {
            // 找不到当前 DSH 时不能继续展示上一份路径的缓存；这不是错误图标，只是
            // 没有可确认的 DSH 更新对象。
            preferences.cachedDSHUpdate = nil
            availability.dsh = nil
            return .failed("未找到可执行的 dsh；App 更新检查仍已独立完成。")
        }
        invalidateCachedDSHUpdateIfNeeded(executablePath: executable.url.path)
        do {
            let currentVersion = try await dshUpdateService.currentVersion(executable: executable)
            invalidateCachedDSHUpdateIfNeeded(
                executablePath: executable.url.path,
                currentVersion: currentVersion
            )
            let check = try await dshUpdateService.check(
                executable: executable,
                currentVersion: currentVersion
            )
            return check.disposition == .updateAvailable ? .available(check) : .current(check)
        } catch is CancellationError {
            return .failed("检查已取消。")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// DSH 缓存不能跨可执行文件或其当前版本复用。路径改变时无需执行任何命令就可
    /// 清除；版本改变则在受控的 `dsh --version` 成功返回后立即清除，再决定是否查询 npm。
    private func invalidateCachedDSHUpdateIfNeeded(
        executablePath: String,
        currentVersion: SemanticVersion? = nil
    ) {
        guard let cached = preferences.cachedDSHUpdate else { return }
        guard cached.executablePath == executablePath,
              currentVersion.map({ cached.currentVersion == $0 }) ?? true else {
            preferences.cachedDSHUpdate = nil
            availability.dsh = nil
            return
        }
    }

    private func finishAutomaticCheck(sources: AutomaticUpdateCheckSources) {
        isChecking = false
        automaticTask = nil
        guard isStarted else { return }

        // 只有 App 到期、DSH 仍在一小时内但带有跨启动缓存时，补一次本机版本核对。
        // 它不查询 npm，也不刷新 DSH 的检查时间；这样不会把旧提示无故隐藏。
        if !sources.contains(.dsh), preferences.cachedDSHUpdate != nil {
            validateCachedDSHUpdateThenSchedule()
        } else {
            scheduleNextAutomaticCheck()
        }
    }

    private func apply(
        appResult: AppCheckResult?,
        dshResult: DSHCheckResult?,
        checkedAt: Date
    ) {
        var cacheState = AutomaticUpdateCheckState(
            lastAppCheckAt: preferences.lastAppUpdateCheckAt,
            lastDSHCheckAt: preferences.lastDSHUpdateCheckAt,
            appUpdate: preferences.cachedAppUpdate,
            dshUpdate: preferences.cachedDSHUpdate
        )
        cacheState.apply(
            appResult: appResult.map(appCacheResult),
            dshResult: dshResult.map(dshCacheResult),
            checkedAt: checkedAt
        )
        preferences.lastAppUpdateCheckAt = cacheState.lastAppCheckAt
        preferences.lastDSHUpdateCheckAt = cacheState.lastDSHCheckAt
        preferences.cachedAppUpdate = cacheState.appUpdate
        preferences.cachedDSHUpdate = cacheState.dshUpdate

        if let appResult {
            switch appResult {
            case let .available(check):
                availability.app = check
            case .current:
                availability.app = nil
            case .failed:
                // 保留已验证过的旧提示；失败不会伪装成“已是最新”。
                break
            }
        }

        if let dshResult {
            switch dshResult {
            case let .available(check):
                availability.dsh = CachedDSHUpdate(
                    executablePath: check.dshExecutable.path,
                    currentVersion: check.currentVersion,
                    latestVersion: check.latestVersion
                )
            case .current:
                availability.dsh = nil
            case .failed:
                // 保留已验证过的旧提示；失败不会伪装成“已是最新”。
                break
            }
        }
    }

    private func appCacheResult(
        _ result: AppCheckResult
    ) -> AutomaticUpdateCheckResult<CachedAppUpdate> {
        switch result {
        case let .available(check):
            .available(CachedAppUpdate(latestVersion: check.latestVersion))
        case .current:
            .current
        case .failed:
            .failed
        }
    }

    private func dshCacheResult(
        _ result: DSHCheckResult
    ) -> AutomaticUpdateCheckResult<CachedDSHUpdate> {
        switch result {
        case let .available(check):
            .available(
                CachedDSHUpdate(
                    executablePath: check.dshExecutable.path,
                    currentVersion: check.currentVersion,
                    latestVersion: check.latestVersion
                )
            )
        case .current:
            .current
        case .failed:
            .failed
        }
    }

    private func appIdentity() -> (version: String, build: String) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "未知"
        return (version, build)
    }
}
