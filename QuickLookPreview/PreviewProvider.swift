import Foundation
import QuickLookUI
import UniformTypeIdentifiers

import MarkdownKit
import SharedTheme

/// 数据型 Quick Look 预览扩展。
///
/// 与「视图型（`QLPreviewingController` 自建 `WKWebView`）」的区别：这里不创建 webview，
/// 只把渲染好的 HTML 交给系统去排版显示。省掉的是 WebContent 进程 spawn —— 实测它是
/// 冷启动耗时的 80%（约 300ms，见 docs/benchmarks.md M0 表）。
///
/// `NSExtensionAttributes.QLIsDataBasedPreview = true` 必须同步在 Info.plist 里打开，
/// 否则系统会去找 `preparePreviewOfFile(at:)` 而忽略本方法。
@objc(QuickLookPreviewProvider)
final class QuickLookPreviewProvider: QLPreviewProvider, QLPreviewingController {

    private static let renderer = MarkdownRenderer()

    /// 计时埋点。QL 预览跑在一个转瞬即逝的独立进程里，挂不了调试器；
    /// `log show` 又常被沙箱挡住，所以直接写文件，简单粗暴但一定拿得到。
    private enum TimingLog {
        static let paths: [String] = [
            NSHomeDirectory() + "/Library/Logs/Spacedown/timing.log",
            "/tmp/spacedown-timing.log",
        ]

        static func append(_ line: String) {
            let payload = Data((line + "\n").utf8)
            for path in paths {
                try? FileManager.default.createDirectory(
                    atPath: (path as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: path) {
                    if let h = FileHandle(forWritingAtPath: path) {
                        h.seekToEndOfFile()
                        h.write(payload)
                        try? h.synchronize()
                        h.closeFile()
                    }
                } else {
                    try? payload.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    /// 超过这个体积就截断。
    ///
    /// 天花板不是解析（约 25 MB/s）而是 WebKit 排版（约 236 ms/MB HTML），
    /// 所以「大文件先截断」是唯一有效的缓解手段 —— 见 docs/技术方案.md §3。
    private static let maxBytes = 512 * 1024

    func providePreview(
        for request: QLFilePreviewRequest,
        completionHandler: @escaping (QLPreviewReply?, Error?) -> Void
    ) {
        let url = request.fileURL

        // 重活放进 dataCreationBlock：文档明确要求这样，系统才能在出结果前先显示 loading UI。
        //
        // 注意 Swift 侧的签名：ObjC 里这个 block 是 `(NSData *(^)(QLPreviewReply*, NSError**))`，
        // 但导入成 Swift 后 `NSError**` 被吃掉了，变成 `(QLPreviewReply) throws -> Data`。
        // 失败要 `throw`，不是给 errorPointer 赋值（照头文件写会编不过）。
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: .zero) { [url] _ in
            let t0 = Self.now()
            var data = try Data(contentsOf: url, options: .mappedIfSafe)
            let t1 = Self.now()
            if data.count > Self.maxBytes {
                data = Self.truncated(data, limit: Self.maxBytes)
            }
            let body = Self.renderer.renderHTMLData(data)
            let t2 = Self.now()
            let doc = SharedTheme.document(body: body)
            let t3 = Self.now()

            Self.TimingLog.append(
                "pid=\(getpid()) file=\(url.lastPathComponent) "
                + "bytes=\(data.count) html=\(doc.count) "
                + "read=\(Self.ms(t0, t1))ms render=\(Self.ms(t1, t2))ms "
                + "wrap=\(Self.ms(t2, t3))ms total=\(Self.ms(t0, t3))ms"
            )
            return doc
        }
        reply.title = url.lastPathComponent
        completionHandler(reply, nil)
    }

    private static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func ms(_ a: UInt64, _ b: UInt64) -> String {
        String(format: "%.2f", Double(b - a) / 1_000_000)
    }

    /// 尽量切在换行上，避免把一个 markdown 块结构切成半截。
    private static func truncated(_ data: Data, limit: Int) -> Data {
        var slice = data.prefix(limit)
        if let newline = slice.lastIndex(of: 0x0A) {
            slice = slice[..<newline]
        }
        var out = Data("\n\n> 文件过大，已截断显示前 \(limit / 1024) KB\n".utf8)
        out.append(slice)
        return out
    }
}
