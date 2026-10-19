import WebKit

/// 主 App 用的 `WKWebView`：加这一层壳只为拦下文件拖放。
///
/// `WKWebView` 对文件拖放有默认行为（直接导航过去，把渲染结果换成裸文本），
/// 而我们要的是"拖进来 = 开一个新标签"。
final class SpacedownWebView: WKWebView, MarkdownDropReceiver {

    var onDropFiles: (([URL]) -> Void)?

    override init(frame: NSRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
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
