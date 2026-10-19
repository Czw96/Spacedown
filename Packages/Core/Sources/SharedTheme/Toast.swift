import AppKit

/// 内容区上/下方短暂显示的一条提示（"已复制链接"这类轻反馈）。
///
/// 用原生视图绘制而不是往页面里注入 DOM：提示不该走渲染引擎，`NSTextField` 直接上屏，
/// 路径更短，也不受页面 CSP 影响。
@MainActor
public enum Toast {

    public enum Placement {
        /// 距宿主视图顶部的距离。
        case top(inset: CGFloat)
        /// 距宿主视图底部的距离。
        case bottom(inset: CGFloat)
    }

    private static let identifierName = "spacedown.toast"
    private static let displayDuration: TimeInterval = 1.7
    private static let fadeDuration: TimeInterval = 0.22

    /// 在 `host` 上显示一条提示，替换掉同一宿主上还没消失的那条。
    public static func show(_ text: String, in host: NSView, placement: Placement = .bottom(inset: 20)) {
        let identifier = NSUserInterfaceItemIdentifier(identifierName)
        host.subviews.filter { $0.identifier == identifier }.forEach { $0.removeFromSuperview() }

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.sizeToFit()

        let padding = NSSize(width: 13, height: 7)
        let box = ToastBox(frame: NSRect(
            x: 0, y: 0,
            width: label.frame.width + padding.width * 2,
            height: label.frame.height + padding.height * 2
        ))
        box.identifier = identifier
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        box.layer?.cornerRadius = 8

        label.frame.origin = NSPoint(x: padding.width, y: padding.height)
        box.addSubview(label)

        switch placement {
        case .top(let inset):
            box.frame.origin = NSPoint(x: (host.bounds.width - box.frame.width) / 2,
                                       y: host.bounds.height - box.frame.height - inset)
            box.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        case .bottom(let inset):
            box.frame.origin = NSPoint(x: (host.bounds.width - box.frame.width) / 2, y: inset)
            box.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        }
        host.addSubview(box)

        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeDuration
                box.animator().alphaValue = 0
            } completionHandler: {
                DispatchQueue.main.async { box.removeFromSuperview() }
            }
        }
    }

    /// 只负责显示，不参与命中测试 —— 否则它会挡住底下 web view 的点击。
    private final class ToastBox: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
