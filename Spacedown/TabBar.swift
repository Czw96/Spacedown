import AppKit

/// 单个标签。视觉规范见 docs/技术方案.md §5.3。
///
/// - 当前标签：底色微抬 + 顶部 2px 强调色条（**不用边框把标签框起来**）
/// - 关闭按钮 hover 才出现
/// - 动效 100ms，不用弹性动画
@MainActor
final class TabItemView: NSView {

    static let height: CGFloat = 30

    let index: Int
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    var isCurrent = false {
        didSet {
            guard isCurrent != oldValue else { return }
            needsDisplay = true
            updateLabelColor()
            updateCloseButtonVisibility()
        }
    }

    private var hovered = false
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    init(index: Int, title: String) {
        self.index = index
        super.init(frame: .zero)

        label.stringValue = title
        label.font = .systemFont(ofSize: 12, weight: .medium)
        // 过长中间截断（§5.3）
        label.lineBreakMode = .byTruncatingMiddle
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")
            ?? NSImage()
        closeButton.image = closeButton.image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isHidden = true
        addSubview(closeButton)

        // 无障碍：标签在 VoiceOver 里应当是一个可点选的按钮，而不是一坨静态文字
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)

        updateLabelColor()
        updateCloseButtonVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("只走代码路径") }

    override func layout() {
        super.layout()
        let closeSize: CGFloat = 16
        let inset: CGFloat = 8
        let labelRight = bounds.width - inset - closeSize - 2
        label.frame = NSRect(
            x: inset + 2, y: (bounds.height - 16) / 2,
            width: max(0, labelRight - inset - 2), height: 16)
        closeButton.frame = NSRect(
            x: bounds.width - inset - closeSize, y: (bounds.height - closeSize) / 2,
            width: closeSize, height: closeSize)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func mouseDown(with event: NSEvent) {
        // 不在这里 performDrag：那会把一次普通点击也变成"等鼠标抬起"，
        // 拖窗口交给标签栏空白区。
        onSelect?(index)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 6
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 0), xRadius: radius, yRadius: radius)

        if isCurrent {
            Palette.currentTabFill.setFill()
            path.fill()
        } else if hovered {
            Palette.hoverTabFill.setFill()
            path.fill()
        }

        if isCurrent {
            // 顶部 2px 强调色条
            let bar = NSBezierPath(
                roundedRect: NSRect(x: 0, y: 0, width: bounds.width, height: 2),
                xRadius: 1, yRadius: 1)
            Palette.accent.setFill()
            bar.fill()
        }
    }

    private func setHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value
        needsDisplay = true
        updateCloseButtonVisibility()
    }

    /// 当前标签的关闭按钮**常驻**，其余标签 hover 才出现。
    ///
    /// 原来是"一律 hover 才出现"——但当前标签恰恰是最可能被关的那个，
    /// 让用户先悬停再找一个小叉是多余的一步。macOS / Chrome 都是常驻。
    private func updateCloseButtonVisibility() {
        closeButton.isHidden = !(hovered || isCurrent)
    }

    func setTitle(_ title: String) {
        label.stringValue = title
        setAccessibilityLabel(title)
    }

    private func updateLabelColor() {
        label.textColor = isCurrent ? .labelColor : .secondaryLabelColor
    }

    @objc private func closeTapped() {
        onClose?(index)
    }
}

/// 标签栏。38px 高，交通灯与标签同一行，右侧是缩放三件套。
///
/// 材质是 `NSVisualEffectView(.windowBackground)`，**不要自己画毛玻璃**（§5.3）。
///
/// 「在 Finder 中显示」「用默认编辑器打开」两个按钮已从标签栏移除（2026-10-10）——
/// 它们不是高频动作，占着一整格工具栏不划算。**功能本身没删**，仍在「文件」菜单里
/// （⌘⇧R / ⌥⌘E）。
///
/// **版心宽度不放这里**（2026-10-11 试过又撤了）：工具栏一旦并排放两组 `− x +`，
/// 视觉噪声明显大于收益，用户也明确要求回「显示」菜单。它现在只在
/// 「显示 → 版心宽度」里（带 ⌥⌘= / ⌥⌘− / ⌥⌘0 快捷键，菜单里显示当前值）。
@MainActor
final class TabBarView: NSView {

    /// 与 `MainWindow` 的窗口高度对齐
    static let height: CGFloat = 38
    /// 交通灯占位：三个按钮 + 左右留白
    static let leadingInset: CGFloat = 78
    static let maxTabWidth: CGFloat = 180
    /// 标签宽度下限。**这是"能读"的下限，不是排版下限** ——
    /// 数量再多也不会继续压缩，超出部分由 `tabsContainer` 裁掉，
    /// 而不是让标签压到右侧的缩放/动作按钮上去。
    static let minTabWidth: CGFloat = 62
    private static let tabSpacing: CGFloat = 2
    /// 标签条与右侧操作区之间的最小留白
    private static let stripGap: CGFloat = 10
    /// 缩放按钮的方框边长（正方形，垂直居中于标签栏）
    private static let zoomBoxSide: CGFloat = 22
    /// 百分比数字那一格的宽度
    private static let zoomLabelWidth: CGFloat = 46
    /// 缩放数字的字体。**排版要用它反推位置**（见 `zoomLabelFrame`），
    /// 所以字号只能从这里改 —— 改 init 里的字体而漏掉这里，数字就会重新错位。
    private static let zoomFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomReset: (() -> Void)?
    /// 右键菜单由 controller 提供（菜单内容依赖当前标签）
    var contextMenuProvider: ((Int) -> NSMenu?)?

    private var items: [TabItemView] = []
    /// 标签专用容器。**存在的唯一理由是裁剪**：标签数量超过可用宽度时，
    /// 超出部分要被切掉，而不是盖到右侧按钮上（`TabItemView` 是后加的子视图，
    /// 不裁的话它天然压在按钮之上）。
    private let tabsContainer = TabStripView()
    private let groupSeparator = SeparatorView()
    private let newTabButton: NSButton
    private let zoomOutButton: NSButton
    private let zoomInButton: NSButton
    private let zoomLabel = NSTextField(labelWithString: "100%")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        newTabButton = Self.symbolButton("plus", "新建标签", 11)
        zoomOutButton = Self.symbolButton("minus", "缩小（⌘-）", 11)
        zoomInButton = Self.symbolButton("plus", "放大（⌘+）", 11)
        super.init(frame: frameRect)

        zoomLabel.font = Self.zoomFont
        zoomLabel.textColor = .secondaryLabelColor
        zoomLabel.alignment = .center
        zoomLabel.usesSingleLineMode = true
        zoomLabel.toolTip = "点击回到 100%（⌘0）"

        // ⚠️ 顺序即图层：容器必须先加，右侧那组按钮后加才会压在标签之上（本来就该如此）
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
    /// 数字那一项报的是**数字墨迹的中线**（cap 高中线），不是它那个框的中线 ——
    /// 框中线跟按钮对不上是**正常**的（见 `zoomLabelFrame`），要对齐的正是这个数。
    /// 三者应当相等；不等就说明布局没跑到、或者位置被谁改回去了。
    /// （本机 `screencapture` 被 TCC 挡住，这类"差了几个 pt"的问题只能靠数字确认。）
    var debugZoomCentersFromTop: [(name: String, fromTop: CGFloat)]? {
        guard let win = window else { return nil }
        let height = win.frame.height
        func centerFromTop(_ view: NSView) -> CGFloat {
            height - view.convert(view.bounds, to: nil).midY
        }
        // 框顶往下 capMidToTop 处才是数字的墨迹中线
        let capMidToTop = Self.zoomFont.ascender - Self.zoomFont.capHeight / 2
        let labelRect = zoomLabel.convert(zoomLabel.bounds, to: nil)
        return [("zoom−", centerFromTop(zoomOutButton)),
                ("zoomLabel(cap 中线)", height - (labelRect.maxY - capMidToTop)),
                ("zoom+", centerFromTop(zoomInButton))]
    }

    /// 缩放那格数字的框。
    ///
    /// ⚠️ **不能把它的框跟两边的按钮框对齐。** `NSTextField` 的文字是**贴着框顶**排的
    /// （实测：墨迹顶 = 框顶 + `ascender` − `capHeight`），而按钮里的 SF Symbol 是在
    /// 22pt 的方框里垂直居中的。两者框一对齐，数字反而会比 `−` / `+` **高约 4pt**。
    ///
    /// 所以这里反过来算：让**数字的 cap 高中线**落在按钮方框的中线上。
    /// 数字（表格数字）没有下伸部，墨迹就是 cap 高那一块，这样对齐才是光学校正的 ——
    /// 与 `60%` / `500%` 这种位数变化也无关，cap 高是常量。
    ///
    /// 实测（离屏渲染同尺寸工具栏后按像素量墨迹中线，方法见 `docs/修复记录`）：
    ///
    /// | 写法 | 数字相对 `+` 的墨迹中线偏差 |
    /// |---|---|
    /// | 旧：写死 `y: 9`、高 18 | 高 **2.75pt**（就是看到的那条错位） |
    /// | 直接把 label 框对齐按钮框 | 高 **3.75pt**（更糟，这个直觉是错的） |
    /// | **本式** | **0.5pt 以内**（纯栅格化残差） |
    ///
    /// 定标：把同一个式子放大到 40pt 渲染，"cap 中线"设定 100.00，实测墨迹 85.50–114.50
    /// → 中线正好 100.00，说明式子本身是准的、不是凑出来的数。
    private static func alignedLabelFrame(x: CGFloat, centerY: CGFloat) -> NSRect {
        // 从「cap 高中线」反推「框顶」：框顶 = 中线 − (ascender − capHeight/2)
        let capMidToTop = zoomFont.ascender - zoomFont.capHeight / 2
        return NSRect(x: x, y: centerY - capMidToTop,
                      width: zoomLabelWidth, height: zoomBoxSide)
    }

    // MARK: - 布局

    override func layout() {
        super.layout()

        // 右侧只有缩放三件套，贴着窗口右缘排。
        let layoutRight = bounds.width - 14
        let box = NSRect(x: layoutRight - Self.zoomBoxSide, y: 8,
                         width: Self.zoomBoxSide, height: Self.zoomBoxSide)
        zoomInButton.frame = box
        // ⚠️ 中间那格的位置由 `alignedLabelFrame` 算，**不要**顺手写成跟 box 同一个 y —— 见那个方法的注释
        let zoomLabelX = box.minX - 4 - Self.zoomLabelWidth
        zoomLabel.frame = Self.alignedLabelFrame(x: zoomLabelX, centerY: box.midY)
        zoomOutButton.frame = NSRect(x: zoomLabelX - 4 - Self.zoomBoxSide, y: box.minY,
                                     width: box.width, height: box.height)

        // 分组分隔：把"标签区 / 缩放区"两件事在视觉上切开，
        // 否则左边新建标签的 `+` 和右边放大的 `+` 看着像同一组
        groupSeparator.frame = NSRect(x: zoomOutButton.frame.minX - Self.stripGap - 1,
                                      y: 10, width: 1, height: bounds.height - 20)

        let tabsStart = Self.leadingInset
        let tabsEnd = groupSeparator.frame.minX - Self.stripGap
        let available = max(0, tabsEnd - tabsStart)

        // 容器就是标签的裁剪框：落在它外面的标签被切掉，不会盖住右侧控件
        tabsContainer.frame = NSRect(x: tabsStart, y: 0, width: available, height: bounds.height)

        // ⚠️ 容器内的坐标是**相对容器**的，所以这里 x 从 0 起算
        guard !items.isEmpty else {
            newTabButton.frame = NSRect(x: tabsStart, y: 8, width: 22, height: 22)
            return
        }

        let spacingTotal = Self.tabSpacing * CGFloat(items.count - 1)
        let width = min(
            Self.maxTabWidth,
            max(Self.minTabWidth, (available - spacingTotal) / CGFloat(items.count)))

        var x: CGFloat = 0
        for item in items {
            item.frame = NSRect(x: x, y: 4, width: width, height: TabItemView.height)
            x += width + Self.tabSpacing
        }

        // `+` 跟着最后一个标签走；标签多到铺满时钉在标签区右缘。
        // （钉住而不是推到控件底下：宁可让它压在最后一个标签上，也不能把右侧操作区顶掉）
        let newTabX = min(tabsStart + x + 4, tabsEnd - 22)
        newTabButton.frame = NSRect(x: newTabX, y: 8, width: 22, height: 22)
    }

    // MARK: - 空白区交互

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onNewTab?()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // ⚠️ 命中测试必须在**容器坐标系**里做：标签现在是 `tabsContainer` 的子视图，
        // 它们的 `frame` 是相对容器的。顺便也因此不会右键到被裁掉的那几个。
        let point = tabsContainer.convert(event.locationInWindow, from: nil)
        guard let index = items.firstIndex(where: { $0.frame.contains(point) }),
              let menu = contextMenuProvider?(index) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - 内部

    private func wireActions() {
        newTabButton.target = self
        newTabButton.action = #selector(newTabTapped)
        zoomInButton.target = self
        zoomInButton.action = #selector(zoomInTapped)
        zoomOutButton.target = self
        zoomOutButton.action = #selector(zoomOutTapped)

        let resetZoom = NSClickGestureRecognizer(target: self, action: #selector(zoomResetTapped))
        zoomLabel.addGestureRecognizer(resetZoom)
    }

    @objc private func newTabTapped() { onNewTab?() }
    @objc private func zoomInTapped() { onZoomIn?() }
    @objc private func zoomOutTapped() { onZoomOut?() }
    @objc private func zoomResetTapped() { onZoomReset?() }

    private static func symbolButton(_ name: String, _ description: String, _ pointSize: CGFloat) -> NSButton {
        let button = NSButton()
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        button.image = image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = description
        return button
    }
}

/// 标签条容器：超出自身范围的部分既**不画**也**不接鼠标**。
///
/// 为什么不能只靠 `layer.masksToBounds`：那只管绘制。AppKit 的 `hitTest` 是按
/// `frame` 判定的，被裁掉的标签照样能点中 —— 表现就是"点右边空白处，跳到了一个看不见的标签"。
/// 所以这里把命中测试也一起收进 bounds。
final class TabStripView: NSView {

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `hitTest(_:)` 收到的是**父视图坐标系**里的点
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return super.hitTest(point)
    }
}

/// 1pt 宽的竖分隔线。
///
/// 用自绘而不是设一次 `layer.backgroundColor`：`NSColor.separatorColor` 是动态色，
/// 存成 CGColor 之后就冻在切换主题前的那一刻了；在 `draw` 里取色则每次都跟着系统走。
final class SeparatorView: NSView {

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 2, width: 1, height: max(0, bounds.height - 4)).fill()
    }
}
