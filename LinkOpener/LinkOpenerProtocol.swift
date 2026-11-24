import Foundation

/// `LinkOpener.xpc` 的服务名。XPC 两端都用它，写一次免得对不上。
public enum LinkOpenerEndpoint {
    public static let serviceName = "cn.29dev.Spacedown.LinkOpener"
}

/// 扩展与 `LinkOpener.xpc` 之间唯一的接口。这个文件同时编译进两个 target。
///
/// 为什么非要有这个服务：沙箱里的扩展**不能**打开链接、也不能启动 App ——
/// `NSWorkspace.shared.open` 在不沙箱时正常返回，加上 `app-sandbox` 之后
/// 会让进程被 SIGTRAP 杀掉。所以这类动作必须交给一个不在沙箱里的独立进程。
@objc public protocol LinkOpenerProtocol {

    /// 把 URL 交给系统打开。
    ///
    /// - Parameter reply: 是否成功。刻意用回传值而不是抛错：调用方拿到 `false`
    ///   只记一笔日志，没有任何可恢复动作。
    func open(_ url: URL, withReply reply: @escaping (Bool) -> Void)

    /// 用 Spacedown 主 App 打开一个本地文件（预览页「打开全文」按钮的动作）。
    ///
    /// 服务侧只接 `file:` URL，且明确指定用**装着这个 XPC 服务的那个 .app** 打开，
    /// 不交给系统默认处理器 —— 默认处理器可能是别的 Markdown 编辑器。
    func openInSpacedown(_ url: URL, withReply reply: @escaping @Sendable (Bool) -> Void)

    /// 只回一个 `true`，用来确认连接本身是通的。
    ///
    /// 不用 `open` 自检是因为那会真的弹出浏览器；诊断"链接点不开"时必须能区分
    /// XPC 没连上还是服务侧打不开。
    func ping(withReply reply: @escaping (Bool) -> Void)

    /// 代读一批本地图片，供渲染时内联成 base64。
    ///
    /// 为什么需要它：Quick Look **只**把「被预览的那个文件」的读权限授给扩展，
    /// 同目录的兄弟文件也读不到（2026-11-24 实测：三张同目录图片一次都没读出来，
    /// `wrap` 只花了 0.56 ms）。所以图片字节只能由这个不在沙箱里的服务代读。
    ///
    /// 能力面收得很紧，任何一条不满足就不出现在回执里：
    /// - 必须落在 `root` 目录**之内**（先解符号链接再判断前缀，防 `..` 与链接逃逸）；
    /// - 必须是普通文件，扩展名在图片白名单内；
    /// - 单张 ≤ 2 MB、一次总量 ≤ 20 MB（与渲染侧 `ImageInliner` 的上限一致）。
    ///
    /// 回执的 key 是**请求时传进来的那个字符串**，调用方可以直接对回原路径。
    func readImages(_ paths: [String], under root: String,
                    withReply reply: @escaping ([String: Data]) -> Void)
}
