import Foundation

/// 读取待渲染的 Markdown。
///
/// 两端口径**故意不同**：
/// - 主 App 是「坐下来读」，走 `full(contentsOf:)` 全量加载；
/// - 空格预览是「扫一眼」，走 `previewBytes(_:)` 只渲染前 64 KB；
///   要看全文就点提示条里的按钮，把文件交给主 App（见 `OpenInAppInteraction`）。
///
/// 截断只有这一份实现。上限针对的不是解析（cmark 吞吐很高），而是之后的
/// WebKit 排版 —— 排版成本随 HTML 体积线性增长（实测 ≈0.22 ms/KB HTML）。
public enum MarkdownDocument {

    /// 空格预览的首屏上限。
    ///
    /// 实测（WebViewBench，五轮中位数）：64 KB md → 97 KB HTML → nav2 **26.3 ms**，
    /// 相对原 512 KB 的 155.5 ms 省 83%。再往下压到 32 KB 只多省 9 ms，却砍掉一半内容；
    /// 往上到 128 KB 要多付 18 ms，换来的内容深度对「按空格扫一眼」没有意义。
    /// 64 KB 约合 80 屏正文（版心 16px/1.72、面板 700px 高），远超一次预览的滚动深度。
    public static let previewMaxBytes = 64 * 1024

    /// 读全文。`mappedIfSafe` 下大文件不占物理内存，只有真正被渲染的部分才会被 touch。
    public static func full(contentsOf url: URL) throws -> Data {
        try Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// 从全文切出预览片段。**唯一一份截断实现**。
    ///
    /// 切在最后一个换行，避免把表格、代码块切成半截。返回是否发生截断 ——
    /// 调用方据此决定要不要挂「在 Spacedown 中打开全文」入口。
    public static func previewBytes(
        _ full: Data,
        maxBytes: Int = previewMaxBytes
    ) -> (rendered: Data, truncated: Bool) {
        guard full.count > maxBytes else { return (full, false) }

        var body = full.prefix(maxBytes)
        if let lastNewline = body.lastIndex(of: 0x0A) {
            body = body[..<lastNewline]
        }

        // 裸 HTML 按钮靠 cmark 的 CMARK_OPT_UNSAFE 保留；点击事件由原生注入的
        // WKUserScript 委托处理（CSP 没有 script-src，内联 onclick 会被挡）。
        // 用 class 而不是 data-*：DangerousURLFilter 的属性扫描表里含 `data`。
        var rendered = Data("""

        > 文件较大，已先显示前 \(maxBytes / 1024) KB。<button type="button" class="sd-open-in-app">在 Spacedown 中打开全文</button>

        """.utf8)
        rendered.append(body)
        return (rendered, true)
    }
}
