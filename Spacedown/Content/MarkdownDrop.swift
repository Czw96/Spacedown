import AppKit

/// 接受 markdown 文件拖放的视图共用的行为。
///
/// 拖放落点有两处（空窗口的内容宿主、以及有内容时的 web view 本身），
/// 判定与解析只写一次，免得两处白名单各自漂移。
protocol MarkdownDropReceiver: NSView {
    var onDropFiles: (([URL]) -> Void)? { get set }
}

extension MarkdownDropReceiver {

    /// 只认文件 URL；扩展名白名单由 `MarkdownFileType` 统一持有。
    func markdownURLs(from sender: NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return objects.filter(MarkdownFileType.isSupported)
    }

    func registerForMarkdownDrops() {
        registerForDraggedTypes([.fileURL])
    }

    func markdownDropEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        markdownURLs(from: sender).isEmpty ? [] : .copy
    }

    func performMarkdownDrop(_ sender: NSDraggingInfo) -> Bool {
        let urls = markdownURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }
}
