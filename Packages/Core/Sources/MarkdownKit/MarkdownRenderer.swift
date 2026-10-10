import Foundation
import CcmarkGfm

public extension MarkdownRenderer {

    /// 单份文档的体积上限。超过就截断，不再整篇渲染。
    ///
    /// 天花板不是解析（约 25 MB/s）而是 WebKit 排版（约 236 ms/MB HTML），
    /// 所以「大文件先截断」是唯一有效的缓解手段 —— 见 docs/技术方案.md §3。
    ///
    /// 放在这里而不是各自调用方：Quick Look 扩展和主 App 的截断口径必须一致，
    /// 否则同一个文件两处显示会不一样长。
    static let defaultMaxBytes = 512 * 1024

    /// 读文件 + 超限截断。
    ///
    /// 截断尽量切在换行上，避免把一个 markdown 块结构切成半截。
    static func documentBytes(
        contentsOf url: URL,
        maxBytes: Int = Self.defaultMaxBytes
    ) throws -> Data {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > maxBytes else { return data }

        var slice = data.prefix(maxBytes)
        if let newline = slice.lastIndex(of: 0x0A) {
            slice = slice[..<newline]
        }
        var out = Data("\n\n> 文件过大，已截断显示前 \(maxBytes / 1024) KB\n".utf8)
        out.append(slice)
        return out
    }
}

/// Markdown → HTML。底层是 vendored cmark-gfm（C，静态链接）。
///
/// 性能约定（改动前先看 docs/技术方案.md §3 与 docs/benchmarks.md）：
/// - 入口收 `Data`，**不先把整篇转成 Swift String**，避免一次全量 UTF-8 校验 + 拷贝；
///   裸指针直接喂给 cmark。
/// - 本类型是线程安全的：cmark 解析器无全局可变状态（除一次性扩展注册）。
public struct MarkdownRenderer: Sendable {

    /// 启用的 GFM 扩展。顺序无关。
    ///
    /// **`tagfilter` 不能少**：我们开了 `CMARK_OPT_UNSAFE`（见 `renderOptions`），
    /// 裸 HTML 会原样输出，此时 tagfilter 是唯一在拦 `<script>` / `<style>` /
    /// `<iframe>` / `<title>` 这些东西的环节。
    public static let gfmExtensions = ["table", "strikethrough", "tasklist", "autolink", "tagfilter"]

    /// 渲染选项：用 `CMARK_OPT_UNSAFE`，**不是**默认的 `CMARK_OPT_DEFAULT`。
    ///
    /// 默认行为会把文档里所有裸 HTML 替换成 `<!-- raw HTML omitted -->`。
    /// 真实 README 顶部的徽章行（`<p align="center">` + `<img>`）、`<details>`、
    /// `<kbd>`、`<br>` 会整片消失，预览看起来像坏了 —— 与"渲染要好看"直接冲突。
    ///
    /// 打开后的安全边界由三层构成，**缺一不可**：
    /// 1. `tagfilter` 扩展：去掉 script / style / iframe / title / textarea /
    ///    xmp / noembed / noframes / plaintext
    /// 2. `neutralizingDangerousURLs(_:)`：`CMARK_OPT_UNSAFE` 会连"危险 scheme 链接"
    ///    一起放开，cmark 不再替我们净化，必须自己来。覆盖 `href` / `src` 的三种引号形态
    /// 3. `SharedTheme` 的 CSP `default-src 'none'`：挡住脚本执行与一切远程加载
    ///    （WebKit 下它同时会挡掉 `javascript:` 导航）
    ///
    /// ⚠️ 顺序是刻意的：2 是**主**防线（精确到属性值），3 是兜底。不要把 3 当成唯一依赖 ——
    /// 哪天为了远程图片把 CSP 放宽成 `img-src *`，只有 2 能继续拦住 `data:text/html`。
    public static let renderOptions: Int32 = CMARK_OPT_UNSAFE

    /// 会被清空的危险 scheme。`CMARK_OPT_UNSAFE` 打开后 cmark 不再拦这些。
    ///
    /// 只针对 `href` / `src` 两个属性；其他位置（正文里的字面文字）不去动。
    private static let dangerousSchemes = ["javascript:", "vbscript:", "data:text/html"]

    /// 危险 scheme 的 ASCII 字面量（小写），供字节级匹配用。
    private static let dangerousPatterns: [[UInt8]] = dangerousSchemes.map { Array($0.utf8) }

    /// 需要检查的属性名（小写）。
    private static let dangerousAttributes: [[UInt8]] = [Array("href".utf8), Array("src".utf8)]

    /// 替换危险 scheme 用的页内锚点前缀。冒号被吃掉，`javascript:alert(1)` 就退化成
    /// 一个点不动、也执行不了的锚点。
    private static let blockedFragment = "#blocked-"

    /// 上面那串的字节形式，重建路径里要用很多次。
    private static let blockedFragmentData = Data(blockedFragment.utf8)

    /// 扩展注册 + 指针解析各只做一次，每次渲染只剩 N 次 `attach`。
    ///
    /// 注意：实测这并没有提速（1KB p50 改前 0.087ms、改后 0.086ms，噪声内）。
    /// 保留只是因为语义更清晰。真正的固定开销（约 0.04ms）来自 `cmark_parser_new`
    /// 的 arena 分配 —— 见 docs/benchmarks.md。
    ///
    /// `nonisolated(unsafe)`：cmark 的扩展注册表是进程级全局、注册后不再变动，
    /// 这些指针生命周期与进程等长，本身不可变，只是类型系统无法证明。
    nonisolated(unsafe) private static let extensionPointers: [OpaquePointer] = {
        cmark_gfm_core_extensions_ensure_registered()
        return gfmExtensions.compactMap { cmark_find_syntax_extension($0) }
    }()

    /// 渲染期扩展列表 —— **tagfilter 只有放在这里才会生效**。
    ///
    /// 看 `html.c` 就明白：`CMARK_NODE_HTML_BLOCK` / `HTML_INLINE` 的分派里，
    /// 过滤走的是 `renderer->filter_extensions`，它来自 `cmark_render_html()` 的
    /// 第三个参数，**不是** parser 上 attach 的那些扩展。
    /// 只 attach 到 parser 而 render 传 nil，裸 `<script>` 会原样输出（踩过）。
    ///
    /// 进程生命周期内只建一次，故意不 free。
    nonisolated(unsafe) private static let filterList: UnsafeMutablePointer<cmark_llist>? = {
        guard let mem = cmark_get_default_mem_allocator(),
              let tagfilter = cmark_find_syntax_extension("tagfilter") else { return nil }
        return cmark_llist_append(mem, nil, UnsafeMutableRawPointer(tagfilter))
    }()

    public init() {}

    /// 把 UTF-8 编码的 Markdown 字节渲染成 HTML 片段。
    /// - Parameter markdown: 文档字节。不做编码探测，假定 UTF-8。
    /// - Returns: HTML 片段（不含 `<html>`/`<head>`，由 `SharedTheme.document` 套壳）。
    public func renderHTML(_ markdown: Data) -> String {
        String(decoding: renderHTMLData(markdown), as: UTF8.self)
    }

    /// 同 `renderHTML(_:)`，但**直接返回 cmark 产出的字节**，不经过 Swift String。
    ///
    /// 用这个版本：cmark 的输出本来就是 UTF-8 字节，走
    /// `String(cString:)` → `Data(body.utf8)` 等于「解码一遍 + 再编码一遍」，
    /// 白白多出两次全量拷贝（5MB 文档上是两次 5MB 的 memcpy + 一次 UTF-8 校验）。
    /// 数据型 QL 扩展只需要 `Data`，中间那个 String 完全没有意义。
    public func renderHTMLData(_ markdown: Data) -> Data {
        guard let parser = cmark_parser_new(Self.renderOptions) else { return Data() }
        defer { cmark_parser_free(parser) }

        for ext in Self.extensionPointers {
            cmark_parser_attach_syntax_extension(parser, ext)
        }

        markdown.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            cmark_parser_feed(parser, base.assumingMemoryBound(to: CChar.self), raw.count)
        }

        guard let doc = cmark_parser_finish(parser) else { return Data() }
        defer { cmark_node_free(doc) }

        guard let cstr = cmark_render_html(doc, Self.renderOptions, Self.filterList) else { return Data() }
        defer { free(UnsafeMutableRawPointer(cstr)) }

        // 先做一次便宜的字节级扫描；没命中就直接拷字节，不走下面的重建路径。
        let len = strlen(cstr)
        let buf = UnsafeBufferPointer(start: cstr, count: len)
        if !Self.containsDangerousScheme(buf) {
            return Data(bytes: cstr, count: len)
        }
        // 重建路径也走在字节上：既省掉 `String(cString:)` + `.utf8` 的两次全量拷贝，
        // 也让「按属性值处理」这件事不必先猜引号形态。
        return Self.neutralizingDangerousURLs(buf)
    }

    /// 把 `href` / `src` 属性值开头的危险 scheme 换成页内锚点。
    ///
    /// 为什么扫渲染结果、不走 AST：
    /// - AST 走查漏掉**裸 HTML** 里的 `<a href="javascript:…">`（它不是语法树节点），
    ///   而那正是打开 `CMARK_OPT_UNSAFE` 后新放开的面——必须覆盖到
    /// - 少一遍全树遍历，也就少一份耗时
    /// - 不用碰 `cmark_node_get_url()` 那笔说不清的所有权（它返回 arena 分配的串，
    ///   手动 `free` 会 double free）
    ///
    /// ⚠️ 必须覆盖三种引号形态（`"` / `'` / 无引号）与 `=` 两侧的空白。
    /// 上一版只做 `href="` 的字面替换：这在 markdown 语法产生的链接上够用（cmark 只输出
    /// 双引号，且会把值里的 `"` 转义成 %22），但裸 HTML 是**原样输出**的 ——
    /// `<a href='javascript:…'>` 会整个漏过去，而 `containsDangerousScheme` 明明命中了，
    /// 于是白跑一遍重建路径却什么都没改。这是"三层防护第二层事实上是漏的"。
    ///
    /// 做法是**换掉 scheme 本身**而不是去挖属性值边界：`href="javascript:alert(1)"`
    /// → `href="#blocked-alert(1)"`，冒号没了就只剩一个点不动的页内锚点。
    /// 不写「找闭合引号再清空中间」是因为清空后模式仍然匹配、替换成空等于没变，
    /// while 会不终止（踩过，别改回去）。
    ///
    /// 命中率极低（正常文档为零），所以上面先做一次便宜的 `contains` 判定；
    /// 只有真命中才走这里的逐字节重建。
    private static func neutralizingDangerousURLs(_ buf: UnsafeBufferPointer<CChar>) -> Data {
        let raw = UnsafeRawBufferPointer(buf)
        var out = Data()
        out.reserveCapacity(buf.count)
        var emitted = 0          // 已经写进 out 的原始字节数（区间左端）
        var i = 0
        while i < buf.count {
            if let valueStart = attributeValueStart(buf, at: i),
               let schemeLength = matchedSchemeLength(buf, at: valueStart) {
                // 属性名与开引号这些原样保留，只把 scheme 那一段换成锚点
                out.append(contentsOf: raw[emitted..<valueStart])
                out.append(blockedFragmentData)
                i = valueStart + schemeLength
                emitted = i
                continue
            }
            i += 1
        }
        out.append(contentsOf: raw[emitted..<buf.count])
        return out
    }

    /// 判断 `i` 处是不是 `href=` / `src=` 的**属性值起点**（已跳过空白与引号）。
    ///
    /// 返回 `nil` 表示这里不是我们关心的属性。属性名在 HTML 里大小写不敏感，
    /// 所以匹配是大小写不敏感的；同时要求前一个字节不是名字字符，
    /// 否则 `data-href=` 之类的自定义属性也会被当成 `href`。
    private static func attributeValueStart(_ buf: UnsafeBufferPointer<CChar>, at i: Int) -> Int? {
        let n = buf.count
        if i > 0, isAttributeNameByte(buf[i - 1]) { return nil }

        var j = i
        var matched = false
        for name in dangerousAttributes where j + name.count <= n && matchesASCII(buf, at: j, name) {
            j += name.count
            matched = true
            break
        }
        guard matched else { return nil }

        while j < n, isASCIISpace(buf[j]) { j += 1 }
        guard j < n, buf[j] == UInt8(ascii: "=") else { return nil }
        j += 1
        while j < n, isASCIISpace(buf[j]) { j += 1 }
        guard j < n else { return nil }
        if buf[j] == UInt8(ascii: "\"") || buf[j] == UInt8(ascii: "'") { j += 1 }
        return j < n ? j : nil
    }

    /// `i` 处是否以某个危险 scheme 开头，返回它的字节长度。
    private static func matchedSchemeLength(_ buf: UnsafeBufferPointer<CChar>, at i: Int) -> Int? {
        for pat in dangerousPatterns where matchesASCII(buf, at: i, pat) { return pat.count }
        return nil
    }

    /// 大小写不敏感的 ASCII 前缀比较（只用于小写的 pattern）。
    private static func matchesASCII(_ buf: UnsafeBufferPointer<CChar>, at i: Int, _ pattern: [UInt8]) -> Bool {
        guard i + pattern.count <= buf.count else { return false }
        for k in 0..<pattern.count where UInt8(bitPattern: buf[i + k]) | 0x20 != pattern[k] {
            return false
        }
        return true
    }

    private static func isASCIISpace(_ byte: CChar) -> Bool {
        let b = UInt8(bitPattern: byte)
        return b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C
    }

    /// 属性名字符（用于判定边界）。`-` 与 `_` 也算，因为自定义属性常见。
    private static func isAttributeNameByte(_ byte: CChar) -> Bool {
        let b = UInt8(bitPattern: byte)
        let lowered = b | 0x20
        return (lowered >= UInt8(ascii: "a") && lowered <= UInt8(ascii: "z"))
            || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
            || b == UInt8(ascii: "-") || b == UInt8(ascii: "_") || b == UInt8(ascii: ":")
    }

    /// 在渲染结果的原始字节上做大小写不敏感的子串查找。
    ///
    /// ⚠️ 不要用 `String.range(of:options:.caseInsensitive)` 做这件事：实测它在大字符串上
    /// 只有约 **4.5 MB/s**，50KB 文档的渲染耗时因此从 1.65ms 涨到 33ms（吞吐 28 → 1.5 MB/s）。
    /// 手写字节扫描是同一个量级快 200 倍的操作。见 docs/benchmarks.md。
    private static func containsDangerousScheme(_ buf: UnsafeBufferPointer<CChar>) -> Bool {
        let n = buf.count
        for pat in dangerousPatterns {
            let m = pat.count
            guard m <= n else { continue }
            var i = 0
            let last = n - m
            while i <= last {
                if UInt8(bitPattern: buf[i]) | 0x20 == pat[0] {
                    var j = 1
                    while j < m && UInt8(bitPattern: buf[i + j]) | 0x20 == pat[j] { j += 1 }
                    if j == m { return true }
                }
                i += 1
            }
        }
        return false
    }
}
