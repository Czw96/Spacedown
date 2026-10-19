import Foundation

/// 扩展与 `LinkOpener.xpc` 之间**唯一**的接口。这个文件同时编译进两个 target。
///
/// ## 为什么非要有这个服务
///
/// 沙箱里的 app 扩展**不能**打开外部链接。这不是"可能被拒"，是**必死** ——
/// 实测（同一段代码，只差 `app-sandbox` 一个权限）：
///
/// | | `NSWorkspace.shared.open(url)` |
/// |---|---|
/// | 不沙箱 | 返回 `true`，浏览器打开 |
/// | **沙箱** | **进程被 SIGTRAP 杀掉（退出码 133）** |
///
/// 也就是说：在沙箱扩展里点一下链接，崩的是扩展自己。所以"打开链接"这件事必须
/// 交给一个**不在沙箱里**的独立进程 —— 就是本协议另一端的 `LinkOpener.xpc`。
///
/// 同架构的两个开源实现都这么做：showmd 叫 `LinkOpener`，QLMarkdown 叫 `external-launcher`。
@objc public protocol LinkOpenerProtocol {

    /// 把 URL 交给系统打开。
    ///
    /// - Parameter reply: 是否成功。**刻意用回传值而不是抛错**：调用方（预览扩展）
    ///   拿到 `false` 只记一笔日志就好，没有任何可恢复动作 —— 不值得为它引入错误路径。
    func open(_ url: URL, withReply reply: @escaping (Bool) -> Void)

    /// 只回一个 `true`，用来确认**连接本身是通的**。
    ///
    /// 为什么不直接用 `open` 自检：那会真的弹出浏览器。诊断"链接点不开到底是
    /// XPC 没连上、还是服务打不开"时必须能分开这两件事，所以留一个无副作用的探针。
    func ping(withReply reply: @escaping (Bool) -> Void)
}
