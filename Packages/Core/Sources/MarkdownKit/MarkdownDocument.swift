import Foundation
import CcmarkGfm

/// 读取待渲染的 Markdown。
///
/// 两端口径**故意不同**：
/// - 主 App 是「坐下来读」，走 `full(contentsOf:)` 全量加载；
/// - 空格预览是「扫一眼」，走 `previewBytes(_:)` 只渲染前 64 KB；
///   要看全文就点片段末尾的按钮，把文件交给主 App（见 `OpenInAppInteraction`）。
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
    /// 切点是「不超过上限的最后一个**完整顶层块**」，不是第 `maxBytes` 个字节。
    /// 按字节硬切（哪怕回退到最后一个换行）会把表格、围栏代码块、引用或列表
    /// 拦腰截断：渲染出来就是缺行的表格、没闭合的代码块，看起来像内容丢了。
    /// 这里用 cmark AST 的 `end_line` 找块边界，块结构由解析器判定，不手写规则。
    ///
    /// 提示放在**正文末尾**而不是开头：用户滚到底才需要「还有下文」这个信息，
    /// 顶部横条只会把第一屏往下推。文案不解释原因，只留一个动作。
    public static func previewBytes(
        _ full: Data,
        maxBytes: Int = previewMaxBytes
    ) -> (rendered: Data, truncated: Bool) {
        guard full.count > maxBytes else { return (full, false) }

        let cut = blockBoundary(in: full, maxBytes: maxBytes)
        var rendered = Data(full.prefix(cut))

        // 裸 HTML 靠 CMARK_OPT_UNSAFE 保留；点击由原生注入的 WKUserScript 委托处理
        //（CSP 没有 script-src，内联 onclick 会被挡）。用 class 而不是 data-*：
        // DangerousURLFilter 的属性扫描表里含 `data`。
        rendered.append(Data("""

        <div class="sd-more"><button type="button" class="sd-open-in-app">加载更多</button></div>

        """.utf8))
        return (rendered, true)
    }

    /// 找不超过 `maxBytes` 的最后一个完整顶层块的结束偏移（块后第一个字节）。
    ///
    /// 解析全文只为拿块边界：cmark 解析成本远低于 WebKit 排版，且 mapped Data
    /// 只在这一步被 touch。行号 → 字节偏移的映射只建到上限，超出上限的块
    /// 直接停 —— 后面的块只会更远。
    private static func blockBoundary(in data: Data, maxBytes: Int) -> Int {
        var lineStarts: [Int] = [0]
        for (index, byte) in data.prefix(maxBytes).enumerated() where byte == 0x0A {
            lineStarts.append(index + 1)
        }

        guard let parser = cmark_parser_new(MarkdownRenderer.renderOptions) else {
            return lineFallback(lineStarts: lineStarts, maxBytes: maxBytes)
        }
        defer { cmark_parser_free(parser) }

        // 扩展必须和渲染时一致，否则表格会被当成普通段落，边界判错。
        cmark_gfm_core_extensions_ensure_registered()
        for name in MarkdownRenderer.gfmExtensions {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            cmark_parser_feed(parser, base.assumingMemoryBound(to: CChar.self), raw.count)
        }
        guard let document = cmark_parser_finish(parser) else {
            return lineFallback(lineStarts: lineStarts, maxBytes: maxBytes)
        }
        defer { cmark_node_free(document) }

        var cut = 0
        var node = cmark_node_first_child(document)
        while let current = node {
            let endLine = Int(cmark_node_get_end_line(current))
            // 少数节点没有 sourcepos（end_line == 0）；跳过它，别因此停住。
            guard endLine >= 1 else {
                node = cmark_node_next(current)
                continue
            }
            // `endLine` 是 1-based；lineStarts[endLine] 即该块之后下一行的起点。
            // endLine >= lineStarts.count 说明块结束已越过上限，后面不必再看。
            guard endLine < lineStarts.count else { break }
            cut = lineStarts[endLine]
            node = cmark_node_next(current)
        }

        // 第一个块就超过上限（一整段无空行的超长文本）：退回按行切，
        // 至少保证 UTF-8 与当前行完整，不把渲染输入截成半个字符。
        return cut > 0 ? cut : lineFallback(lineStarts: lineStarts, maxBytes: maxBytes)
    }

    private static func lineFallback(lineStarts: [Int], maxBytes: Int) -> Int {
        guard let last = lineStarts.last, last > 0 else { return maxBytes }
        return last
    }
}
