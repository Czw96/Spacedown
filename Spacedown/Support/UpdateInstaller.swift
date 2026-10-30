import AppKit
import CryptoKit

/// 应用内自更新：下载 → 验签 → 解压 → 换包 → 重启。
///
/// 为什么自己做而不是用 Sparkle：本工程不引 SwiftPM 依赖（见 README §八），
/// vendor 一个预编译 framework 再加 appcast 的维护成本高于这里的几百行。
/// 安全模型上对齐 Sparkle 的核心那一环 —— 更新包必须带 Ed25519 签名（`UpdateSigning`）。
///
/// 换包本身交给一个 `sh` 脚本：App 必须先退出才能替换自己的 bundle，而脚本在
/// 父进程退出后会被 launchd 收留继续跑。脚本的设计目标是**任何一步失败都能回到旧版本**。
@MainActor
final class UpdateInstaller {

    struct Release {
        let version: String
        let page: URL
        let archive: URL
        /// 与 zip 同名的 `.sig` 资产；缺失就拒绝安装。
        let signature: URL?
        /// GitHub 给的 sha256（`digest` 字段），拿得到就再校一遍。
        let sha256: String?
    }

    /// 进度阶段。下载有真实百分比；验签与解压量不出来，用不确定态。
    enum Phase {
        case downloading(Double)
        case verifying
        case installing
    }

    enum Failure: LocalizedError {
        case notInApplications
        case missingSignature
        case downloadFailed
        case checksumMismatch
        case unzipFailed
        case unexpectedBundle
        case versionMismatch(expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .notInApplications:
                return "当前这份 App 不在「应用程序」文件夹里，无法自动替换。请先把它拖进「应用程序」，或手动下载新版本。"
            case .missingSignature:
                return "这次发布没有附带签名文件，出于安全考虑不自动安装。请手动下载。"
            case .downloadFailed:
                return "下载失败，请检查网络后重试。"
            case .checksumMismatch:
                return "更新包的校验值与发布记录不一致。"
            case .unzipFailed:
                return "更新包解压失败。"
            case .unexpectedBundle:
                return "更新包里不是 Spacedown.app。"
            case let .versionMismatch(expected, actual):
                return "更新包版本不对：期望 \(expected)，实际 \(actual)。"
            }
        }
    }

    static let shared = UpdateInstaller()
    private init() {}

    private static let logURL = URL(fileURLWithPath: "/tmp/spacedown-update.log")

    /// 下载进度观察者。必须在任务存活期间持有，否则 KVO 立刻失效。
    private var progressObservation: NSKeyValueObservation?

    /// 点「立即更新」后走这里。成功时 App 会自己退出，失败抛错由调用方提示。
    func install(_ release: Release, onPhase: @escaping @MainActor (Phase) -> Void) async throws {
        let appURL = Bundle.main.bundleURL
        guard appURL.deletingLastPathComponent().standardizedFileURL.path == "/Applications" else {
            throw Failure.notInApplications
        }
        guard let signatureURL = release.signature else { throw Failure.missingSignature }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("spacedown-update-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let archive = work.appendingPathComponent("update.zip")
        let signatureFile = work.appendingPathComponent("update.zip.sig")
        onPhase(.downloading(0))
        try await download(release.archive, to: archive) { fraction in
            onPhase(.downloading(fraction))
        }
        // 签名文件只有几十字节，不报进度
        try await download(signatureURL, to: signatureFile) { _ in }
        onPhase(.verifying)

        // 1. 签名（谁能签出这个包）—— 这是唯一不依赖 GitHub 的凭据
        let signatureText = (try? String(contentsOf: signatureFile, encoding: .utf8)) ?? ""
        try UpdateSigning.verify(fileURL: archive, signatureBase64: signatureText)

        // 2. 摘要（传输是否损坏），两道都过才解压
        if let expected = release.sha256 {
            let actual = SHA256.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else { throw Failure.checksumMismatch }
        }

        // 3. 解压
        let staged = work.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, staged.path])
        guard let newApp = try? FileManager.default.contentsOfDirectory(at: staged, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }), newApp.lastPathComponent == "Spacedown.app" else {
            throw Failure.unexpectedBundle
        }

        // 4. 新包的身份证：bundle id 必须是我们，版本必须是这次要装的
        let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
        guard (info?["CFBundleIdentifier"] as? String) == Bundle.main.bundleIdentifier else {
            throw Failure.unexpectedBundle
        }
        let stagedVersion = info?["CFBundleShortVersionString"] as? String ?? ""
        guard stagedVersion == release.version else {
            throw Failure.versionMismatch(expected: release.version, actual: stagedVersion)
        }

        // 5. 交给脚本，退出自己
        onPhase(.installing)
        try scheduleSwap(app: appURL, staged: newApp, work: work)
        append("准备换包：\(appURL.path) ← \(newApp.path)（\(release.version)）")
        NSApp.terminate(nil)
    }

    // MARK: - 下载

    private func download(_ url: URL, to destination: URL,
                          onProgress: @escaping @MainActor (Double) -> Void) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60

        let (temporary, response, error) = try await downloadTask(request, onProgress: onProgress)
        guard error == nil,
              (response as? HTTPURLResponse)?.statusCode == 200,
              let temporary else {
            throw Failure.downloadFailed
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            throw Failure.downloadFailed
        }
    }

    /// `downloadTask` 的 `Progress` 在服务器给了 `Content-Length` 时会给出真实比例，
    /// 不用自己数字节。GitHub 的 Release 资产都有长度，所以这里能出确定进度条。
    private func downloadTask(_ request: URLRequest,
                              onProgress: @escaping @MainActor (Double) -> Void)
        async throws -> (URL?, URLResponse?, Error?) {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: request) { temporary, response, error in
                continuation.resume(returning: (temporary, response, error))
            }
            progressObservation = task.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                let value = progress.fractionCompleted
                Task { @MainActor in onProgress(value) }
            }
            task.resume()
        }
    }

    // MARK: - 换包脚本

    /// 把换包脚本复制到临时目录并**脱离**本进程启动。
    ///
    /// 脚本本身是 bundle 资源（`Resources/swap.sh`）而不是写死在 Swift 里的字符串：
    /// 它是这段逻辑里最容易出错的一环，独立成文件才能单独演练回滚。
    private func scheduleSwap(app: URL, staged: URL, work: URL) throws {
        guard let bundled = Bundle.main.url(forResource: "swap", withExtension: "sh") else {
            throw Failure.unzipFailed
        }
        let scriptURL = work.appendingPathComponent("swap.sh")
        try? FileManager.default.removeItem(at: scriptURL)
        try FileManager.default.copyItem(at: bundled, to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path, app.path, staged.path, work.path, Self.logURL.path]
        // 不等待：脚本要等我们退出之后才动手
        try process.run()
    }

    // MARK: - 杂项

    private func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw Failure.unzipFailed
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.unzipFailed }
    }

    private func append(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("[\(stamp)] \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: Self.logURL)
        }
    }
}
