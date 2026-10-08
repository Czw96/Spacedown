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

        updateLabelColor()
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
        closeButton.isHidden = !value
    }

    func setTitle(_ title: String) {
        label.stringValue = title
    }

    private func updateLabelColor() {
        label.textColor = isCurrent ? .labelColor : .secondaryLabelColor
    }

    @objc private func closeTapped() {
        onClose?(index)
    }
}

/// 标签栏。38px 高，交通灯与标签同一行，右侧是缩放三件套 + 两个动作。
///
/// 材质是 `NSVisualEffectView(.windowBackground)`，**不要自己画毛玻璃**（§5.3）。
@MainActor
final class TabBarView: NSView {

    /// 与 `MainWindow` 的窗口高度对齐
    static let height: CGFloat = 38
    /// 交通灯占位：三个按钮 + 左右留白
    static let leadingInset: CGFloat = 78
    /// 右侧操作区宽度
    static let trailingInset: CGFloat = 190
    static let maxTabWidth: CGFloat = 180
    static let minTabWidth: CGFloat = 92
    private static let tabSpacing: CGFloat = 2

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomReset: (() -> Void)?
    var onRevealInFinder: (() -> Void)?
    var onOpenInEditor: (() -> Void)?
    /// 右键菜单由 controller 提供（菜单内容依赖当前标签）
    var contextMenuProvider: ((Int) -> NSMenu?)?

    private var items: [TabItemView] = []
    private let newTabButton: NSButton
    private let zoomOutButton: NSButton
    private let zoomInButton: NSButton
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let revealButton: NSButton
    private let editorButton: NSButton

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        newTabButton = Self.symbolButton("plus", "新建标签", 11)
        zoomOutButton = Self.symbolButton("minus", "缩小", 11)
        zoomInButton = Self.symbolButton("plus", "放大", 11)
        revealButton = Self.symbolButton("folder", "在 Finder 中显示", 12)
        editorButton = Self.symbolButton("arrow.up.forward.app", "用默认编辑器打开", 12)
        super.init(frame: frameRect)

        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.textColor = .secondaryLabelColor
        zoomLabel.alignment = .center
        zoomLabel.usesSingleLineMode = true

        for view in [newTabButton, zoomOutButton, zoomInButton, zoomLabel, revealButton, editorButton] {
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
                addSubview(item)
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

    // MARK: - 布局

    override func layout() {
        super.layout()

        let layoutRight = bounds.width - 14
        editorButton.frame = NSRect(x: layoutRight - 22, y: 8, width: 22, height: 22)
        revealButton.frame = NSRect(x: editorButton.frame.minX - 6 - 22, y: 8, width: 22, height: 22)
        zoomInButton.frame = NSRect(x: revealButton.frame.minX - 16 - 22, y: 8, width: 22, height: 22)
        zoomLabel.frame = NSRect(x: zoomInButton.frame.minX - 4 - 46, y: 9, width: 46, height: 18)
        zoomOutButton.frame = NSRect(x: zoomLabel.frame.minX - 4 - 22, y: 8, width: 22, height: 22)

        let tabsStart = Self.leadingInset
        let tabsEnd = zoomOutButton.frame.minX - 12
        let available = max(0, tabsEnd - tabsStart)
        guard !items.isEmpty else {
            newTabButton.frame = NSRect(x: tabsStart, y: 8, width: 22, height: 22)
            return
        }

        let spacingTotal = Self.tabSpacing * CGFloat(items.count - 1)
        let width = min(
            Self.maxTabWidth,
            max(Self.minTabWidth, (available - spacingTotal) / CGFloat(items.count)))

        var x = tabsStart
        for item in items {
            item.frame = NSRect(x: x, y: 4, width: width, height: TabItemView.height)
            x += width + Self.tabSpacing
        }
        newTabButton.frame = NSRect(x: x + 4, y: 8, width: 22, height: 22)
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
        let point = convert(event.locationInWindow, from: nil)
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
        revealButton.target = self
        revealButton.action = #selector(revealTapped)
        editorButton.target = self
        editorButton.action = #selector(editorTapped)

        let reset = NSClickGestureRecognizer(target: self, action: #selector(zoomResetTapped))
        zoomLabel.addGestureRecognizer(reset)
    }

    @objc private func newTabTapped() { onNewTab?() }
    @objc private func zoomInTapped() { onZoomIn?() }
    @objc private func zoomOutTapped() { onZoomOut?() }
    @objc private func zoomResetTapped() { onZoomReset?() }
    @objc private func revealTapped() { onRevealInFinder?() }
    @objc private func editorTapped() { onOpenInEditor?() }

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
