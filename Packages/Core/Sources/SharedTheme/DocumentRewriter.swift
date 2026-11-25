import Foundation

/// 渲染结果的后处理：给表格套横向滚动容器、把 GitHub 提示块标成带 class 的引用块。
///
/// 两步都在渲染期做，而不是交给 CSS：
/// - 表格需要一层 `overflow-x: auto` 的父元素。纯 CSS 的 `table { display: block }`
///   会把表格盒换成块盒，连带改变宽度与边框合并行为。
/// - `> [!NOTE]` 不在 GFM 里，cmark 产出的只是普通引用块加一行字面文本，CSS 认不出来。
///
/// 两步都只在对应标记出现时才重建，正常文档的代价就是一次扫描。
enum DocumentRewriter {

    static func process(_ body: Data) -> Data {
        addingHeadingIDs(in: markingAlerts(in: wrappingTables(in: body)))
    }

    // MARK: - 标题锚点

    /// 给每个标题补 `id`，让 `[说明](#说明)` 这类页内锚点真的能跳。
    ///
    /// cmark-gfm **不生成**标题 id（GitHub 是在渲染之后另做一遍），所以在这之前
    /// 所有 `#锚点` 都是死链：点了没反应，因为目标元素根本不存在。
    ///
    /// slug 规则对齐 GitHub：小写、空白转 `-`、丢掉标点、保留中日韩等字母、重名依次加
    /// `-1`、`-2`。刻意不追求 100% 一致（GitHub 的标点表有几百个字符），常见标题一致即可。
    private static func addingHeadingIDs(in body: Data) -> Data {
        let html = String(decoding: body, as: UTF8.self)
        guard html.contains("<h") else { return body }
        guard let regex = try? NSRegularExpression(
            pattern: "<h([1-6])>(.*?)</h\\1>",
            options: [.dotMatchesLineSeparators]
        ) else { return body }

        let full = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: full)
        guard !matches.isEmpty else { return body }

        // 先按文档顺序算出每个标题的新写法（重名编号才跟 GitHub 一致），再从后往前替换：
        // 反向替换时，后面的偏移变化不会影响前面的 range。
        var used: [String: Int] = [:]
        var edits: [(range: Range<String.Index>, text: String)] = []
        for match in matches {
            guard let whole = Range(match.range, in: html),
                  let inner = Range(match.range(at: 2), in: html) else { continue }
            let text = plainText(String(html[inner]))
            guard !text.isEmpty, let slug = uniqueSlug(for: text, used: &used) else { continue }

            let heading = String(html[whole])
            guard let openEnd = heading.firstIndex(of: ">") else { continue }
            let openTag = heading[..<openEnd]                       // `<h2`
            let rest = heading[heading.index(after: openEnd)...]    // `AI 实现说明</h2>`
            edits.append((whole, "\(openTag) id=\"\(slug)\">\(rest)"))
        }
        guard !edits.isEmpty else { return body }

        var result = html
        for edit in edits.reversed() {
            result.replaceSubrange(edit.range, with: edit.text)
        }
        return Data(result.utf8)
    }

    /// 去掉行内标签（`<a>`、`<code>`…）与常见实体，留下纯文本。
    private static func plainText(_ html: String) -> String {
        var text = html
        if let tag = try? NSRegularExpression(pattern: "<[^>]+>") {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = tag.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }
        return text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    /// GitHub 风格的 slug：小写、空白转 `-`、只留字母/数字/`-`/`_`。
    private static func uniqueSlug(for text: String, used: inout [String: Int]) -> String? {
        var slug = ""
        var pendingDash = false
        for character in text.lowercased() {
            if character.isWhitespace {
                pendingDash = !slug.isEmpty
                continue
            }
            guard character.isLetter || character.isNumber
                    || character == "-" || character == "_" else {
                // 标点、emoji 一律丢掉（GitHub 也是丢，只是它有一张更细的表）
                continue
            }
            if pendingDash, !slug.hasSuffix("-") { slug.append("-") }
            pendingDash = false
            slug.append(character)
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        guard !slug.isEmpty else { return nil }

        if let count = used[slug] {
            used[slug] = count + 1
            return "\(slug)-\(count)"
        }
        used[slug] = 1
        return slug
    }

    // MARK: - 表格

    private static let tableOpen = Array("<table".utf8)
    private static let tableClose = Array("</table>".utf8)
    private static let tableWrapOpen = Data(#"<div class="table-wrap">"#.utf8)
    private static let tableWrapClose = Data("</div>".utf8)

    /// 给每个 `<table>` 包一层 `.table-wrap`。
    ///
    /// 代码块里的 `<table` 已被 cmark 转义成 `&lt;table`，不会误伤；markdown 表格不嵌套，
    /// 所以「第一个 `</table>` 就是配对的」。没有闭合标签时原样保留，不自造坏结构。
    private static func wrappingTables(in body: Data) -> Data {
        guard firstIndex(of: tableOpen, in: body, from: 0) != nil else { return body }

        var output = Data()
        output.reserveCapacity(body.count + 64)
        var copied = 0
        var searchFrom = 0

        while let openAt = firstIndex(of: tableOpen, in: body, from: searchFrom) {
            guard let closeAt = firstIndex(of: tableClose, in: body, from: openAt) else { break }
            let closeEnd = closeAt + tableClose.count
            output.append(body[copied..<openAt])
            output.append(tableWrapOpen)
            output.append(body[openAt..<closeEnd])
            output.append(tableWrapClose)
            copied = closeEnd
            searchFrom = closeEnd
        }
        output.append(body[copied...])
        return output
    }

    /// 大小写不敏感的 ASCII 子串查找，返回**字节偏移**。
    ///
    /// 不用 `Data.range(of:options:)`：`Data.SearchOptions` 没有大小写不敏感这一项。
    private static func firstIndex(of needle: [UInt8], in haystack: Data, from offset: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        return haystack.withUnsafeBytes { raw -> Int? in
            var index = max(0, offset)
            let last = raw.count - needle.count
            while index <= last {
                if raw[index] | 0x20 == needle[0] {
                    var matched = 1
                    while matched < needle.count, raw[index + matched] | 0x20 == needle[matched] {
                        matched += 1
                    }
                    if matched == needle.count { return index }
                }
                index += 1
            }
            return nil
        }
    }

    // MARK: - GitHub 提示块

    private static let alertMarker = Data("<blockquote>\n<p>[!".utf8)

    /// `[!TYPE]` → CSS class。顺序无关，按 GitHub 的语义强度排。
    private static let alertClasses: [String: String] = [
        "NOTE": "note",
        "TIP": "tip",
        "IMPORTANT": "important",
        "WARNING": "warning",
        "CAUTION": "caution",
    ]

    /// 把 `<blockquote>` 紧跟 `<p>[!TYPE]` 的形态改写成带 class 的引用块。
    ///
    /// 判定刻意保守：类型名必须全大写且在表里，否则整段原样输出 —— 普通引用块一律不碰。
    private static func markingAlerts(in body: Data) -> Data {
        var output = Data()
        output.reserveCapacity(body.count)
        var copied = body.startIndex

        while let marker = body.range(of: alertMarker, in: copied..<body.endIndex) {
            output.append(body[copied..<marker.lowerBound])

            guard let (cssClass, contentStart) = alert(in: body, after: marker.upperBound) else {
                // 不是认识的提示块：把标记本身原样吐出，从下一个字节继续找（否则会死循环）
                output.append(body[marker.lowerBound..<marker.upperBound])
                copied = marker.upperBound
                continue
            }
            output.append(Data("<blockquote class=\"alert alert-\(cssClass)\">\n<p>".utf8))
            copied = contentStart
        }
        output.append(body[copied...])
        return output
    }

    /// 读出 `[!TYPE]` 的类型，并返回正文起点（跳过标记独占一行时留下的换行）。
    private static func alert(in body: Data, after start: Data.Index) -> (cssClass: String, content: Data.Index)? {
        var cursor = start
        var name = ""
        while cursor < body.endIndex, isUppercaseASCII(body[cursor]), name.utf8.count < 9 {
            name.append(Character(UnicodeScalar(body[cursor])))
            cursor = body.index(after: cursor)
        }
        guard cursor < body.endIndex,
              body[cursor] == UInt8(ascii: "]"),
              let cssClass = alertClasses[name] else { return nil }

        var content = body.index(after: cursor)
        if content < body.endIndex, body[content] == 0x0A {
            content = body.index(after: content)
        }
        return (cssClass, content)
    }

    private static func isUppercaseASCII(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")
    }
}
