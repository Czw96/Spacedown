import AppKit

/// 更新提示与进度窗。
///
/// 不用 `NSAlert`：系统弹窗的排版是死的，字号与层级没法调，"有新版本 1.0.5 / 当前版本 1.0.4"
/// 只能靠字符串拼；而且下载过程中它没法原地变成进度条 —— 关一个再弹一个，视觉上会闪。
///
/// 所以做成一个面板：同一块区域里，先显示版本对比与两个按钮，点「立即更新」后
/// **原地**把按钮换成进度条。
///
/// 布局要点：按钮行与进度条共用一块**固定高度**的区域（`actionArea`），互相切换时
/// 窗口不改变尺寸 —— 否则状态切换会带一次跳高。
@MainActor
final class UpdatePromptWindow: NSPanel {

    /// 用户点了「立即更新」。
    var onInstall: (() -> Void)?
    /// 用户点了「稍后」/「关闭」。
    var onLater: (() -> Void)?
    /// 下载中途点「取消」。
    var onCancel: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let laterButton = NSButton(title: "稍后", target: nil, action: nil)
    private let updateButton = NSButton(title: "立即更新", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let buttonRow = NSStackView()
    private let progressRow = NSStackView()
    private let actionArea = NSView()
    private let root = NSStackView()

    private static let width: CGFloat = 400
    private static let inset: CGFloat = 20
    /// 顶部比左右多留一点：标题栏被透明化之后，太贴边会显得局促
    private static let topInset: CGFloat = 16
    private static let actionHeight: CGFloat = 30

    init(version: String, currentVersion: String) {
        // `.fullSizeContentView` 让 contentView 铺到标题栏下面。
        // 只用 `.titled` 时内容整体被推下 ~28pt，看起来就是"上面留了一大气白"。
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 180),
                   styleMask: [.titled, .fullSizeContentView],
                   backing: .buffered, defer: false)

        // ⚠️ 程序化创建的窗口必须关掉，否则关窗时多释放一次 → 段错误
        isReleasedWhenClosed = false
        title = "Spacedown 更新"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        hidesOnDeactivate = false
        // 这个面板不需要关闭/缩放按钮：进出都由「稍后 / 关闭」控制
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 44).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 44).isActive = true

        titleLabel.stringValue = "Spacedown \(version)"
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        subtitleLabel.stringValue = "当前 \(currentVersion)"
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        noteLabel.stringValue = "自动下载并验签，完成后会重启。"
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .secondaryLabelColor
        // 失败原因是完整句子（最长两行），必须折行；固定宽之后 label 才知道在哪断
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.maximumNumberOfLines = 3
        noteLabel.preferredMaxLayoutWidth = Self.width - Self.inset * 2

        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let header = NSStackView(views: [icon, text])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        // 进度区：进度条 + 百分比
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true

        cancelButton.title = "取消"
        cancelButton.bezelStyle = .inline
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"

        progressRow.orientation = .horizontal
        progressRow.alignment = .centerY
        progressRow.spacing = 8
        progressRow.addArrangedSubview(progressBar)
        progressRow.addArrangedSubview(statusLabel)
        progressRow.addArrangedSubview(cancelButton)
        progressRow.isHidden = true

        // 按钮行：靠右。用一根弹簧把按钮推到右边，别靠 stack 的 alignment。
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 1).isActive = true
        for button in [laterButton, updateButton] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
        }
        updateButton.keyEquivalent = "\r"
        laterButton.keyEquivalent = "\u{1b}"
        laterButton.target = self
        laterButton.action = #selector(later(_:))
        updateButton.target = self
        updateButton.action = #selector(install(_:))
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.addArrangedSubview(spacer)
        buttonRow.addArrangedSubview(laterButton)
        buttonRow.addArrangedSubview(updateButton)

        for view in [buttonRow, progressRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            actionArea.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: actionArea.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: actionArea.trailingAnchor),
                view.centerYAnchor.constraint(equalTo: actionArea.centerYAnchor),
            ])
        }
        actionArea.heightAnchor.constraint(equalToConstant: Self.actionHeight).isActive = true

        root.setViews([header, noteLabel, actionArea], in: .leading)
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = contentView!
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.inset),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.inset),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.topInset),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.inset),
            actionArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            actionArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        // 宽度靠 stack 的约束链确定不了（它按内容自适应），显式钉住。
        content.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        resizeToFit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("只走代码路径") }

    // MARK: - 对外

    func show() {
        center()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 进入"正在更新"状态：按钮让位给进度条。
    func beginProgress() {
        noteLabel.stringValue = "正在下载…"
        updateButton.title = "立即更新"
        buttonRow.isHidden = true
        progressRow.isHidden = false
        cancelButton.isHidden = false
        updateButton.isHidden = true      // 下载中不显示「立即更新」，避免重复触发
        laterButton.title = "稍后"
        progressBar.isIndeterminate = false
        progressBar.doubleValue = 0
        statusLabel.stringValue = ""
    }

    /// - Parameter fraction: 0…1；`nil` 表示"在忙但量不出来"（验签、解压）。
    func updateProgress(_ fraction: Double?, note: String) {
        noteLabel.stringValue = note
        if let fraction {
            if progressBar.isIndeterminate {
                progressBar.stopAnimation(nil)
                progressBar.isIndeterminate = false
            }
            progressBar.doubleValue = fraction
            statusLabel.stringValue = "\(Int((fraction * 100).rounded()))%"
        } else {
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
            statusLabel.stringValue = ""
            // 验签之后就要动磁盘了，这时候"取消"只会留下半成品，直接收掉
            cancelButton.isHidden = true
        }
    }

    /// 取消后回到初始状态，让用户能再点一次。
    func reset() {
        noteLabel.stringValue = "自动下载并验签，完成后会重启。"
        updateButton.title = "立即更新"
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
        progressBar.doubleValue = 0
        progressRow.isHidden = true
        buttonRow.isHidden = false
        updateButton.isHidden = false
        updateButton.keyEquivalent = "\r"
        laterButton.title = "稍后"
        laterButton.isHidden = false
    }

    /// 失败：原地显示原因 + 「前往下载」，不另开一个弹窗。
    func showFailure(_ message: String) {
        noteLabel.stringValue = message
        progressRow.isHidden = true
        buttonRow.isHidden = false
        // 失败后直接给「重试」：这类失败多半是网络抖动，重新下载就能过，
        // 让用户跑去网页下载反而更麻烦。
        updateButton.isHidden = false
        updateButton.title = "重试更新"
        updateButton.keyEquivalent = "\r"
        laterButton.title = "关闭"
        resizeToFit()
    }

    /// 按当前内容重新定高，并保持**顶边**不动（窗口锚在屏幕上沿，变高时向下长）。
    private func resizeToFit() {
        layoutIfNeeded()
        root.layoutSubtreeIfNeeded()
        let height = root.fittingSize.height + Self.topInset + Self.inset
        let top = frame.maxY
        setContentSize(NSSize(width: Self.width, height: height))
        setFrameOrigin(NSPoint(x: frame.origin.x, y: top - height))
    }

    // MARK: - 内部

    @objc private func install(_ sender: Any?) { onInstall?() }
    @objc private func cancel(_ sender: Any?) {
        cancelButton.isHidden = true
        noteLabel.stringValue = "正在取消…"
        onCancel?()
    }
    @objc private func later(_ sender: Any?) { onLater?() }

}
