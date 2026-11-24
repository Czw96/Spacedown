import Foundation

import MarkdownKit
import SharedTheme

/// 一次预览的渲染产物与分段耗时。
struct PreviewDocument {

    let html: Data
    /// 是否只渲染了前一段（诊断用）。
    let truncated: Bool
    let readMs: Double
    let renderMs: Double
    let wrapMs: Double

    /// 取图片字节的钩子：`(图片绝对路径, 文档所在目录) -> 已读到的字节`。
    ///
    /// 主 App 不传（它能直接读磁盘）；Quick Look 扩展传 `ImageBridge.fetch`，
    /// 因为沙箱不给兄弟文件的读权限。
    typealias ImageProvider = ([URL], URL) -> [URL: Data]

    /// 没有共享可变状态，可以在后台队列上调用。
    private static let renderer = MarkdownRenderer()

    /// 读文件 → 按完整块截前 64 KB → 解析 → 拼完整 HTML。
    ///
    /// 预览**永远只出这一段**。要看全文是主 App 的事：片段末尾的「加载更多」
    /// 按钮把文件交给 `LinkOpener.xpc`，不在扩展里做全量渲染 —— QL 扩展的内存
    /// 限额与看门狗都比主 App 紧，几百 KB 的全量排版很容易把内容进程拖死。
    ///
    /// ⚠️ 读文件必须待在安全作用域里；**图片则完全读不到** —— Quick Look 只把「这一个
    /// 文件」的权限授出来，同目录的兄弟文件也不行（2026-11-24 实测）。图片字节由
    /// `imageProvider` 从非沙箱的 XPC 服务取，见 `ImageBridge`。
    static func load(at url: URL, images: ImageProvider? = nil) throws -> PreviewDocument {
        let directory = url.deletingLastPathComponent()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let readStarted = PreviewDiagnostics.now()
        let full = try MarkdownDocument.full(contentsOf: url)
        let readFinished = PreviewDiagnostics.now()

        let (markdown, truncated) = MarkdownDocument.previewBytes(full)
        let body = renderer.renderHTMLData(markdown)
        let renderFinished = PreviewDiagnostics.now()

        // 图片先由 XPC 代读；一篇没有图的文档不会发这次 IPC。
        var preloaded: [URL: Data] = [:]
        if let images {
            let wanted = ImageInliner.imagePaths(in: body, baseDirectory: directory)
            if !wanted.isEmpty { preloaded = images(wanted, directory) }
        }
        let html = SharedTheme.document(body: body, baseDirectory: directory,
                                        imageData: preloaded)
        let wrapFinished = PreviewDiagnostics.now()

        return PreviewDocument(
            html: html,
            truncated: truncated,
            readMs: PreviewDiagnostics.milliseconds(from: readStarted, to: readFinished),
            renderMs: PreviewDiagnostics.milliseconds(from: readFinished, to: renderFinished),
            wrapMs: PreviewDiagnostics.milliseconds(from: renderFinished, to: wrapFinished)
        )
    }
}
