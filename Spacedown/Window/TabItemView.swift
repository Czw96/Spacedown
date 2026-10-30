import AppKit

import SharedTheme

/// 单个标签。
///
/// 当前标签靠底色微抬表达（`Palette.currentTabFill`），不画边框或强调色条；
/// 关闭按钮在悬停或成为当前标签时出现。
@MainActor
final class TabItemView: NSView {

    static let height: CGFloat = 30

    private static let closeButtonSize: CGFloat = 16
    /// 标题行高。比标签高度小一圈，垂直居中后上下各留一点呼吸。
    private static let labelHeight: CGFloat = 16
    private static let horizontalInset: CGFloat = 8

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
        // 尾部截断：中段截断会把文件名切成 `Spacedow…接测试.md`，很难读
        label.lineBreakMode = .byTruncatingTail
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

        // 无障碍：标签在 VoiceOver 里应当是一个可点选的按钮
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)

        updateLabelColor()
        updateCloseButtonVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("只走代码路径") }

    override func layout() {
        super.layout()
        let closeSize = Self.closeButtonSize
        let inset = Self.horizontalInset
        let labelLeft = inset + 2
        let labelRight = bounds.width - inset - closeSize - 2

        label.frame = NSRect(x: labelLeft, y: (bounds.height - Self.labelHeight) / 2,
                             width: max(0, labelRight - labelLeft), height: Self.labelHeight)
        closeButton.frame = NSRect(x: bounds.width - inset - closeSize,
                                   y: (bounds.height - closeSize) / 2,
                                   width: closeSize, height: closeSize)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
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
        // 拖窗口交给标签栏空白区
        onSelect?(index)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        if isCurrent {
            Palette.currentTabFill.setFill()
            path.fill()
        } else if hovered {
            Palette.hoverTabFill.setFill()
            path.fill()
        }
    }

    func setTitle(_ title: String) {
        label.stringValue = title
        setAccessibilityLabel(title)
    }

    private func setHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value
        needsDisplay = true
        updateCloseButtonVisibility()
    }

    /// 当前标签的关闭按钮常驻，其余标签悬停才出现 ——
    /// 当前标签恰恰是最可能被关的那个，不该让用户先悬停再找一个小叉。
    private func updateCloseButtonVisibility() {
        closeButton.isHidden = !(hovered || isCurrent)
    }

    private func updateLabelColor() {
        label.textColor = isCurrent ? .labelColor : .secondaryLabelColor
    }

    @objc private func closeTapped() {
        onClose?(index)
    }
}
