import Foundation

/// 读取待渲染的 Markdown，并施加体积上限。
///
/// 上限针对的不是解析（cmark 吞吐很高），而是之后的 WebKit 排版 —— 排版成本大致随
/// HTML 体积线性增长，超大文档会把首帧拖到无法接受。截断因此是唯一有效的缓解手段。
///
/// 截断只有这一处实现：主 App 与 Quick Look 扩展都调它。两头各写一份的话，
/// 同一个文件在两处的显示长度会不一致。
public enum MarkdownDocument {

    /// 单份文档的字节上限。
    public static let defaultMaxBytes = 512 * 1024

    /// 读文件；超过上限时切在前 N 字节的最后一个换行处，并在正文前加一行说明。
    ///
    /// 切在换行上是为了不把某个块结构（表格、代码块）切成半截。
    public static func bytes(contentsOf url: URL, maxBytes: Int = defaultMaxBytes) throws -> Data {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > maxBytes else { return data }

        var body = data.prefix(maxBytes)
        if let lastNewline = body.lastIndex(of: 0x0A) {
            body = body[..<lastNewline]
        }

        var notice = Data("\n\n> 文件过大，已截断显示前 \(maxBytes / 1024) KB\n".utf8)
        notice.append(body)
        return notice
    }
}
