import Foundation
import CcmarkGfm

/// Markdown → HTML 片段。底层是 vendored cmark-gfm（静态链接）。
///
/// 入口收 `Data` 而不是 `String`：cmark 吃 UTF-8 字节，先转成 String 只会多一次
/// 全量校验与拷贝。
///
/// 本类型是线程安全的 —— cmark 没有可变的全局状态（扩展注册表在启动时一次性建好），
/// 所以可以在后台队列上渲染。
public struct MarkdownRenderer: Sendable {

    /// 启用的 GFM 扩展。
    ///
    /// `tagfilter` 不可省略：渲染开着 `CMARK_OPT_UNSAFE`，裸 HTML 会原样输出，
    /// tagfilter 是唯一会拦 `<script>` / `<style>` / `<iframe>` / `<title>` 的一层。
    public static let gfmExtensions = ["table", "strikethrough", "tasklist", "autolink", "tagfilter"]

    /// 渲染选项 —— 用 `CMARK_OPT_UNSAFE`，而不是默认的 `CMARK_OPT_DEFAULT`。
    ///
    /// 默认行为会把文档里所有裸 HTML 换成 `<!-- raw HTML omitted -->`：README 顶部的
    /// 徽章行（`<p align="center">` + `<img>`）、`<details>`、`<kbd>`、`<br>` 会整片消失。
    ///
    /// 放开裸 HTML 之后，安全边界由三层组成：
    /// 1. `tagfilter`：去掉 script / style / iframe / title 等危险标签
    /// 2. `DangerousURLFilter`：中和 `href` / `src` 里的危险 scheme
    ///    （cmark 在 unsafe 模式下不再替我们净化链接）
    /// 3. 文档外壳的 CSP `default-src 'none'`：兜住脚本与一切远程加载
    public static let renderOptions: Int32 = CMARK_OPT_UNSAFE

    /// 挂在 parser 上的扩展，进程内只查一次。
    ///
    /// `nonisolated(unsafe)`：这些指针指向 cmark 的进程级注册表，注册后不再变动、
    /// 生命周期与进程等长，只是类型系统无法证明这一点。
    nonisolated(unsafe) private static let parserExtensions: [OpaquePointer] = {
        cmark_gfm_core_extensions_ensure_registered()
        return gfmExtensions.compactMap { cmark_find_syntax_extension($0) }
    }()

    /// 渲染期的过滤扩展 —— **tagfilter 只有出现在这里才生效**。
    ///
    /// 过滤走的是 `cmark_render_html()` 的第三个参数（`renderer->filter_extensions`），
    /// 不是 parser 上挂的那些扩展；只 attach 到 parser 时裸 `<script>` 会原样输出。
    ///
    /// 进程生命周期内只建一次，故意不 free。
    nonisolated(unsafe) private static let renderFilters: UnsafeMutablePointer<cmark_llist>? = {
        guard let allocator = cmark_get_default_mem_allocator(),
              let tagfilter = cmark_find_syntax_extension("tagfilter") else { return nil }
        return cmark_llist_append(allocator, nil, UnsafeMutableRawPointer(tagfilter))
    }()

    public init() {}

    /// 把 UTF-8 编码的 Markdown 渲染成 HTML 片段。
    ///
    /// - Parameter markdown: 文档字节，不做编码探测。
    /// - Returns: 不含 `<html>`/`<head>` 的片段，外壳由 `SharedTheme.document` 负责。
    public func renderHTML(_ markdown: Data) -> String {
        String(decoding: renderHTMLData(markdown), as: UTF8.self)
    }

    /// 同 `renderHTML(_:)`，但直接返回 cmark 产出的字节。
    ///
    /// 数据型消费方（Quick Look 扩展、`SharedTheme`）只需要 `Data`；走
    /// `String(cString:)` 再 `.utf8` 等于把同一份内容解码一遍、再编码一遍。
    public func renderHTMLData(_ markdown: Data) -> Data {
        guard let parser = cmark_parser_new(Self.renderOptions) else { return Data() }
        defer { cmark_parser_free(parser) }

        for extensionPointer in Self.parserExtensions {
            cmark_parser_attach_syntax_extension(parser, extensionPointer)
        }

        markdown.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            cmark_parser_feed(parser, base.assumingMemoryBound(to: CChar.self), raw.count)
        }

        guard let document = cmark_parser_finish(parser) else { return Data() }
        defer { cmark_node_free(document) }

        guard let rendered = cmark_render_html(document, Self.renderOptions, Self.renderFilters) else {
            return Data()
        }
        defer { free(UnsafeMutableRawPointer(rendered)) }

        let bytes = UnsafeBufferPointer(start: rendered, count: strlen(rendered))
        // 绝大多数文档不含危险 scheme：先做一次只读扫描，命中才进重建路径。
        guard DangerousURLFilter.needsNeutralizing(bytes) else {
            return Data(bytes: rendered, count: bytes.count)
        }
        return DangerousURLFilter.neutralized(bytes)
    }
}
