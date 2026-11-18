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

    /// 没有共享可变状态，可以在后台队列上调用。
    private static let renderer = MarkdownRenderer()

    /// 读文件 → 截前 64 KB → 解析 → 拼完整 HTML。
    ///
    /// 预览**永远只出这一段**。要看全文是主 App 的事：提示条里的按钮把文件交给
    /// `LinkOpener.xpc`，不在扩展里做全量渲染 —— QL 扩展的内存限额与看门狗
    /// 都比主 App 紧，几百 KB 的全量排版很容易把内容进程拖死。
    ///
    /// ⚠️ 读文件与 `SharedTheme.document` 的图片内联都必须待在同一个安全作用域里：
    /// 图片是同目录的相对路径，光把全文 Data 留内存并不能绕开文件访问权。
    static func load(at url: URL) throws -> PreviewDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let readStarted = PreviewDiagnostics.now()
        let full = try MarkdownDocument.full(contentsOf: url)
        let readFinished = PreviewDiagnostics.now()

        let (markdown, truncated) = MarkdownDocument.previewBytes(full)
        let body = renderer.renderHTMLData(markdown)
        let renderFinished = PreviewDiagnostics.now()

        let html = SharedTheme.document(body: body, baseDirectory: url.deletingLastPathComponent())
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
