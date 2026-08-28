import Darwin
import Dispatch
import Foundation
import DSHDesktopCore
import WebKit
@preconcurrency import SwiftTerm

extension DSHDesktopVerification {
    static func verifyDSHUpdateFoundation() async throws {
        guard let rc2 = SemanticVersion("0.1.1-rc.2"),
              let rc10 = SemanticVersion("0.1.1-rc.10"),
              let stable = SemanticVersion("0.1.1"),
              let nextPatch = SemanticVersion("0.1.2"),
              let buildOne = SemanticVersion("1.0.0+build.1"),
              let buildTwo = SemanticVersion("1.0.0+build.2") else {
            throw VerificationError("合法 SemVer（语义版本）无法解析")
        }
        try expect(rc2 < rc10 && rc10 < stable && stable < nextPatch, "预发布版本比较顺序错误")
        try expect(buildOne == buildTwo, "SemVer build metadata（构建元数据）错误影响版本优先级")
        try expect(
            SemanticVersion.extract(from: "DeepSeek Harness dsh v0.1.1-rc.2\n") == rc2,
            "无法从 dsh --version 输出提取版本"
        )
        try expect(
            SemanticVersion.extract(from: "DeepSeek Harness dsh 0.1.1oops\n") == nil,
            "版本提取错误接受了尾随字符"
        )
        try expect(
            DSHUpdateService.parseNPMViewLatestOutput(#""0.1.1-rc.2""#) == rc2,
            "无法解析 npm latest 的 JSON 字符串输出"
        )
        try expect(
            DSHUpdateService.parseNPMViewLatestOutput("[\n  \"0.1.1-rc.2\"\n]") == rc2,
            "无法解析 npm 12 的单元素 JSON 数组输出"
        )
        try expect(
            DSHUpdateService.parseNPMViewLatestOutput(#"["0.1.1-rc.2", "0.1.1"]"#) == nil,
            "错误接受了含多个 latest 版本的歧义 JSON 数组"
        )
        try expect(SemanticVersion("01.0.0") == nil, "接受了带前导零的非法 SemVer")

        let dummyDSH = URL(fileURLWithPath: "/opt/example/lib/node_modules/@deepseek-ai/dsh/lib/bin.js")
        let dummyNPM = URL(fileURLWithPath: "/opt/example/bin/npm")
        let dummyRoot = URL(fileURLWithPath: "/opt/example/lib/node_modules", isDirectory: true)
        try expect(
            DSHUpdateCheck(
                dshExecutable: dummyDSH,
                npmExecutable: dummyNPM,
                npmGlobalRoot: dummyRoot,
                currentVersion: rc2,
                latestVersion: rc10
            ).disposition == .updateAvailable,
            "旧版本没有判定为可更新"
        )
        try expect(
            DSHUpdateCheck(
                dshExecutable: dummyDSH,
                npmExecutable: dummyNPM,
                npmGlobalRoot: dummyRoot,
                currentVersion: stable,
                latestVersion: rc10
            ).disposition == .newerThanLatest,
            "较新版本错误触发降级"
        )
        try expect(
            DSHUpdateService.path(
                dummyDSH,
                isInside: dummyRoot
                    .appendingPathComponent("@deepseek-ai", isDirectory: true)
                    .appendingPathComponent("dsh", isDirectory: true)
            ),
            "全局 npm 包内的 dsh 没有通过来源边界"
        )
        try expect(
            !DSHUpdateService.path(
                URL(fileURLWithPath: "/opt/example/lib/node_modules/@deepseek-ai/dsh-evil/lib/bin.js"),
                isInside: dummyRoot
                    .appendingPathComponent("@deepseek-ai", isDirectory: true)
                    .appendingPathComponent("dsh", isDirectory: true)
            ),
            "相似路径前缀错误通过全局 npm 来源边界"
        )
        try expect(
            DSHUpdateService.updateArguments == [
                "install", "--global", "@deepseek-ai/dsh@latest", "--no-audit", "--no-fund",
            ],
            "更新命令不是固定的 @deepseek-ai/dsh@latest 参数数组"
        )

        let commandOutput = try await OneShotCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["0.1.1-rc.2\n"],
            timeout: 5,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp", "TMPDIR": "/tmp"],
            homeDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )
        try expect(commandOutput.succeeded, "受控单次命令执行失败")
        try expect(commandOutput.stdout == "0.1.1-rc.2", "单次命令没有分离并保留 stdout")
    }

    static func verifyAppUpdateFoundation() throws {
        guard let currentVersion = SemanticVersion("0.0.1") else {
            throw VerificationError("无法构造 App 当前版本 fixture")
        }
        let releaseURL = URL(
            string: "https://github.com/hellokitty-23/dsd-pancake/releases/tag/v0.0.2"
        )!
        let check = try AppUpdateService.parseLatestReleaseURL(
            releaseURL,
            currentVersion: currentVersion,
            currentBuild: "36"
        )
        try expect(check.disposition == .updateAvailable, "较新的 App Release 未判定为可选更新")
        try expect(check.latestVersion == SemanticVersion("0.0.2"), "App Release tag 版本解析错误")
        try expect(
            check.releasePageURL.absoluteString
                == "https://github.com/hellokitty-23/dsd-pancake/releases/tag/v0.0.2",
            "App Release 页面地址解析错误"
        )
        try expect(
            check.downloadURL?.absoluteString
                == "https://github.com/hellokitty-23/dsd-pancake/releases/download/v0.0.2/DSD-Pancake-v0.0.2-arm64.dmg",
            "App 更新检查没有生成受约束的 arm64 DMG 下载地址"
        )
        try expect(
            check.checksumURL?.absoluteString
                == "https://github.com/hellokitty-23/dsd-pancake/releases/download/v0.0.2/DSD-Pancake-v0.0.2-arm64.dmg.sha256",
            "App 更新检查没有生成与 DMG 对应的 SHA-256 校验地址"
        )

        let sameVersion = AppUpdateCheck(
            currentVersion: currentVersion,
            currentBuild: "36",
            latestVersion: currentVersion,
            releasePageURL: check.releasePageURL,
            downloadURL: check.downloadURL,
            checksumURL: check.checksumURL
        )
        try expect(sameVersion.disposition == .upToDate, "相同 App 版本未判定为最新")

        do {
            _ = try AppUpdateService.parseLatestReleaseURL(
                URL(string: "https://example.com/hellokitty-23/dsd-pancake/releases/tag/v0.0.2")!,
                currentVersion: currentVersion,
                currentBuild: "36"
            )
            throw VerificationError("非 GitHub 项目地址错误通过 App 更新来源边界")
        } catch let error as AppUpdateError {
            guard case .untrustedReleaseURL = error else {
                throw VerificationError("非 GitHub 项目地址返回了错误类型：\(error)")
            }
        }

        do {
            _ = try AppUpdateService.parseLatestReleaseURL(
                URL(
                    string: "https://github.com/hellokitty-23/dsd-pancake/releases/tag/v0.0.2-rc.1"
                )!,
                currentVersion: currentVersion,
                currentBuild: "36"
            )
            throw VerificationError("预发布 App Release 错误进入正式更新通道")
        } catch let error as AppUpdateError {
            guard error == .unstableRelease else {
                throw VerificationError("预发布 App Release 返回了错误类型：\(error)")
            }
        }
    }

    static func verifyAutomaticUpdateAndDownloadFoundation() async throws {
        guard let current = SemanticVersion("0.0.1"),
              let latest = SemanticVersion("0.0.2") else {
            throw VerificationError("无法构造自动更新检查版本 fixture")
        }

        try verifyAppDownloadFlow(current: current, latest: latest)

        let origin = Date(timeIntervalSince1970: 1_000_000)
        let schedule = AutomaticUpdateCheckSchedule.hourly
        try expect(
            schedule.dueSources(lastAppCheckAt: nil, lastDSHCheckAt: nil, now: origin) == [.app, .dsh],
            "首次启动没有同时检查 App 和 DSH"
        )
        try expect(
            schedule.dueSources(
                lastAppCheckAt: origin,
                lastDSHCheckAt: origin,
                now: origin.addingTimeInterval(59 * 60)
            ).isEmpty,
            "未满一小时错误触发自动检查"
        )
        try expect(
            schedule.dueSources(
                lastAppCheckAt: origin,
                lastDSHCheckAt: origin,
                now: origin.addingTimeInterval(60 * 60)
            ) == [.app, .dsh],
            "恰满一小时没有触发独立自动检查"
        )
        try expect(
            schedule.dueSources(
                lastAppCheckAt: origin.addingTimeInterval(60 * 60),
                lastDSHCheckAt: origin,
                now: origin.addingTimeInterval(60 * 60)
            ) == [.dsh],
            "手动刷新 App 后错误重复检查 App，或遗漏到期 DSH"
        )
        try expect(
            schedule.nextCheckAt(
                lastAppCheckAt: origin.addingTimeInterval(-2 * 60 * 60),
                lastDSHCheckAt: origin.addingTimeInterval(-3 * 60 * 60),
                now: origin
            ) == origin,
            "睡眠恢复后下一次检查不应补跑多个历史时点"
        )

        let cachedApp = CachedAppUpdate(latestVersion: latest)
        try expect(cachedApp.applies(to: current), "较新的 App 缓存没有恢复为提示")
        try expect(!cachedApp.applies(to: latest), "相同 App 版本错误保留旧提示")

        let cachedDSH = CachedDSHUpdate(
            executablePath: "/opt/homebrew/bin/dsh",
            currentVersion: current,
            latestVersion: latest
        )
        try expect(
            cachedDSH.applies(to: "/opt/homebrew/bin/dsh", currentVersion: current),
            "同一路径和版本的 DSH 缓存没有恢复"
        )
        try expect(
            !cachedDSH.applies(to: "/usr/local/bin/dsh", currentVersion: current)
                && !cachedDSH.applies(to: "/opt/homebrew/bin/dsh", currentVersion: latest),
            "路径或当前版本变化后仍错误保留 DSH 缓存"
        )

        var cacheState = AutomaticUpdateCheckState(dshUpdate: cachedDSH)
        let manualCheckAt = origin.addingTimeInterval(123)
        cacheState.apply(
            appResult: .available(cachedApp),
            dshResult: .failed,
            checkedAt: manualCheckAt
        )
        try expect(
            cacheState.lastAppCheckAt == manualCheckAt
                && cacheState.lastDSHCheckAt == manualCheckAt
                && cacheState.appUpdate == cachedApp
                && cacheState.dshUpdate == cachedDSH,
            "App 成功与 DSH 失败没有独立刷新时间并保留既有缓存"
        )
        try expect(
            cacheState.availableUpdateCount == 2
                && UpdateIndicatorPresentation.label(forAvailableUpdateCount: 2) == "发现 2 项可选更新"
                && UpdateIndicatorPresentation.label(forAvailableUpdateCount: 1) == "发现 1 项可选更新"
                && UpdateIndicatorPresentation.label(forAvailableUpdateCount: 0) == nil
                && UpdateIndicatorPresentation.isVisible(forAvailableUpdateCount: 1)
                && !UpdateIndicatorPresentation.isVisible(forAvailableUpdateCount: 0),
            "标题栏更新图标没有严格跟随可选更新状态"
        )

        let standardUpdateLayout = UpdateOverlayLayout.resolve(
            totalWidth: 1_280,
            sidebarWidth: 320
        )
        let resizedSidebarLayout = UpdateOverlayLayout.resolve(
            totalWidth: 1_280,
            sidebarWidth: 420
        )
        let narrowUpdateLayout = UpdateOverlayLayout.resolve(
            totalWidth: 600,
            sidebarWidth: 368
        )
        try expect(
            standardUpdateLayout.indicatorCenterX == 360
                && standardUpdateLayout.surfaceOriginX == 336
                && standardUpdateLayout.arrowX == 24
                && standardUpdateLayout.arrowPointsToIndicator,
            "更新图标与浮层没有锚定在主内容区左边距"
        )
        try expect(
            resizedSidebarLayout.indicatorCenterX - standardUpdateLayout.indicatorCenterX == 100
                && resizedSidebarLayout.surfaceOriginX - standardUpdateLayout.surfaceOriginX == 100,
            "侧栏宽度变化后更新入口与浮层没有同步移动"
        )
        try expect(
            narrowUpdateLayout.usesCompactActions
                && narrowUpdateLayout.surfaceOriginX >= narrowUpdateLayout.mainLeading
                && narrowUpdateLayout.surfaceOriginX + narrowUpdateLayout.surfaceWidth <= 600,
            "窄窗口下更新浮层越过侧栏或右侧窗口边界"
        )

        let laterCheckAt = manualCheckAt.addingTimeInterval(1)
        cacheState.apply(
            appResult: .current,
            dshResult: .available(cachedDSH),
            checkedAt: laterCheckAt
        )
        try expect(
            cacheState.lastAppCheckAt == laterCheckAt
                && cacheState.lastDSHCheckAt == laterCheckAt
                && cacheState.appUpdate == nil
                && cacheState.dshUpdate == cachedDSH,
            "手动检查后的 current / available 独立归约不正确"
        )

        cacheState.invalidateDSHUpdate(
            executablePath: "/usr/local/bin/dsh",
            currentVersion: current
        )
        try expect(cacheState.dshUpdate == nil, "DSH 路径变化后没有失效旧更新缓存")
        cacheState = AutomaticUpdateCheckState(appUpdate: cachedApp)
        cacheState.invalidateAppUpdate(for: latest)
        try expect(cacheState.appUpdate == nil, "App 版本追平后没有失效旧更新缓存")

        guard let cachedCheck = AppUpdateService.cachedCheck(
            currentVersion: current.rawValue,
            currentBuild: "36",
            latestVersion: latest.rawValue
        ) else {
            throw VerificationError("App 缓存无法恢复固定 Release 地址")
        }
        try expect(
            cachedCheck.disposition == .updateAvailable
                && cachedCheck.downloadURL?.lastPathComponent == "DSD-Pancake-v0.0.2-arm64.dmg"
                && cachedCheck.checksumURL?.lastPathComponent == "DSD-Pancake-v0.0.2-arm64.dmg.sha256",
            "App 缓存没有以固定 Release 文件名恢复可选更新"
        )
        let fixedURLs = try AppReleaseDownloadService.fixedReleaseURLs(for: cachedCheck)
        try expect(
            fixedURLs.0 == cachedCheck.downloadURL && fixedURLs.1 == cachedCheck.checksumURL,
            "安全下载没有接受由固定 Release tag 推导出的地址"
        )

        let forgedAssetCheck = AppUpdateCheck(
            currentVersion: current,
            currentBuild: "36",
            latestVersion: latest,
            releasePageURL: cachedCheck.releasePageURL,
            downloadURL: URL(string: "https://objects.githubusercontent.com/forged.dmg")!,
            checksumURL: URL(string: "https://objects.githubusercontent.com/forged.dmg.sha256")!
        )
        do {
            _ = try AppReleaseDownloadService.fixedReleaseURLs(for: forgedAssetCheck)
            throw VerificationError("下载器错误接受了非固定 GitHub 初始地址")
        } catch let error as AppReleaseDownloadError {
            try expect(
                error == .untrustedRedirect("https://objects.githubusercontent.com/forged.dmg"),
                "伪造 Release 资产地址返回了错误类型：\(error)"
            )
        }

        guard let initialURL = cachedCheck.downloadURL else {
            throw VerificationError("缺少固定 DMG 初始地址")
        }
        try expect(
            AppUpdateService.isTrustedReleaseAssetRedirect(initialURL, expectedInitialURL: initialURL),
            "固定 GitHub 初始地址错误被拒绝"
        )
        try expect(
            AppUpdateService.isTrustedReleaseAssetRedirect(
                URL(string: "https://objects.githubusercontent.com/github-production-release-asset/example")!,
                expectedInitialURL: initialURL
            ),
            "GitHub 受控 Release 资产主机错误被拒绝"
        )
        try expect(
            !AppUpdateService.isTrustedReleaseAssetRedirect(
                URL(string: "https://github.com/hellokitty-23/dsd-pancake/releases/download/v0.0.2/other.dmg")!,
                expectedInitialURL: initialURL
            )
                && !AppUpdateService.isTrustedReleaseAssetRedirect(
                    URL(string: "https://downloads.example.com/DSD-Pancake-v0.0.2-arm64.dmg")!,
                    expectedInitialURL: initialURL
                ),
            "非固定 GitHub 初始地址或任意下载主机错误通过信任边界"
        )

        let filename = "DSD-Pancake-v0.0.2-arm64.dmg"
        let expectedHash = String(repeating: "a", count: 64)
        let validSidecar = Data("\(expectedHash)  \(filename)\n".utf8)
        try expect(
            try AppReleaseDownloadService.parseSHA256Sidecar(
                validSidecar,
                expectedFilename: filename
            ) == expectedHash,
            "严格 SHA-256 sidecar 无法解析"
        )
        for invalidSidecar in [
            Data("\(expectedHash)  other.dmg\n".utf8),
            Data("\(expectedHash)  \(filename)\n\n".utf8),
            Data("not-a-hash  \(filename)\n".utf8),
        ] {
            do {
                _ = try AppReleaseDownloadService.parseSHA256Sidecar(
                    invalidSidecar,
                    expectedFilename: filename
                )
                throw VerificationError("错误接受了格式或文件名不可信的 SHA-256 sidecar")
            } catch let error as AppReleaseDownloadError {
                try expect(error == .invalidChecksumFile, "损坏 sidecar 返回了错误类型：\(error)")
            }
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "dsd-pancake-update-download-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let existingFile = directory.appendingPathComponent(filename)
        try Data("old".utf8).write(to: existingFile, options: .withoutOverwriting)
        let uniqueDestination = try AppReleaseDownloadService.uniqueDestinationURL(
            in: directory,
            filename: filename
        )
        try expect(
            uniqueDestination.lastPathComponent == "DSD-Pancake-v0.0.2-arm64 (1).dmg"
                && fileManager.fileExists(atPath: existingFile.path),
            "下载目标没有保留同名既有文件并生成无覆盖名称"
        )

        let digestFixture = directory.appendingPathComponent("digest-fixture")
        try Data("abc".utf8).write(to: digestFixture, options: .withoutOverwriting)
        try expect(
            try AppReleaseDownloadService.sha256(of: digestFixture)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "下载文件的 SHA-256 计算错误"
        )

        let cancelledDownload = AppReleaseDownloadCancellation()
        cancelledDownload.cancel()
        try expect(cancelledDownload.isCancelled, "下载取消令牌没有保存已取消状态")
        do {
            _ = try AppReleaseDownloadService.sha256(
                of: digestFixture,
                cancellation: cancelledDownload
            )
            throw VerificationError("已取消下载仍继续计算文件哈希")
        } catch is CancellationError {
            // 取消后不读取或保留本次临时文件，是下载器的基础边界。
        }

        let releaseFixtureDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "dsd-pancake-release-download-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: releaseFixtureDirectory, withIntermediateDirectories: true)
        defer {
            ReleaseAssetURLProtocol.reset()
            try? fileManager.removeItem(at: releaseFixtureDirectory)
        }

        let fixtureDownloader = AppReleaseDownloadService(
            makeSessionConfiguration: { requestTimeout, resourceTimeout in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil
                configuration.timeoutIntervalForRequest = requestTimeout
                configuration.timeoutIntervalForResource = resourceTimeout
                configuration.protocolClasses = [ReleaseAssetURLProtocol.self]
                return configuration
            }
        )
        let fixtureDMG = Data("fixture-dmg-payload".utf8)
        let fixtureDigestURL = releaseFixtureDirectory.appendingPathComponent("expected-digest")
        try fixtureDMG.write(to: fixtureDigestURL, options: .withoutOverwriting)
        let fixtureDigest = try AppReleaseDownloadService.sha256(of: fixtureDigestURL)
        try fileManager.removeItem(at: fixtureDigestURL)
        let fixtureSidecar = Data("\(fixtureDigest)  \(filename)\n".utf8)

        ReleaseAssetURLProtocol.install { request in
            let isChecksum = request.url?.lastPathComponent.hasSuffix(".sha256") == true
            let body = isChecksum ? fixtureSidecar : fixtureDMG
            return ReleaseAssetURLProtocol.Fixture(
                status: 200,
                headers: [
                    "Content-Type": isChecksum ? "text/plain" : "application/x-apple-diskimage",
                    "Content-Length": "\(body.count)",
                ],
                body: body
            )
        }
        let preflightDigest = try await fixtureDownloader.verifyChecksum(for: cachedCheck)
        try expect(
            preflightDigest == fixtureDigest,
            "更新浮层下载预验证没有接受有效 checksum sidecar"
        )
        let currentReleaseCheck = AppUpdateCheck(
            currentVersion: latest,
            currentBuild: "37",
            latestVersion: latest,
            releasePageURL: cachedCheck.releasePageURL,
            downloadURL: cachedCheck.downloadURL,
            checksumURL: cachedCheck.checksumURL
        )
        do {
            _ = try await fixtureDownloader.verifyChecksum(for: currentReleaseCheck)
            throw VerificationError("当前已是最新版本时仍进入内置下载预验证")
        } catch let error as AppReleaseDownloadError {
            try expect(error == .updateNotAvailable, "非可选更新预验证返回了错误类型：\(error)")
        }
        let existingDownload = releaseFixtureDirectory.appendingPathComponent(filename)
        try Data("user-file".utf8).write(to: existingDownload, options: .withoutOverwriting)
        let downloaded = try await fixtureDownloader.download(
            check: cachedCheck,
            downloadsDirectory: releaseFixtureDirectory
        )
        let preservedUserFile = try Data(contentsOf: existingDownload)
        let downloadedDMG = try Data(contentsOf: downloaded.fileURL)
        let successfulDownloadEntries = try fileManager.contentsOfDirectory(
            at: releaseFixtureDirectory,
            includingPropertiesForKeys: nil
        )
        try expect(
            downloaded.fileURL.lastPathComponent == "DSD-Pancake-v0.0.2-arm64 (1).dmg"
                && preservedUserFile == Data("user-file".utf8)
                && downloadedDMG == fixtureDMG
                && successfulDownloadEntries.allSatisfy { !$0.lastPathComponent.hasSuffix(".part") },
            "受控下载没有保留同名用户文件、验证内容或清理 .part 临时文件"
        )
        try expect(
            fixtureDownloader.downloadedFileIsAvailable(downloaded),
            "刚完成且仍存在的普通 DMG 被错误判为不可用"
        )
        try expect(
            await fixtureDownloader.downloadedFileMatchesChecksum(downloaded),
            "刚完成且内容未变化的 DMG 重新校验失败"
        )
        try Data("same-path-tampered-dmg".utf8).write(to: downloaded.fileURL, options: .atomic)
        try expect(
            fixtureDownloader.downloadedFileIsAvailable(downloaded),
            "同路径被替换后的普通文件应保持“存在”，以覆盖仅检查路径的回归场景"
        )
        try expect(
            !(await fixtureDownloader.downloadedFileMatchesChecksum(downloaded)),
            "同路径内容被篡改后仍错误通过下载文件 SHA-256 复检"
        )
        try fileManager.removeItem(at: downloaded.fileURL)
        try expect(
            !fixtureDownloader.downloadedFileIsAvailable(downloaded),
            "用户删除 DMG 后仍错误保留已下载状态"
        )

        let mismatchDirectory = releaseFixtureDirectory.appendingPathComponent("mismatch", isDirectory: true)
        try fileManager.createDirectory(at: mismatchDirectory, withIntermediateDirectories: true)
        ReleaseAssetURLProtocol.install { request in
            let isChecksum = request.url?.lastPathComponent.hasSuffix(".sha256") == true
            let body = isChecksum ? fixtureSidecar : Data("tampered-dmg".utf8)
            return ReleaseAssetURLProtocol.Fixture(
                status: 200,
                headers: ["Content-Length": "\(body.count)"],
                body: body
            )
        }
        do {
            _ = try await fixtureDownloader.download(
                check: cachedCheck,
                downloadsDirectory: mismatchDirectory
            )
            throw VerificationError("哈希不匹配的 DMG 错误完成下载")
        } catch let error as AppReleaseDownloadError {
            guard case .checksumMismatch = error else {
                throw VerificationError("哈希不匹配返回了错误类型：\(error)")
            }
        }
        let mismatchEntries = try fileManager.contentsOfDirectory(
            at: mismatchDirectory,
            includingPropertiesForKeys: nil
        )
        try expect(
            mismatchEntries.isEmpty,
            "哈希不匹配后残留了最终文件或 .part 临时文件"
        )

        let missingChecksumDirectory = releaseFixtureDirectory.appendingPathComponent(
            "missing-checksum",
            isDirectory: true
        )
        try fileManager.createDirectory(at: missingChecksumDirectory, withIntermediateDirectories: true)
        ReleaseAssetURLProtocol.install { request in
            let isChecksum = request.url?.lastPathComponent.hasSuffix(".sha256") == true
            return ReleaseAssetURLProtocol.Fixture(
                status: isChecksum ? 404 : 500,
                headers: ["Content-Length": "0"],
                body: Data()
            )
        }
        do {
            _ = try await fixtureDownloader.download(
                check: cachedCheck,
                downloadsDirectory: missingChecksumDirectory
            )
            throw VerificationError("缺少 checksum sidecar 时错误开始了内置下载")
        } catch let error as AppReleaseDownloadError {
            try expect(
                error == .checksumUnavailable(statusCode: 404),
                "缺少 checksum sidecar 返回了错误类型：\(error)"
            )
        }
        let missingChecksumEntries = try fileManager.contentsOfDirectory(
            at: missingChecksumDirectory,
            includingPropertiesForKeys: nil
        )
        try expect(
            missingChecksumEntries.isEmpty,
            "缺少 checksum sidecar 时仍写入了下载文件"
        )

        let cancelledDirectory = releaseFixtureDirectory.appendingPathComponent(
            "cancelled-before-start",
            isDirectory: true
        )
        try fileManager.createDirectory(at: cancelledDirectory, withIntermediateDirectories: true)
        let cancellationBeforeStart = AppReleaseDownloadCancellation()
        cancellationBeforeStart.cancel()
        do {
            _ = try await fixtureDownloader.download(
                check: cachedCheck,
                downloadsDirectory: cancelledDirectory,
                cancellation: cancellationBeforeStart
            )
            throw VerificationError("已取消下载仍开始了网络或文件写入")
        } catch is CancellationError {
            // 预期：开始前取消不会创建 .part 或最终文件。
        }
        let cancelledEntries = try fileManager.contentsOfDirectory(
            at: cancelledDirectory,
            includingPropertiesForKeys: nil
        )
        try expect(cancelledEntries.isEmpty, "取消下载后残留了临时或最终文件")

        let inFlightCancellationDirectory = releaseFixtureDirectory.appendingPathComponent(
            "cancelled-in-flight",
            isDirectory: true
        )
        try fileManager.createDirectory(at: inFlightCancellationDirectory, withIntermediateDirectories: true)
        let requestRecorder = ReleaseAssetRequestRecorder()
        ReleaseAssetURLProtocol.install { request in
            requestRecorder.record(request)
            let isChecksum = request.url?.lastPathComponent.hasSuffix(".sha256") == true
            let body = isChecksum ? fixtureSidecar : fixtureDMG
            return ReleaseAssetURLProtocol.Fixture(
                status: 200,
                headers: ["Content-Length": "\(body.count)"],
                body: body,
                delay: isChecksum ? 0 : 0.5
            )
        }
        let inFlightCancellation = AppReleaseDownloadCancellation()
        let inFlightTask = Task {
            try await fixtureDownloader.download(
                check: cachedCheck,
                downloadsDirectory: inFlightCancellationDirectory,
                cancellation: inFlightCancellation
            )
        }
        var dmGRequestStarted = false
        for _ in 0 ..< 100 {
            if requestRecorder.containsPath(suffix: "/\(filename)") {
                dmGRequestStarted = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(dmGRequestStarted, "受控下载没有在取消测试前进入 DMG 请求阶段")
        inFlightCancellation.cancel()
        do {
            _ = try await inFlightTask.value
            throw VerificationError("下载进行中取消后仍返回了成功结果")
        } catch is CancellationError {
            // 预期：取消会终止 URLSession 任务，并由下载器清理本次 .part 文件。
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        let inFlightEntries = try fileManager.contentsOfDirectory(
            at: inFlightCancellationDirectory,
            includingPropertiesForKeys: nil
        )
        try expect(inFlightEntries.isEmpty, "下载进行中取消后残留了 .part 或最终文件")
    }

    /// 纯 flow（状态流）验证不启动网络或文件 IO，专门证明旧 operation token
    /// （操作令牌）不能覆盖新 Release，且下载文件失效后会回到可下载状态。
    static func verifyAppDownloadFlow(
        current: SemanticVersion,
        latest: SemanticVersion
    ) throws {
        guard let next = SemanticVersion("0.0.3"),
              let firstCheck = AppUpdateService.cachedCheck(
                currentVersion: current.rawValue,
                currentBuild: "36",
                latestVersion: latest.rawValue
              ),
              let nextCheck = AppUpdateService.cachedCheck(
                currentVersion: current.rawValue,
                currentBuild: "36",
                latestVersion: next.rawValue
              ) else {
            throw VerificationError("无法构造 AppDownloadFlow Release fixture")
        }

        var flow = AppDownloadFlow()
        try expect(flow.send(.latestCheckChanged(firstCheck)).isEmpty, "首次 Release 写入产生了意外 IO")
        let firstPrepare = flow.send(.prepareRequested(firstCheck))
        guard case let .verifyChecksum(firstToken, preparedCheck)? = firstPrepare.first,
              preparedCheck == firstCheck else {
            throw VerificationError("下载状态流没有产生 checksum 预验证 effect")
        }
        try expect(flow.state == .verifyingChecksum, "checksum 预验证没有进入对应状态")

        let replacementEffects = flow.send(.latestCheckChanged(nextCheck))
        try expect(
            replacementEffects == [.cancel(firstToken)] && flow.state == .idle,
            "Release 切换没有取消旧操作并归零状态"
        )
        try expect(
            flow.send(.checksumVerified(firstToken)).isEmpty && flow.state == .idle,
            "旧 checksum 结果错误覆盖了新 Release 状态"
        )

        let nextPrepare = flow.send(.prepareRequested(nextCheck))
        guard case let .verifyChecksum(nextChecksumToken, preparedNextCheck)? = nextPrepare.first,
              preparedNextCheck == nextCheck else {
            throw VerificationError("新 Release 没有产生 checksum 预验证 effect")
        }
        _ = flow.send(.checksumVerified(nextChecksumToken))
        try expect(flow.state == .readyToDownload, "checksum 通过后没有进入可下载状态")

        let staleDownloadEffects = flow.send(.downloadRequested(nextCheck))
        guard case let .download(staleDownloadToken, downloadedCheck)? = staleDownloadEffects.first,
              downloadedCheck == nextCheck else {
            throw VerificationError("用户下载动作没有产生下载 effect")
        }
        _ = flow.send(.downloadProgress(staleDownloadToken, 0.5))
        try expect(flow.state == .downloading(0.5), "下载进度没有按当前 token 更新")

        let result = AppReleaseDownloadResult(
            fileURL: URL(fileURLWithPath: "/tmp/DSD-Pancake-v0.0.3-arm64.dmg"),
            sha256: String(repeating: "a", count: 64)
        )

        let downloadReleaseChange = flow.send(.latestCheckChanged(firstCheck))
        try expect(
            downloadReleaseChange == [.cancel(staleDownloadToken)] && flow.state == .idle,
            "下载进行中切换 Release 没有取消精确 token 并归零状态"
        )
        try expect(
            flow.send(.downloadProgress(staleDownloadToken, 0.9)).isEmpty
                && flow.state == .idle,
            "旧 Release 的迟到下载进度错误覆盖了新状态"
        )
        try expect(
            flow.send(.downloadCompleted(staleDownloadToken, result)).isEmpty
                && flow.state == .idle,
            "旧 Release 的迟到下载完成结果错误覆盖了新状态"
        )

        _ = flow.send(.latestCheckChanged(nextCheck))
        let resumedPrepare = flow.send(.prepareRequested(nextCheck))
        guard case let .verifyChecksum(resumedChecksumToken, resumedCheck)? = resumedPrepare.first,
              resumedCheck == nextCheck else {
            throw VerificationError("下载竞态验证后无法重新预验证 checksum")
        }
        _ = flow.send(.checksumVerified(resumedChecksumToken))
        let resumedDownload = flow.send(.downloadRequested(nextCheck))
        guard case let .download(resumedDownloadToken, resumedDownloadCheck)? = resumedDownload.first,
              resumedDownloadCheck == nextCheck else {
            throw VerificationError("下载竞态验证后无法重新开始下载")
        }
        _ = flow.send(.downloadCompleted(resumedDownloadToken, result))
        try expect(flow.state == .completed(result), "当前下载完成结果没有进入 completed")

        let cancelledValidation = flow.send(.validationRequested(result))
        guard case let .validateDownloadedFile(cancelledValidationToken, validationResult)? =
            cancelledValidation.first,
            validationResult == result else {
            throw VerificationError("下载完成结果没有进入文件复检")
        }
        let validationCancellation = flow.send(.cancelValidationRequested(
            result,
            isAvailable: true
        ))
        try expect(
            validationCancellation == [.cancel(cancelledValidationToken)]
                && flow.state == .completed(result),
            "取消文件复检没有撤销精确 token 或恢复已完成状态"
        )
        try expect(
            flow.send(.validationCompleted(
                cancelledValidationToken,
                result,
                isValid: false
            )).isEmpty && flow.state == .completed(result),
            "已取消文件复检的迟到结果错误覆盖了 completed 状态"
        )

        let replacedValidation = flow.send(.validationRequested(result))
        guard case let .validateDownloadedFile(replacedValidationToken, _)? =
            replacedValidation.first else {
            throw VerificationError("Release 切换验证前没有启动文件复检")
        }
        let validationReleaseChange = flow.send(.latestCheckChanged(firstCheck))
        try expect(
            validationReleaseChange == [.cancel(replacedValidationToken)]
                && flow.state == .idle,
            "文件复检中切换 Release 没有取消精确 token 并归零状态"
        )
        try expect(
            flow.send(.validationCompleted(
                replacedValidationToken,
                result,
                isValid: true
            )).isEmpty && flow.state == .idle,
            "旧 Release 的迟到文件复检结果错误恢复了旧下载"
        )

        _ = flow.send(.latestCheckChanged(nextCheck))
        let validationPrepare = flow.send(.prepareRequested(nextCheck))
        guard case let .verifyChecksum(validationChecksumToken, _)? = validationPrepare.first else {
            throw VerificationError("文件复检失败场景无法重新预验证 checksum")
        }
        _ = flow.send(.checksumVerified(validationChecksumToken))
        let validationDownload = flow.send(.downloadRequested(nextCheck))
        guard case let .download(validationDownloadToken, _)? = validationDownload.first else {
            throw VerificationError("文件复检失败场景无法重新开始下载")
        }
        _ = flow.send(.downloadCompleted(validationDownloadToken, result))
        let invalidValidation = flow.send(.validationRequested(result))
        guard case let .validateDownloadedFile(invalidValidationToken, _)? = invalidValidation.first else {
            throw VerificationError("无效文件场景没有进入文件复检")
        }
        _ = flow.send(.validationCompleted(
            invalidValidationToken,
            result,
            isValid: false
        ))
        try expect(
            flow.state == .readyToDownload,
            "文件完整校验失败后没有回到可重新下载状态"
        )

        let availabilityDownload = flow.send(.downloadRequested(nextCheck))
        guard case let .download(availabilityDownloadToken, _)? = availabilityDownload.first else {
            throw VerificationError("文件可用性验证前无法重新下载")
        }
        _ = flow.send(.downloadCompleted(availabilityDownloadToken, result))
        _ = flow.send(.completedFileAvailabilityChanged(result, isAvailable: false))
        try expect(flow.state == .readyToDownload, "已下载文件被删除后没有退回重新下载")

        let redownloadEffects = flow.send(.downloadRequested(nextCheck))
        guard case let .download(redownloadToken, _)? = redownloadEffects.first else {
            throw VerificationError("文件失效后不能重新开始下载")
        }
        let cancelEffects = flow.send(.cancelTransferRequested)
        try expect(
            cancelEffects == [.cancel(redownloadToken)] && flow.state == .idle,
            "取消当前下载没有撤销精确 token 或恢复 idle"
        )
    }

}
