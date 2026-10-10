import Foundation
import os

/// 渲染产物的外壳：CSS + HTML 模板。
///
/// 全部以 `Data` 形式预拼好，拼接时是纯 memcpy，不做字符串插值——见 docs/技术方案.md §3。
public enum SharedTheme {

    private static let logger = Logger(subsystem: "cn.29dev.Spacedown", category: "theme")

    /// `theme.css` 所在的 bundle 取决于构建方式，两条链路的落点不同：
    ///
    /// - **SwiftPM**（`swift build`）：走 SwiftPM 的 resource bundle，即 `Bundle.module`
    /// - **Xcode**：SharedTheme 是一个 framework，`theme.css` 躺在它自己的 Resources 里，
    ///   所以要用「定义这个类型的 bundle」来找 —— `Bundle.main` 会是宿主 App / appex，
    ///   那里没有这个文件
    ///
    /// `SPACEDOWN_SPM_BUILD` 由 Package.swift 注入，只在 SwiftPM 构建下成立。
    private static var cssBundle: Bundle {
    #if SPACEDOWN_SPM_BUILD
        Bundle.module
    #else
        Bundle(for: ThemeToken.self)
    #endif
    }

    /// 只用来定位上面的 bundle，无其他用途。
    private final class ThemeToken {}

    /// 内容样式表。明暗双主题靠 CSS 自身切换，Swift 侧不需要感知当前主题。
    ///
    /// ⚠️ 读不到时**不崩**，退回下面那份最简样式。这份代码 App 与 Quick Look 扩展共用：
    /// 扩展崩掉会让 Finder 的预览链路一起抖动，而"样式没打进 bundle"本来就只是打包事故 ——
    /// 能出内容比出一份崩溃报告有用得多。
    public static let css: Data = {
        guard let url = cssBundle.url(forResource: "theme", withExtension: "css") else {
            logger.error("theme.css 不在 bundle 里，退回内置最简样式（这是打包 bug）")
            return fallbackCSS
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            logger.error("theme.css 读取失败：\(error.localizedDescription, privacy: .public)，退回内置最简样式")
            return fallbackCSS
        }
    }()

    /// 打包事故时的保底样式：只保证能读，不追求好看。
    private static let fallbackCSS = Data(#"""
    :root { color-scheme: light dark; }
    body {
        margin: 0; background: #ffffff; color: #1b1b1f;
        font: 16px/1.6 -apple-system, "PingFang SC", sans-serif;
    }
    .content { max-width: 44rem; margin: 0 auto; padding: 2.5rem 3rem 6rem; }
    pre { overflow-x: auto; padding: 0.9rem 1.1rem; background: #f7f7f8; border-radius: 10px; }
    code { font-family: ui-monospace, Menlo, monospace; }
    .table-wrap { margin: 0 0 1.5em; overflow-x: auto; }
    @media (prefers-color-scheme: dark) {
        body { background: #1b1b1d; color: #e9e9ec; }
        pre { background: #242427; }
    }
    """#.utf8)

    /// `<!doctype>` 到 `<div class="content">` 为止。
    /// CSP 只放行 data: 图片——图片已在渲染期内联成 base64，HTML 是单文件自包含的。
    public static let htmlPrefix: Data = {
        var d = Data()
        d.append(Data(#"""
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
<style>
"""#.utf8))
        d.append(css)
        d.append(Data(#"""
</style>
</head>
<body>
<div class="content">
"""#.utf8))
        return d
    }()

    /// 收尾。
    public static let htmlSuffix: Data = Data(#"""
</div>
</body>
</html>
"""#.utf8)

    /// 把 cmark 产出的 HTML 片段包成完整文档。
    /// - Parameters:
    ///   - body: `MarkdownRenderer` 的输出（不含 html/head/body）。
    ///   - measurePercent: 版心宽度，**占可用宽度的百分比**（100 = 铺满）。
    ///     100 走的是纯 memcpy 的快路径；其余值才追加一小段覆盖样式。
    ///     ⚠️ 这是**渲染期参数**：改了它，同一份文件也要重新渲染，不能只改 CSS 变量了事。
    public static func document(body: Data, measurePercent: Int = fullMeasurePercent) -> Data {
        let wrapped = wrappingTables(body)
        var out = Data()
        out.reserveCapacity(htmlPrefix.count + 48 + wrapped.count + htmlSuffix.count)
        out.append(htmlPrefix)
        if measurePercent != fullMeasurePercent {
            // 放在 htmlPrefix 之后（也就是落在 <body> 里）即可生效：自定义属性是全局的，
            // 且同优先级下后出现的赢。这样就完全不用去动那份预拼好的 css。
            out.append(Data("<style>:root{--measure:\(measurePercent)%}</style>".utf8))
        }
        out.append(wrapped)
        out.append(htmlSuffix)
        return out
    }

    /// 版心"铺满"。同时是 `measurePercent` 的取值上界。
    public static let fullMeasurePercent = 100

    // MARK: - 表格横向滚动容器

    /// 给每个 `<table>` 套一层 `overflow-x: auto` 的容器。
    ///
    /// 为什么在渲染期做而不是纯 CSS：`pre` 早就写了 `overflow-x: auto`，表格却没有对应容器 ——
    /// 宽表格（本项目自己的基准表就是）在 Quick Look 窄面板里会直接撑破版心，右侧列读不到。
    /// CSS 侧 `table { display: block; overflow-x: auto }` 那个偏方会把表格盒换成块盒，
    /// 连带改变宽度与边框合并行为，不如老实包一层（GitHub 也是这么做的）。
    ///
    /// 安全性：代码块里的 `<table` 已被 cmark 转义成 `&lt;table`，不会误伤；
    /// markdown 表格不嵌套，所以「第一个 `</table>` 就是配对的」成立。
    ///
    /// 成本：只有真出现 `<table` 才重建，且只做一次前向扫描（每个字节只看一遍）。
    private static func wrappingTables(_ body: Data) -> Data {
        let open = Array("<table".utf8)
        let close = Array("</table>".utf8)
        let base = body.startIndex

        guard firstIndex(of: open, in: body, from: 0) != nil else { return body }

        var out = Data()
        out.reserveCapacity(body.count + 64)
        var cursor = 0
        var search = 0
        while let openAt = firstIndex(of: open, in: body, from: search) {
            guard let closeAt = firstIndex(of: close, in: body, from: openAt) else {
                break        // 没有闭合标签：原样留着，别自己制造坏结构
            }
            let closeEnd = closeAt + close.count
            out.append(body[base + cursor ..< base + openAt])
            out.append(tableWrapOpen)
            out.append(body[base + openAt ..< base + closeEnd])
            out.append(tableWrapClose)
            cursor = closeEnd
            search = closeEnd
        }
        out.append(body[base + cursor ..< body.endIndex])
        return out
    }

    /// 在字节流里做大小写不敏感的 ASCII 子串查找，返回匹配处的**字节偏移**。
    ///
    /// 不用 `Data.range(of:options:)`：`Data.SearchOptions` 就是 `NSData.SearchOptions`，
    /// 里面根本没有大小写不敏感这一项（试过，编译不过）。手写十来行，顺带比 Foundation
    /// 的大小写不敏感路径快得多 —— 同一条结论在 `MarkdownRenderer` 里有实测数据。
    private static func firstIndex(of needle: [UInt8], in haystack: Data, from offset: Int) -> Int? {
        guard !needle.isEmpty, haystack.count - offset >= needle.count else { return nil }
        return haystack.withUnsafeBytes { raw -> Int? in
            let last = raw.count - needle.count
            var i = max(0, offset)
            while i <= last {
                if raw[i] | 0x20 == needle[0] {
                    var j = 1
                    while j < needle.count,
                          raw[i + j] | 0x20 == needle[j] { j += 1 }
                    if j == needle.count { return i }
                }
                i += 1
            }
            return nil
        }
    }

    private static let tableWrapOpen = Data(#"<div class="table-wrap">"#.utf8)
    private static let tableWrapClose = Data("</div>".utf8)
}
