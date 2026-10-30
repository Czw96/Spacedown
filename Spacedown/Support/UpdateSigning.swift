import Foundation
import CryptoKit

/// 更新包的真实性校验。
///
/// 本 App 没有 Developer ID，Apple 不会为更新包背书，所以"这个包确实是我们发的"
/// 这件事只能自己承担：发布时用 Ed25519 私钥签 zip，App 里用烘焙进来的公钥验签。
/// 这等价于 Sparkle 的 EdDSA 机制（同一套 ed25519），区别只是没有 appcast。
///
/// ⚠️ 只校 sha256 是不够的：那个值同样由 GitHub 计算并下发，账号被盗就一起被换掉。
enum UpdateSigning {

    /// 公钥（base64，32 字节原始表示）。私钥在 `~/.spacedown-signing/update-signing.key`。
    ///
    /// 换密钥要谨慎：老版本里烘焙的是旧公钥，新签名它们验不过 —— 只能让用户手动下载一次。
    static let publicKeyBase64 = "fJRttPU7pl7dEvjU5J3bzMDg04oXXYBWXH9+RznbdJQ="

    enum Failure: LocalizedError {
        case brokenPublicKey
        case brokenSignature
        case mismatched

        var errorDescription: String? {
            switch self {
            case .brokenPublicKey: return "内置公钥无法解析（打包问题）"
            case .brokenSignature: return "签名文件格式不对"
            case .mismatched: return "更新包验签失败，可能被替换过"
            }
        }
    }

    /// 验签：`signatureBase64` 是 `.sig` 资产的内容。
    static func verify(fileURL: URL, signatureBase64: String) throws {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw Failure.brokenPublicKey
        }
        let trimmed = signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: trimmed) else { throw Failure.brokenSignature }

        let payload = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard key.isValidSignature(signature, for: payload) else { throw Failure.mismatched }
    }
}
