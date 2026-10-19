import AppKit

/// 只认文件拖放的容器视图 —— 空窗口时的拖放落点就是它。
final class DropTargetView: NSView, MarkdownDropReceiver {

    var onDropFiles: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForMarkdownDrops()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("只走代码路径") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        markdownDropEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        performMarkdownDrop(sender)
    }
}
