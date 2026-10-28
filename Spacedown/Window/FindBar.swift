import AppKit

/// 内容卡片右上角浮出来的查找条。
///
/// 为什么自己做而不是用 `NSTextFinder`：后者的界面要求调用方实现
/// `NSTextFinderBarContainer`（自己造 find bar 视图再交给它），而 `WKWebView`
/// 只提供 `find(_:configuration:completionHandler:)`，两边接起来并不比自己画省事，
/// 反而多一层不属于我们的状态。
///
/// 与主窗口其余部分一样：纯代码、无 nib、跟随系统明暗。
@MainActor
final class FindBar: NSVisualEffectView, NSSearchFieldDelegate {

    /// 输入变化（逐字触发，等同 Safari 的「边输边找」）。
    var onQueryChange: ((String) -> Void)?
    /// ↩ / 下箭头。
    var onNext: (() -> Void)?
    /// ⇧↩ / 上箭头。
    var onPrevious: (() -> Void)?
    /// Esc / 关闭按钮。
    var onClose: (() -> Void)?

    private let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    var query: String { field.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        isHidden = true

        field.placeholderString = "查找"
        field.controlSize = .small
        field.font = .systemFont(ofSize: 12.5)
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 190).isActive = true

        status.font = .systemFont(ofSize: 11.5)
        status.textColor = .secondaryLabelColor
        // 固定宽度 + 只换文字：出现「无结果」时不能把右边的按钮推走
        status.widthAnchor.constraint(equalToConstant: 46).isActive = true

        configure(previousButton, symbol: "chevron.up", label: "上一个")
        configure(nextButton, symbol: "chevron.down", label: "下一个")
        configure(closeButton, symbol: "xmark", label: "关闭查找")
        previousButton.target = self
        previousButton.action = #selector(previous(_:))
        nextButton.target = self
        nextButton.action = #selector(next(_:))
        closeButton.target = self
        closeButton.action = #selector(close(_:))

        let stack = NSStackView(views: [field, status, previousButton, nextButton, closeButton])
        stack.orientation = .horizontal
        // 基线对齐会让搜索框与图标按钮错位，居中更稳
        stack.alignment = .centerY
        stack.spacing = 4
        stack.setCustomSpacing(2, after: previousButton)
        stack.setCustomSpacing(6, after: nextButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("只走代码路径") }

    // MARK: - 对外

    /// 显示并接管键盘焦点。
    func present(in host: NSView) {
        if superview !== host {
            translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(self)
            NSLayoutConstraint.activate([
                topAnchor.constraint(equalTo: host.topAnchor, constant: 10),
                trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -10),
            ])
        }
        isHidden = false
        alphaValue = 1
        window?.makeFirstResponder(field)
        // 上一次的查询词整段选中：接着按 ⌘F 的本意通常是"换个词再找"
        field.currentEditor()?.selectAll(nil)
    }

    /// 收起，并把焦点还给内容区（由调用方决定给谁）。
    func dismiss() {
        guard !isHidden else { return }
        isHidden = true
        status.stringValue = ""
    }

    /// `nil` 表示"找到了"；给字符串就是在状态区显示它。
    func showStatus(_ text: String?) {
        status.stringValue = text ?? ""
    }

    // MARK: - 内部

    private func configure(_ button: NSButton, symbol: String, label: String) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 20),
            button.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        showStatus(nil)
        onQueryChange?(field.stringValue)
    }

    /// 搜索框里没有输入法候选时，这些键先到这里 —— 比在 `keyDown` 里抢事件规矩。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            // ⇧↩ 是"上一个"，与 Safari 一致
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onPrevious?()
            } else {
                onNext?()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    // MARK: - 动作

    @objc private func previous(_ sender: Any?) { onPrevious?() }
    @objc private func next(_ sender: Any?) { onNext?() }
    @objc private func close(_ sender: Any?) { onClose?() }
}
