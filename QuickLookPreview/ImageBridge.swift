import Foundation

/// 让沙箱里的扩展拿到图片字节：走非沙箱的 `LinkOpener.xpc` 代读。
///
/// 为什么非要绕这一圈：Quick Look **只**把「被预览的那个文件」的读权限授给扩展，
/// 同目录的兄弟文件也读不到（2026-11-24 实测：三张同目录图片一次都没读出来，
/// 渲染只花了 0.56 ms）。把图挪到 README 同级也不行 —— 权限粒度是文件，不是目录。
///
/// 为什么不干脆让 XPC 把整篇 HTML 渲染好：那要把 `MarkdownKit` 与 `SharedTheme` 的
/// CSS 资源再塞进 XPC bundle，多一份渲染口径就多一处会分叉的地方。这里只搬字节，
/// 渲染全局只有一条路径。
enum ImageBridge {

    /// 回执最多等这么久。本地 IPC 正常在几毫秒内到，给到 0.7 s 已经很宽松。
    private static let timeout: DispatchTimeInterval = .milliseconds(700)

    /// 进程内熔断：超时过一次就不再指望这个服务。
    ///
    /// 没有熔断的话，服务起不来时每次预览都要白等满一个超时——那比"没有图"糟得多。
    private static let state = BrokenFlag()

    private final class BrokenFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var broken = false

        var isBroken: Bool {
            lock.lock(); defer { lock.unlock() }
            return broken
        }

        func markBroken() {
            lock.lock(); defer { lock.unlock() }
            broken = true
        }
    }

    /// 回执在私有队列上到达，用引用类型接住，避免跨线程改动局部变量。
    private final class ReplyBox: @unchecked Sendable {
        var images: [String: Data] = [:]
        let done = DispatchSemaphore(value: 0)
    }

    /// 同步取图。调用点必须在后台队列上（`PreviewDocument.load` 就在）。
    static func fetch(_ paths: [URL], under root: URL, via service: LinkOpenerProtocol?) -> [URL: Data] {
        guard let service, !paths.isEmpty, !state.isBroken else { return [:] }

        let started = DispatchTime.now().uptimeNanoseconds
        let box = ReplyBox()
        service.readImages(paths.map(\.path), under: root.path) { images in
            box.images = images
            box.done.signal()
        }

        guard box.done.wait(timeout: .now() + timeout) == .success else {
            state.markBroken()
            PreviewDiagnostics.logger.error("images_bridge_timeout requested=\(paths.count)")
            return [:]
        }

        var result: [URL: Data] = [:]
        var bytes = 0
        for (path, data) in box.images {
            result[URL(fileURLWithPath: path).standardizedFileURL] = data
            bytes += data.count
        }
        let elapsed = PreviewDiagnostics.milliseconds(
            from: started, to: PreviewDiagnostics.now()
        )
        PreviewDiagnostics.logger.notice("""
        images_bridged requested=\(paths.count) got=\(result.count) \
        bytes=\(bytes) ms=\(PreviewDiagnostics.formatted(elapsed), privacy: .public)
        """)
        return result
    }
}
