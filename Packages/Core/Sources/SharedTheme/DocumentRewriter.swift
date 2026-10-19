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
        markingAlerts(in: wrappingTables(in: body))
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
