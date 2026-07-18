import Foundation
import LocalAuthentication

enum BiometricAuthError: LocalizedError {
    case notAvailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "此设备未启用面容 ID / 触控 ID 或设备密码"
        case .failed(let message):
            return message
        }
    }
}

/// Face ID / Touch ID / 设备密码门禁。
enum BiometricAuth {
    /// 用于按钮文案，如「使用面容 ID 解锁」。
    static var biometryDisplayName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID: return "面容 ID"
        case .touchID: return "触控 ID"
        case .opticID: return "Optic ID"
        default: return "设备密码"
        }
    }

    static var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// 解锁后才能查看 / 修改 API Key。允许 Face ID，失败时可退回设备密码。
    static func authenticateToUnlockAPIKey() async throws {
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw BiometricAuthError.notAvailable
        }
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "验证身份后才能查看或修改 API Key"
            )
            guard ok else {
                throw BiometricAuthError.failed("验证未通过")
            }
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                throw BiometricAuthError.failed("已取消验证")
            default:
                throw BiometricAuthError.failed(laError.localizedDescription)
            }
        }
    }
}
