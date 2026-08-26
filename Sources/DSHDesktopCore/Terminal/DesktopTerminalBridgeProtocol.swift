import Foundation

/// DSD Pancake 底部终端的最小 WebKit bridge（通信桥）协议。
///
/// 它只允许页面同步一个经过 DSH 正式 session service（会话服务）取得的工作区，
/// 或明确当前没有可用工作区；显示状态只由原生壳控制。它绝不接受 shell command
/// （命令）、脚本、环境变量或进程参数。
public enum DesktopTerminalBridge {
    public static let messageName = "dsdPancakeTerminal"
    public static let protocolVersion = 1

    /// 严格解析 JSON 形消息。每个 action 都要求精确字段集，防止将来在未审查时扩大
    /// 页面到原生层的权限边界。
    public static func decode(_ body: Any) -> DesktopTerminalBridgeAction? {
        guard let dictionary = body as? [String: Any],
              integer(dictionary["version"]) == protocolVersion,
              let action = dictionary["action"] as? String else {
            return nil
        }

        switch action {
        case "capabilities":
            guard Set(dictionary.keys) == ["version", "action"] else { return nil }
            return .capabilities

        case "syncWorkspace":
            guard Set(dictionary.keys) == ["version", "action", "sessionID", "workspacePath"],
                  let sessionID = dictionary["sessionID"] as? String,
                  let workspacePath = dictionary["workspacePath"] as? String,
                  let request = DesktopTerminalWorkspaceRequest(
                      sessionID: sessionID,
                      workspacePath: workspacePath
                  ) else {
                return nil
            }
            return .syncWorkspace(request)

        case "clearWorkspace":
            guard Set(dictionary.keys) == ["version", "action"] else { return nil }
            return .clearWorkspace

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

/// WebKit handler 进入原生终端控制器前的唯一准入门（admission gate）。把 bridge
/// 开关、主 frame 和固定 loopback origin 一起放在 Core，避免 UI target 因重构而漏掉
/// 某一项检查。它只返回已经通过严格 payload 解析的 action，失败时一律 no-op。
public enum DesktopTerminalBridgeAdmission {
    public static func decode(
        _ body: Any,
        bridgeEnabled: Bool,
        isMainFrame: Bool,
        originScheme: String,
        originHost: String,
        originPort: Int
    ) -> DesktopTerminalBridgeAction? {
        guard bridgeEnabled,
              isMainFrame,
              originScheme == LocalService.url.scheme,
              originHost == LocalService.host,
              originPort == LocalService.port else {
            return nil
        }
        return DesktopTerminalBridge.decode(body)
    }
}

public enum DesktopTerminalBridgeAction: Equatable, Sendable {
    case capabilities
    case syncWorkspace(DesktopTerminalWorkspaceRequest)
    case clearWorkspace
}

/// 尚未触及文件系统的工作区请求。协议解析只接受绝对、无控制字符的路径；原生层
/// 仍必须通过 `DesktopTerminalWorkspace` 再次确认该路径当前是实际目录。
public struct DesktopTerminalWorkspaceRequest: Equatable, Sendable {
    public let sessionID: String
    public let workspacePath: String

    public init?(sessionID: String, workspacePath: String) {
        guard Self.isOpaqueSessionID(sessionID), Self.isSafeAbsolutePath(workspacePath) else {
            return nil
        }
        self.sessionID = sessionID
        self.workspacePath = workspacePath
    }

    private static func isOpaqueSessionID(_ value: String) -> Bool {
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

    private static func isSafeAbsolutePath(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty,
              bytes.count <= 4_096,
              value.hasPrefix("/") else {
            return false
        }
        return bytes.allSatisfy { byte in
            // POSIX path 可以包含非 ASCII 文件名，但 NUL、换行和其他控制字符不能
            // 安全地作为 bridge 负载的一部分传递。
            byte >= 32 && byte != 127
        }
    }
}

/// 已经由原生层验证为可进入的工作区目录。只用规范化路径作为身份，保证不同 DSH
/// session 指向同一 workspace 时可复用同一个 PTY。
public struct DesktopTerminalWorkspace: Hashable, Sendable {
    public let path: String

    public init?(
        request: DesktopTerminalWorkspaceRequest,
        fileManager: FileManager = .default
    ) {
        var isDirectory: ObjCBool = false
        let normalized = URL(fileURLWithPath: request.workspacePath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard fileManager.fileExists(atPath: normalized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        path = normalized.path
    }
}

public enum DesktopTerminalBridgeResponse {
    /// 响应只包含 capability（能力）和可见状态；不把 workspace 路径、shell 输出或
    /// 其它本机信息反向暴露给网页。
    public static func payload(supported: Bool, isOpen: Bool, workspaceAccepted: Bool = true) -> [String: Any] {
        [
            "version": DesktopTerminalBridge.protocolVersion,
            "supported": supported,
            "open": isOpen,
            "workspaceAccepted": workspaceAccepted,
        ]
    }
}

/// 将“私有 patch 已准备”与“服务归属已验证”同时作为终端 capability 的前置条件。
/// 任一条件缺失（特别是 external DSH）都必须保持 bridge 关闭。
public enum DesktopTerminalBridgePolicy {
    public static func mayEnable(
        serviceOwnership: ServiceOwnership,
        terminalPatchPrepared: Bool
    ) -> Bool {
        serviceOwnership == .owned && terminalPatchPrepared
    }
}
