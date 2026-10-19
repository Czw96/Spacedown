import Foundation

import MarkdownKit
import SharedTheme

/// 一次预览的渲染产物与分段耗时。
struct PreviewDocument {

    let html: Data
    let readMs: Double
    let renderMs: Double
    let wrapMs: Double

    /// 没有共享可变状态，可以在后台队列上调用。
    private static let renderer = MarkdownRenderer()

    /// 读文件 → 截断 → 解析 → 拼完整 HTML，与主 App 走同一条链路。
    ///
    /// 截断必须走 `MarkdownDocument`：主 App 与扩展的截断口径必须一致，
    /// 否则同一个文件在两处显示的长度会不一样。
    static func load(at url: URL) throws -> PreviewDocument {
        // 沙箱里必须显式开安全作用域：Quick Look 给的 URL 是 security-scoped 的，
        // 不 start 的话读取会直接失败。非沙箱运行时返回 false，但读取照常。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let readStarted = PreviewDiagnostics.now()
        let markdown = try MarkdownDocument.bytes(contentsOf: url)
        let readFinished = PreviewDiagnostics.now()

        let body = renderer.renderHTMLData(markdown)
        let renderFinished = PreviewDiagnostics.now()

        let html = SharedTheme.document(body: body)
        let wrapFinished = PreviewDiagnostics.now()

        return PreviewDocument(
            html: html,
            readMs: PreviewDiagnostics.milliseconds(from: readStarted, to: readFinished),
            renderMs: PreviewDiagnostics.milliseconds(from: readFinished, to: renderFinished),
            wrapMs: PreviewDiagnostics.milliseconds(from: renderFinished, to: wrapFinished)
        )
    }
}
