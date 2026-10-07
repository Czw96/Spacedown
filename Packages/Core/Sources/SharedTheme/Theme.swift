import Foundation

/// 渲染产物的外壳：CSS + HTML 模板。
///
/// 全部以 `Data` 形式预拼好，拼接时是纯 memcpy，不做字符串插值——见 docs/技术方案.md §3。
public enum SharedTheme {

    /// 内容样式表。明暗双主题靠 CSS 自身切换，Swift 侧不需要感知当前主题。
    public static let css: Data = {
        guard let url = Bundle.module.url(forResource: "theme", withExtension: "css") else {
            fatalError("theme.css 未打进 SharedTheme resource bundle —— 这是打包 bug，不是运行时可恢复的错误")
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            fatalError("theme.css 读取失败：\(error)")
        }
    }()

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
    /// - Parameter body: `MarkdownRenderer` 的输出（不含 html/head/body）。
    public static func document(body: Data) -> Data {
        var out = Data()
        out.reserveCapacity(htmlPrefix.count + body.count + htmlSuffix.count)
        out.append(htmlPrefix)
        out.append(body)
        out.append(htmlSuffix)
        return out
    }
}
