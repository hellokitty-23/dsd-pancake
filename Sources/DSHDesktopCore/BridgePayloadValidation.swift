import Foundation

/// 两个 App 私有 WebKit bridge 共用的纯负载校验规则。它不定义业务字段或权限，
/// 只确保桥接版本与匿名标识符在进入各自协议前具有同一安全边界。
enum BridgePayloadValidation {
    static func integer(_ value: Any?) -> Int? {
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

    static func isOpaqueIdentifier(_ value: String) -> Bool {
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
