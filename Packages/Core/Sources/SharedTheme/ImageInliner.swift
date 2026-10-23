import Foundation
import os

/// 把 `src` 指向本地相对路径的 `<img>` 改写成 base64 data URI。
///
/// 为什么必须在渲染期做，而不是交给 web view 解析相对地址：
/// 1. 装载时 baseURL 是 `about:blank`（`WebViewDocument` 故意不用 file URL，
///    否则 WebKit 会去申请目录读权限，那是一次可能阻塞主线程的 IPC）；
/// 2. 文档 CSP 是 `default-src 'none'; img-src data:`，相对地址本来就被挡掉；
/// 3. Quick Look 扩展在沙箱里，拿不到被预览文件所在目录的读权限 ——
///    图片能不能读出来，取决于我们主动去读，而不是 web view 去请求。
///
/// 所以唯一能让相对路径图片显示出来的位置，就是这里：出 HTML 之前把字节塞进去。
///
/// 走的是与 `DocumentRewriter` 相同的策略：先扫一遍，没有 `<img>` 就直接返回原
/// `Data`，正常文档的额外代价只是一次字节比较。
enum ImageInliner {

    private static let logger = Logger(subsystem: "cn.29dev.Spacedown", category: "image")

    /// 单张图片的字节上限。超过就不内联，换成占位符。
    ///
    /// 上限针对的不是读文件，而是之后 WebKit 的排版与解码：base64 会把体积撑到 4/3，
    /// 一张 8 MB 的照片能在窄面板里卡住首帧。
    static let maxBytesPerImage = 2 * 1024 * 1024

    /// 整篇文档的内联总量上限。超预算的图片一律换占位符，避免一张长图集文档把内存打满。
    static let maxBytesTotal = 20 * 1024 * 1024

    /// 认识的图片扩展名 → MIME。
    ///
    /// 不认扩展名的一律不内联：靠魔数嗅探要逐个格式写识别，收益很低，
    /// 而不认识的类型塞进 `data:` 也未必解码得了。
    private static let mimeTypes: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "avif": "image/avif",
        "heic": "image/heic",
        "bmp": "image/bmp",
        "tif": "image/tiff",
        "tiff": "image/tiff",
        "ico": "image/x-icon",
        "svg": "image/svg+xml",
    ]

    /// 超限占位符：灰底 + 一行说明。
    ///
    /// 用灰阶 + 半透明填充，浅色深色主题下都不突兀（`<img>` 里的 SVG 拿不到
    /// `currentColor`，只能取中间灰）。
    private static let oversizePlaceholder: String = {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="480" height="72" viewBox="0 0 480 72">\
        <rect width="480" height="72" rx="8" fill="#808080" fill-opacity="0.12"/>\
        <text x="20" y="43" font-family="-apple-system, PingFang SC, sans-serif" \
        font-size="13" fill="#808080">图片过大，未内联</text></svg>
        """
        return "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
    }()

    /// 扫描并改写。没有可内联的图片时原样返回，不做拷贝。
    ///
    /// - Parameters:
    ///   - html: `MarkdownRenderer` 产出的片段（此时 `<img>` 还没被包进外壳）。
    ///   - baseDirectory: Markdown 文件所在目录，相对路径以它为基准。
    static func rewrite(_ html: Data, baseDirectory: URL) -> Data {
        guard let firstTag = nextImageTag(in: html, from: html.startIndex) else { return html }

        var output = Data()
        output.reserveCapacity(html.count)
        var cursor = html.startIndex
        var budget = maxBytesTotal
        // 同一张图在文档里出现多次时只读一次；同一文件的大图也只需要一个占位符。
        var resolved: [String: String] = [:]

        var tagStart = firstTag
        while true {
            append(html[cursor..<tagStart], to: &output)
            let tagEnd = endOfTag(in: html, from: tagStart)
            let source = tagEnd.flatMap { sourceRange(in: html, tagStart..<$0) }

            guard let source else {
                // 结构认不出来（畸形标签）：原样保留到下一个 '>'，继续往后找。
                let stop = tagEnd.map { html.index(after: $0) } ?? html.endIndex
                append(html[tagStart..<stop], to: &output)
                cursor = stop
                guard let next = nextImageTag(in: html, from: cursor) else {
                    append(html[cursor...], to: &output)
                    return output
                }
                tagStart = next
                continue
            }

            let key = String(decoding: html[source], as: UTF8.self)
            let replacement: String
            if let cached = resolved[key] {
                replacement = cached
            } else {
                replacement = inlineSource(key, baseDirectory: baseDirectory, budget: &budget)
                resolved[key] = replacement
            }

            append(html[cursor..<source.lowerBound], to: &output)
            append(Data(replacement.utf8), to: &output)
            cursor = source.upperBound

            guard let next = nextImageTag(in: html, from: cursor) else {
                append(html[cursor...], to: &output)
                return output
            }
            tagStart = next
        }
    }

    /// 把一个 `src` 值解析成 data URI；不该内联时返回原值。
    ///
    /// 返回原值等于维持现状（web view 里显示成坏图），占位符只用于「文件在、但太大」。
    private static func inlineSource(_ source: String, baseDirectory: URL, budget: inout Int) -> String {
        guard isRelativePath(source) else { return source }
        guard let path = localPath(for: source, baseDirectory: baseDirectory) else { return source }

        let mime: String
        let extensionName = path.pathExtension.lowercased()
        guard let known = mimeTypes[extensionName] else { return source }
        mime = known

        guard let values = try? path.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            return source
        }

        let size = values.fileSize ?? 0
        if size > maxBytesPerImage || size > budget {
            logger.debug("图片超限，用占位符：\(path.lastPathComponent, privacy: .private) \(size) B")
            return oversizePlaceholder
        }

        // mappedIfSafe：读的是映射而不是整块拷贝，后面 base64 再一次性分配。
        guard let bytes = try? Data(contentsOf: path, options: .mappedIfSafe) else {
            // 沙箱里最可能是这里失败（兄弟目录没有读权限）。留原值，别假装成功。
            logger.debug("图片读不到：\(path.lastPathComponent, privacy: .private)")
            return source
        }

        budget -= bytes.count
        return "data:\(mime);base64," + bytes.base64EncodedString()
    }

    /// 只处理相对路径。带 scheme 的（http / https / data / file / mailto）、
    /// 协议相对地址（`//host/x.png`）和页内锚点都原样留着。
    private static func isRelativePath(_ source: String) -> Bool {
        guard !source.isEmpty else { return false }
        if source.hasPrefix("//") || source.hasPrefix("#") { return false }
        // `^[A-Za-z][A-Za-z0-9+.-]*:` —— RFC 3986 的 scheme 语法
        var sawLetter = false
        for byte in source.utf8 {
            if byte == UInt8(ascii: ":") { return !sawLetter }
            if byte == UInt8(ascii: "/") { return true }
            let isAlpha = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
            if !sawLetter {
                guard isAlpha else { return true }
                sawLetter = true
            } else {
                let isDigit = byte >= 48 && byte <= 57
                let isSchemePunctuation = byte == UInt8(ascii: "+")
                    || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
                guard isAlpha || isDigit || isSchemePunctuation else { return true }
            }
        }
        return true
    }

    /// cmark 会把非 ASCII 与空格百分号编码（`图 片.png` → `%E5%9B%BE%20...`），
    /// 所以解析回文件路径必须解码。查询串与锚点对文件系统无意义，先切掉。
    private static func localPath(for source: String, baseDirectory: URL) -> URL? {
        var raw = source
        if let hash = raw.firstIndex(of: "#") { raw = String(raw[raw.startIndex..<hash]) }
        if let question = raw.firstIndex(of: "?") { raw = String(raw[raw.startIndex..<question]) }
        guard !raw.isEmpty else { return nil }

        let decoded = raw.removingPercentEncoding ?? raw
        if decoded.hasPrefix("/") { return URL(fileURLWithPath: decoded) }
        return baseDirectory.appendingPathComponent(decoded)
    }

    // MARK: - 字节扫描

    private static let imageOpen = Array("<img".utf8)

    /// 找下一个 `<img`。cmark 永远输出小写标签，所以不必做大小写折叠。
    private static func nextImageTag(in html: Data, from start: Data.Index) -> Data.Index? {
        guard start < html.endIndex else { return nil }
        var index = start
        while index < html.endIndex {
            guard html[index] == imageOpen[0] else {
                index = html.index(after: index)
                continue
            }
            // `<image` 之类的自定义元素不该被当成 img：要求 `<img` 之后是空白或 '>'
            var probe = html.index(after: index)
            var matched = 1
            while matched < imageOpen.count, probe < html.endIndex {
                guard html[probe] == imageOpen[matched] else { break }
                probe = html.index(after: probe)
                matched += 1
            }
            if matched == imageOpen.count {
                if probe == html.endIndex { return index }
                let next = html[probe]
                if next == UInt8(ascii: " ") || next == UInt8(ascii: "\n")
                    || next == UInt8(ascii: "\t") || next == UInt8(ascii: "\r")
                    || next == UInt8(ascii: ">") || next == UInt8(ascii: "/") {
                    return index
                }
            }
            index = html.index(after: index)
        }
        return nil
    }

    /// 标签的结束 `>`（跳过引号内的内容：`alt="a>b"` 里的 `>` 不算结束）。
    private static func endOfTag(in html: Data, from start: Data.Index) -> Data.Index? {
        var quote: UInt8?
        var index = start
        while index < html.endIndex {
            let byte = html[index]
            if let open = quote {
                if byte == open { quote = nil }
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                quote = byte
            } else if byte == UInt8(ascii: ">") {
                return index
            }
            index = html.index(after: index)
        }
        return nil
    }

    /// 在标签范围内找 `src` 属性的值区间（不含引号）。
    ///
    /// 按属性名整体比较，所以 `data-src` / `lowsrc` 不会被误当成 `src`。
    private static func sourceRange(in html: Data, _ tag: Range<Data.Index>) -> Range<Data.Index>? {
        var index = tag.lowerBound
        while index < tag.upperBound {
            // 跳过空白与分隔符
            while index < tag.upperBound, isSpace(html[index]) || html[index] == UInt8(ascii: "/") {
                index = html.index(after: index)
            }
            guard index < tag.upperBound else { return nil }

            // 属性名
            let nameStart = index
            while index < tag.upperBound, !isSpace(html[index]),
                  html[index] != UInt8(ascii: "="), html[index] != UInt8(ascii: ">") {
                index = html.index(after: index)
            }
            let name = String(decoding: html[nameStart..<index], as: UTF8.self).lowercased()

            while index < tag.upperBound, isSpace(html[index]) { index = html.index(after: index) }
            guard index < tag.upperBound, html[index] == UInt8(ascii: "=") else {
                // 无值属性（`<img hidden>`）：继续看下一个
                continue
            }
            index = html.index(after: index)
            while index < tag.upperBound, isSpace(html[index]) { index = html.index(after: index) }
            guard index < tag.upperBound else { return nil }

            let quote = html[index]
            if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
                let valueStart = html.index(after: index)
                var valueEnd = valueStart
                while valueEnd < tag.upperBound, html[valueEnd] != quote {
                    valueEnd = html.index(after: valueEnd)
                }
                if name == "src" { return valueStart..<valueEnd }
                index = html.index(after: valueEnd)
            } else {
                // 无引号属性值：到空白或 '>' 为止
                let valueStart = index
                var valueEnd = index
                while valueEnd < tag.upperBound, !isSpace(html[valueEnd]),
                      html[valueEnd] != UInt8(ascii: ">") {
                    valueEnd = html.index(after: valueEnd)
                }
                if name == "src" { return valueStart..<valueEnd }
                index = valueEnd
            }
        }
        return nil
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n")
            || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
    }

    private static func append(_ slice: Data.SubSequence, to output: inout Data) {
        output.append(contentsOf: slice)
    }
}
