import Foundation
import os

/// 渲染产物的外壳：样式表 + HTML 模板。
///
/// 所有片段都以 `Data` 预拼好，组装时是纯 memcpy，不做字符串插值。
public enum SharedTheme {

    /// 版心"铺满"。同时是 `measurePercent` 的取值上界。
    public static let fullMeasurePercent = 100

    private static let logger = Logger(subsystem: "cn.29dev.Spacedown", category: "theme")

    /// 内容样式表。明暗主题由 CSS 自己按 `prefers-color-scheme` 切换，Swift 侧不感知。
    public static let css: Data = {
        guard let url = cssBundle.url(forResource: "theme", withExtension: "css") else {
            logger.error("theme.css 不在 bundle 里，退回内置最简样式（打包问题）")
            return fallbackCSS
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            logger.error("theme.css 读取失败：\(error.localizedDescription, privacy: .public)，退回内置最简样式")
            return fallbackCSS
        }
    }()

    /// `<!doctype>` 到 `<div class="content">`。
    ///
    /// CSP 放行内联样式、`data:` 图片与 **https 远程图片**：本地图片在渲染期已内联成
    /// base64，远程图片交给 WebKit 自己去取（与浏览器行为一致，用户按空格看到的就是
    /// 文档本来的样子）。其余一律不放行 —— 没有 `script-src`，也没有 `connect-src`，
    /// 所以文档里的脚本与 fetch 依然跑不起来；只放 `https:` 是因为 `http:` 图片会带来
    /// 明文的中间人篡改面，而现在的图床基本都是 https。
    ///
    /// `form-action` 与 `base-uri` **不继承** `default-src`，必须单独写：前者挡住
    /// 裸 HTML 里的 `<form action="https://…">` 把内容提交出去，后者挡住 `<base href>`
    /// 改写页面内的相对地址。
    public static let htmlPrefix: Data = {
        var prefix = Data()
        prefix.append(Data(#"""
        <!DOCTYPE html>
        <html lang="zh">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: https:; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'">
        <style>
        """#.utf8))
        prefix.append(css)
        prefix.append(Data(#"""
        </style>
        </head>
        <body>
        <div class="content">
        """#.utf8))
        return prefix
    }()

    /// `.content` 的收尾。
    public static let htmlSuffix = Data(#"""
    </div>
    </body>
    </html>
    """#.utf8)

    /// 把 HTML 片段包成完整文档。
    ///
    /// - Parameters:
    ///   - body: `MarkdownRenderer` 的输出（不含 html / head / body）。
    ///   - measurePercent: 版心宽度，占**可用宽度**的百分比，100 表示铺满。
    ///     非 100 时追加一小段覆盖样式，因此它是**渲染期参数** —— 改了它，
    ///     同一份文件也要重新生成 HTML。
    ///   - baseDirectory: Markdown 文件所在目录。给了它才会把相对路径图片内联成
    ///     base64（见 `ImageInliner`）；不给则图片保持相对地址，等于不显示。
    ///   - imageData: 已经拿到手的图片字节，键是标准化后的绝对路径。
    ///     Quick Look 扩展拿不到兄弟文件的读权限，图片由非沙箱的 XPC 服务代读后塞进来；
    ///     主 App 不传，走磁盘。
    public static func document(
        body: Data,
        measurePercent: Int = fullMeasurePercent,
        baseDirectory: URL? = nil,
        imageData: [URL: Data] = [:]
    ) -> Data {
        var content = DocumentRewriter.process(body)
        if let baseDirectory {
            content = ImageInliner.rewrite(content, baseDirectory: baseDirectory,
                                           preloaded: imageData)
        }

        var document = Data()
        document.reserveCapacity(htmlPrefix.count + content.count + htmlSuffix.count + 48)
        document.append(htmlPrefix)
        if measurePercent != fullMeasurePercent {
            // 覆盖样式落在 <body> 内即可生效：自定义属性是全局的，同优先级下后出现的赢，
            // 这样就不必去改预拼好的 css。
            document.append(Data("<style>:root{--measure:\(measurePercent)%}</style>".utf8))
        }
        document.append(content)
        document.append(htmlSuffix)
        return document
    }

    /// 打包事故时的保底样式：只保证能读。
    private static let fallbackCSS = Data(#"""
    :root { color-scheme: light dark; }
    body {
        margin: 0; background: #ffffff; color: #1b1b1f;
        font: 16px/1.6 -apple-system, "PingFang SC", sans-serif;
    }
    .content { margin: 0 auto; padding: 2.5rem 3rem 6rem; }
    pre { overflow-x: auto; padding: 0.9rem 1.1rem; background: #f7f7f8; border-radius: 10px; }
    code { font-family: ui-monospace, Menlo, monospace; }
    .table-wrap { margin: 0 0 1.5em; overflow-x: auto; }
    @media (prefers-color-scheme: dark) {
        body { background: #1b1b1d; color: #e9e9ec; }
        pre { background: #242427; }
    }
    """#.utf8)

    /// `theme.css` 的落点取决于构建方式：
    /// SwiftPM 下是 `Bundle.module`，Xcode 下是 SharedTheme.framework 自己的资源目录 ——
    /// 后者要用「定义这个类型的 bundle」来找，`Bundle.main` 会是宿主 App。
    private static var cssBundle: Bundle {
    #if SPACEDOWN_SPM_BUILD
        Bundle.module
    #else
        Bundle(for: ThemeToken.self)
    #endif
    }

    /// 只用来定位上面的 bundle。
    private final class ThemeToken {}
}
