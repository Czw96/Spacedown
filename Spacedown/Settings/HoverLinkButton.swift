import AppKit

/// 悬停时略微加重的文字按钮（用于「卸载…」）。
///
/// 卸载是低频 + 不可逆的动作，按 macOS 惯例应当降权：带边框的按钮会把它和主操作
/// 摆成同级，还容易误点。悬停只从 secondary 提到 label，不变红 —— 红色是"立刻要出事"
/// 的信号，用在这里只是装饰性示警。
final class HoverLinkButton: NSButton {

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.activeInActiveApp`：窗口在前台时才跟踪
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        contentTintColor = .labelColor
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = .secondaryLabelColor
    }
}
