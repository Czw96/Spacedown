import AppKit
import UniformTypeIdentifiers

/// 「这个文件我们能预览吗」的唯一判据。
///
/// 刻意按**扩展名**判断而不是 UTI：本机 `.mdown` / `.mkdn` / `.mdx` 等分别被
/// WPS 与其它扩展认领成了各自的 UTI，按 UTI 白名单会把它们整片漏掉；
/// 而我们对内容没有额外要求 —— 都是文本，cmark 照渲染。
enum MarkdownFileType {

    /// 系统给 `.md` / `.markdown` 的 UTI。设置默认打开方式时用它。
    static let preferredUTI = "net.daringfireball.markdown"

    private static let extensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn", "mdtxt", "mdwn", "mdx", "rmd", "qmd",
    ]

    static func isSupported(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return extensions.contains(url.pathExtension.lowercased())
    }

    /// 打开面板的默认类型过滤。只影响下拉菜单里默认选中哪类文件，不影响手选。
    static let openPanelTypes: [UTType] = {
        let identifiers = [
            preferredUTI,
            "public.markdown",
            "com.kingsoft.wpsoffice.markdown",   // 本机被 WPS 认领的 .mdown / .mkd
        ]
        let types = identifiers.compactMap { UTType($0) }
        // 一个都解析不出来时退回纯文本：空过滤等于什么都不让选
        return types.isEmpty ? [.plainText] : types
    }()
}
