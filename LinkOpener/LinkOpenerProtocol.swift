import Foundation

/// `LinkOpener.xpc` 的服务名。XPC 两端都用它，写一次免得对不上。
public enum LinkOpenerEndpoint {
    public static let serviceName = "cn.29dev.Spacedown.LinkOpener"
}

/// 扩展与 `LinkOpener.xpc` 之间唯一的接口。这个文件同时编译进两个 target。
///
/// 为什么非要有这个服务：沙箱里的扩展**不能**打开外部链接 ——
/// `NSWorkspace.shared.open` 在不沙箱时正常返回，加上 `app-sandbox` 之后
/// 会让进程被 SIGTRAP 杀掉。所以"打开链接"必须交给一个不在沙箱里的独立进程。
@objc public protocol LinkOpenerProtocol {

    /// 把 URL 交给系统打开。
    ///
    /// - Parameter reply: 是否成功。刻意用回传值而不是抛错：调用方拿到 `false`
    ///   只记一笔日志，没有任何可恢复动作。
    func open(_ url: URL, withReply reply: @escaping (Bool) -> Void)

    /// 只回一个 `true`，用来确认连接本身是通的。
    ///
    /// 不用 `open` 自检是因为那会真的弹出浏览器；诊断"链接点不开"时必须能区分
    /// XPC 没连上还是服务侧打不开。
    func ping(withReply reply: @escaping (Bool) -> Void)
}
