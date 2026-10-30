import AppKit

/// 标签栏：左侧交通灯占位，中间标签，右侧缩放三件套。
@MainActor
final class TabBarView: NSView {

    /// 与主窗口的标题栏同一行。
    static let height: CGFloat = 38
    /// 交通灯占位：三个按钮 + 左右留白。
    static let leadingInset: CGFloat = 78
    static let maxTabWidth: CGFloat = 180
    /// 标签宽度下限。数量再多也不会继续压缩，超出部分由容器裁掉。
    static let minTabWidth: CGFloat = 62

    private static let tabSpacing: CGFloat = 2
    /// 标签条与右侧操作区之间的最小留白。
    private static let stripGap: CGFloat = 10
    /// 缩放按钮的方框边长（正方形，垂直居中）。
    private static let zoomBoxSide: CGFloat = 22
    /// 「新建标签」按钮的方框边长，与缩放按钮同规格。
    private static let newTabSide: CGFloat = 22
    /// 右侧操作区距窗口右缘的留白。
    private static let trailingInset: CGFloat = 14
    private static let zoomLabelWidth: CGFloat = 46
    /// 缩放数字的字体。排版要用它反推位置（见 `alignedLabelFrame`），
    /// 所以字号只能从这里改。
    private static let zoomFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomReset: (() -> Void)?
    /// 右键菜单由控制器提供（内容依赖被点中的标签）。
    var contextMenuProvider: ((Int) -> NSMenu?)?

    private var items: [TabItemView] = []

    /// 标签专用容器。存在的唯一理由是裁剪：标签数量超过可用宽度时，
    /// 超出部分要被切掉，而不是盖到右侧按钮上。
    private let tabsContainer = TabStripView()
    private let groupSeparator = SeparatorView()
    private let newTabButton = TabBarView.symbolButton("plus", "新建标签", pointSize: 11)
    private let zoomOutButton = TabBarView.symbolButton("minus", "缩小（⌘-）", pointSize: 11)
    private let zoomInButton = TabBarView.symbolButton("plus", "放大（⌘+）", pointSize: 11)
    private let zoomLabel = NSTextField(labelWithString: "100%")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        zoomLabel.font = Self.zoomFont
        zoomLabel.textColor = .secondaryLabelColor
        zoomLabel.alignment = .center
        zoomLabel.usesSingleLineMode = true
        zoomLabel.toolTip = "点击回到 100%（⌘0）"

        // 顺序即图层：容器先加，右侧按钮后加才会压在标签之上
        tabsContainer.wantsLayer = true
        tabsContainer.layer?.masksToBounds = true
        addSubview(tabsContainer)

        for view in [newTabButton, groupSeparator, zoomOutButton, zoomInButton, zoomLabel] {
            addSubview(view)
        }

        wireActions()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("只走代码路径") }

    // MARK: - 对外

    func reload(titles: [String], current: Int) {
        if items.count != titles.count {
            for item in items { item.removeFromSuperview() }
            items = titles.enumerated().map { index, title in
                let item = TabItemView(index: index, title: title)
                item.onSelect = { [weak self] index in self?.onSelect?(index) }
                item.onClose = { [weak self] index in self?.onClose?(index) }
                tabsContainer.addSubview(item)
                return item
            }
        } else {
            for (index, title) in titles.enumerated() {
                items[index].setTitle(title)
            }
        }
        for (index, item) in items.enumerated() {
            item.isCurrent = (index == current)
        }
        needsLayout = true
    }

    func setZoomPercent(_ percent: Int) {
        zoomLabel.stringValue = "\(percent)%"
    }

    /// 布局自检用：第一个标签在窗口坐标系里的位置。
    var debugFirstTabFrame: NSRect? {
        guard let first = items.first else { return nil }
        return first.convert(first.bounds, to: nil)
    }

    /// 布局自检用：缩放三件套各自的**可见中线**离窗口顶有多远。
    ///
    /// 数字那一项报的是数字墨迹的中线（cap 高中线），不是它那个框的中线 ——
    /// 框中线跟按钮对不上是正常的（见 `alignedLabelFrame`），要对齐的正是这个数。
    /// 三者应当相等；不等就说明布局没跑到，或者位置被谁改回去了。
    var debugZoomCentersFromTop: [(name: String, fromTop: CGFloat)]? {
        guard let window else { return nil }
        let height = window.frame.height

        func centerFromTop(_ view: NSView) -> CGFloat {
            height - view.convert(view.bounds, to: nil).midY
        }
        let capMidToTop = Self.zoomFont.ascender - Self.zoomFont.capHeight / 2
        let labelRect = zoomLabel.convert(zoomLabel.bounds, to: nil)
        return [("zoom−", centerFromTop(zoomOutButton)),
                ("zoomLabel(cap 中线)", height - (labelRect.maxY - capMidToTop)),
                ("zoom+", centerFromTop(zoomInButton))]
    }

    // MARK: - 布局

    override func layout() {
        super.layout()

        let layoutRight = bounds.width - Self.trailingInset
        let zoomInFrame = NSRect(x: layoutRight - Self.zoomBoxSide, y: 8,
                                 width: Self.zoomBoxSide, height: Self.zoomBoxSide)
        zoomInButton.frame = zoomInFrame

        let zoomLabelX = zoomInFrame.minX - 4 - Self.zoomLabelWidth
        zoomLabel.frame = Self.alignedLabelFrame(x: zoomLabelX, centerY: zoomInFrame.midY)
        zoomOutButton.frame = NSRect(x: zoomLabelX - 4 - Self.zoomBoxSide,
                                     y: zoomInFrame.minY,
                                     width: zoomInFrame.width, height: zoomInFrame.height)

        // 分组分隔：把"标签区 / 缩放区"在视觉上切开，
        // 否则左边新建标签的 `+` 和右边放大的 `+` 看着像同一组
        groupSeparator.frame = NSRect(x: zoomOutButton.frame.minX - Self.stripGap - 1,
                                      y: 10, width: 1, height: bounds.height - 20)

        let tabsStart = Self.leadingInset
        let tabsEnd = groupSeparator.frame.minX - Self.stripGap
        let available = max(0, tabsEnd - tabsStart)

        // 容器就是标签的裁剪框：落在它外面的标签被切掉，不会盖住右侧控件
        tabsContainer.frame = NSRect(x: tabsStart, y: 0, width: available, height: bounds.height)

        // 容器内的坐标是相对容器的，所以这里 x 从 0 起算
        guard !items.isEmpty else {
            newTabButton.frame = Self.newTabFrame(x: tabsStart, y: 8)
            return
        }

        let spacingTotal = Self.tabSpacing * CGFloat(items.count - 1)
        let width = min(Self.maxTabWidth,
                        max(Self.minTabWidth, (available - spacingTotal) / CGFloat(items.count)))

        var x: CGFloat = 0
        for item in items {
            item.frame = NSRect(x: x, y: 4, width: width, height: TabItemView.height)
            x += width + Self.tabSpacing
        }

        // `+` 跟着最后一个标签走；标签铺满时钉在标签区右缘 ——
        // 宁可压住最后一个标签，也不能把右侧操作区顶掉
        newTabButton.frame = Self.newTabFrame(x: min(tabsStart + x + 4, tabsEnd - Self.newTabSide),
                                              y: 8)
    }

    // MARK: - 交互

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onNewTab?()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // 命中测试必须在容器坐标系里做：标签是 `tabsContainer` 的子视图，
        // 这样也自然排除了被裁掉的那几个
        let point = tabsContainer.convert(event.locationInWindow, from: nil)
        guard let index = items.firstIndex(where: { $0.frame.contains(point) }),
              let menu = contextMenuProvider?(index) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - 内部

    /// 缩放数字那一格的框。
    ///
    /// 不能把它的框跟两边的按钮框对齐：`NSTextField` 的文字贴着框顶排
    /// （墨迹顶 = 框顶 + `ascender` − `capHeight`），而按钮里的 SF Symbol 是在
    /// 方框里垂直居中的。两者框一对齐，数字会比 `−` / `+` 高约 4pt。
    ///
    /// 所以反过来算：让数字的 cap 高中线落在按钮方框的中线上。数字没有下伸部，
    /// 墨迹就是 cap 那一块，这样与位数变化无关。
    private static func alignedLabelFrame(x: CGFloat, centerY: CGFloat) -> NSRect {
        let capMidToTop = zoomFont.ascender - zoomFont.capHeight / 2
        return NSRect(x: x, y: centerY - capMidToTop, width: zoomLabelWidth, height: zoomBoxSide)
    }

    private func wireActions() {
        newTabButton.target = self
        newTabButton.action = #selector(newTabTapped)
        zoomInButton.target = self
        zoomInButton.action = #selector(zoomInTapped)
        zoomOutButton.target = self
        zoomOutButton.action = #selector(zoomOutTapped)

        zoomLabel.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(zoomResetTapped))
        )
    }

    @objc private func newTabTapped() { onNewTab?() }
    @objc private func zoomInTapped() { onZoomIn?() }
    @objc private func zoomOutTapped() { onZoomOut?() }
    @objc private func zoomResetTapped() { onZoomReset?() }

    private static func newTabFrame(x: CGFloat, y: CGFloat) -> NSRect {
        NSRect(x: x, y: y, width: newTabSide, height: newTabSide)
    }

    private static func symbolButton(_ name: String, _ description: String, pointSize: CGFloat) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = description
        return button
    }
}

/// 标签条容器：超出自身范围的部分既不画也不接鼠标。
///
/// 只靠 `layer.masksToBounds` 不够 —— 那只管绘制，`hitTest` 仍按 frame 判定，
/// 被裁掉的标签照样能点中。
final class TabStripView: NSView {

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `hitTest(_:)` 收到的是父视图坐标系里的点
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return super.hitTest(point)
    }
}

/// 1pt 宽的竖分隔线。
///
/// 自绘而不是设一次 `layer.backgroundColor`：`NSColor.separatorColor` 是动态色，
/// 存成 CGColor 就冻在切换主题前的那一刻了。
final class SeparatorView: NSView {

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 2, width: 1, height: max(0, bounds.height - 4)).fill()
    }
}
