import AppKit
import Foundation

/// 替沙箱里的扩展做两件被禁止的事：打开外部链接、用主 App 打开本地文件。
///
/// ## ⚠️ 它**刻意不带** `app-sandbox`
///
/// 它的存在意义就是"替沙箱里的扩展做那件被沙箱禁止的事"。加了沙箱等于自废武功
/// （见 `LinkOpenerProtocol` 里那张实测表）。
///
/// ## 能力面收到最小
///
/// - `open` 只放行 `http` / `https` / `mailto`，其余 scheme 一律拒绝；
/// - `openInSpacedown` 只接 `file:`，且只把文件交给同一个 bundle 里的主 App。
///
/// 两个口子都不接受"任意 URL 交给系统默认处理器"，塞进来也走不出去。
final class LinkOpenerService: NSObject, LinkOpenerProtocol {

    private static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

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
