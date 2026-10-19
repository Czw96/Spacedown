import AppKit
import Foundation

/// 只做一件事的 XPC 服务：把 URL 交给系统打开。
///
/// ## ⚠️ 它**刻意不带** `app-sandbox`
///
/// 它的存在意义就是"替沙箱里的扩展做那件被沙箱禁止的事"。加了沙箱等于自废武功
/// （见 `LinkOpenerProtocol` 里那张实测表）。
///
/// ## 能力面收到最小
///
/// 只放行 `http` / `https` / `mailto`，其余 scheme 一律拒绝。这样即便将来有人想办法
/// 从这个口子塞进别的 scheme（`file:`、自定义 scheme 之类），也打不开。
/// 一个"打开链接"的服务就该只会打开链接。
final class LinkOpenerService: NSObject, LinkOpenerProtocol {

    private static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    func open(_ url: URL, withReply reply: @escaping (Bool) -> Void) {
        guard let scheme = url.scheme?.lowercased(),
              Self.allowedSchemes.contains(scheme) else {
            reply(false)
            return
        }
        reply(NSWorkspace.shared.open(url))
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
