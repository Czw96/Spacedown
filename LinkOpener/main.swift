import AppKit
import Foundation

/// 替沙箱里的扩展做三件被禁止的事：打开外部链接、用主 App 打开本地文件、代读图片。
///
/// ## ⚠️ 它**刻意不带** `app-sandbox`
///
/// 它的存在意义就是"替沙箱里的扩展做那件被沙箱禁止的事"。加了沙箱等于自废武功
/// （见 `LinkOpenerProtocol` 里那张实测表）。
///
/// ## 能力面收到最小
///
/// - `open` 只放行 `http` / `https` / `mailto`，其余 scheme 一律拒绝；
/// - `openInSpacedown` 只接 `file:`，且只把文件交给同一个 bundle 里的主 App；
/// - `readImages` 只读 `root` 目录内、图片扩展名、单张 ≤ 2 MB 的普通文件。
///
/// 三个口子都不接受"任意 URL 交给系统默认处理器"或"读任意路径"，塞进来也走不出去。
final class LinkOpenerService: NSObject, LinkOpenerProtocol {

    private static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    /// 与 `ImageInliner` 的白名单保持一致 —— 那边认不出的扩展名，这里读出来也没用。
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "avif", "heic", "bmp", "tif", "tiff", "ico", "svg",
    ]
    private static let maxBytesPerImage = 2 * 1024 * 1024
    private static let maxBytesTotal = 20 * 1024 * 1024

    /// 从自身 bundle 往上找到装着这个 XPC 服务的 `.app`。
    ///
    /// ⚠️ 不能改用 `withAppBundleIdentifier:`：开发机上 DerivedData 与 /Applications
    /// 常同时存在两份 Spacedown，LaunchServices 按 bundle ID 找可能启动旧副本，
    /// 表现成"点了按钮却打开了一个没有这份改动的版本"——QL 扩展上已经踩过这类串台。
    private static var hostAppURL: URL? {
        // ⚠️ 这个 XPC 服务嵌在 **QL 扩展内部**，不是主 App 的 Contents/XPCServices：
        // Spacedown.app/Contents/PlugIns/QuickLookPreview.appex/Contents/XPCServices/LinkOpener.xpc
        // 往上要走 6 层才到 .app（中途会经过 .appex，它的 pathExtension 不是 "app"，
        // 不会误命中）。留 10 层余量，别把循环上限定在刚好够用的位置。
        var candidate = Bundle.main.bundleURL
        for _ in 0..<10 {
            candidate = candidate.deletingLastPathComponent()
            if candidate.pathExtension.lowercased() == "app" { return candidate }
        }
        return nil
    }

    func open(_ url: URL, withReply reply: @escaping (Bool) -> Void) {
        guard let scheme = url.scheme?.lowercased(),
              Self.allowedSchemes.contains(scheme) else {
            reply(false)
            return
        }
        reply(NSWorkspace.shared.open(url))
    }

    func openInSpacedown(_ url: URL, withReply reply: @escaping @Sendable (Bool) -> Void) {
        guard url.isFileURL, let app = Self.hostAppURL else {
            reply(false)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url],
                                withApplicationAt: app,
                                configuration: configuration) { _, error in
            reply(error == nil)
        }
    }

    /// 无副作用的连通性探针（见协议里的说明）。
    func ping(withReply reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    /// 代读图片。校验全部在服务侧做，调用方给什么路径都不相信。
    ///
    /// 解符号链接再比前缀，是为了挡 `sub/../../../etc/x.png` 和"目录内一个指向外部的符号
    /// 链接"这两条路。`root` 自己也解一次，否则 `/tmp/x` 与 `/private/tmp/x` 会被判成
    /// 不同目录（macOS 上 `/tmp` 就是个链接）。
    func readImages(_ paths: [String], under root: String,
                    withReply reply: @escaping ([String: Data]) -> Void) {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        var result: [String: Data] = [:]
        var used = 0

        for path in paths {
            guard used < Self.maxBytesTotal else { break }
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(rootPrefix) else { continue }
            guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size <= Self.maxBytesPerImage,
                  size <= Self.maxBytesTotal - used else { continue }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            used += data.count
            // key 用请求原字符串：调用方按自己的写法回查，不必猜我们标准化成了什么
            result[path] = data
        }
        reply(result)
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: LinkOpenerProtocol.self)
        connection.exportedObject = LinkOpenerService()
        connection.resume()
        return true
    }
}

// XPC 服务的标准入口：`NSXPCListener.service()` 之后不用自己跑 run loop，
// 监听端口会把它撑住，消息由 XPC 的队列驱动。
let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
