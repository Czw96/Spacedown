import AppKit
import UniformTypeIdentifiers

/// 「Spacedown 设置」窗口。
///
/// 两个角色：
/// 1. **设置页** —— 菜单「Spacedown → 设置…」（⌘,）打开，目前只有一件事：
///    把 `.md` 的默认打开方式设为自己。
/// 2. **启动兜底** —— 直接双击 App 图标（没带文件）时显示它，否则 App 起来后一个窗口都没有。
///
/// ⚠️ 这里有个循环依赖要说清楚：我们不抢用户现有的编辑器当默认打开方式
/// （`LSHandlerRank` 是 Alternate），代价是默认打开方式被别家占着时，双击 `.md`
/// 根本不会启动 Spacedown，用户也就永远看不到这个按钮。所以状态行必须显式说出
/// "现在是谁在接管" —— 光有一个按钮不够。
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {

    var onClose: ((SettingsWindow) -> Void)?

    /// 内容列宽：状态行的折行宽度与居中区域共用它。
    private static let columnWidth: CGFloat = 400

    private let window: NSWindow
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let setDefaultButton = NSButton()
    private let uninstallButton = HoverLinkButton()

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 416),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // 不关掉这个标志，关窗时会因"多释放一次"而崩溃，见 SpacedownWindow
        window.isReleasedWhenClosed = false
        // 不设标题：头部已有图标 + 名字
        window.title = ""
        super.init()

        window.delegate = self
        window.contentView = makeContentView()
        refreshStatus()          // 必须在量高度之前：状态行的字数决定它占几行
        sizeToFitContent()
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }

    /// 窗口高度跟着内容走：列宽固定，高度随字体度量与系统版本变，
    /// 写死一个数要么底部留一大片空白，要么把页脚裁掉。
    private func sizeToFitContent() {
        guard let content = window.contentView, let root = content.subviews.first else { return }
        root.layoutSubtreeIfNeeded()
        let height = root.fittingSize.height
        guard height > 0 else { return }
        window.setContentSize(NSSize(width: 520, height: height.rounded(.up)))
    }

    // MARK: - 界面

    private func makeContentView() -> NSView {
        let icon = NSImageView()
        icon.image = Self.logo
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 92),
            icon.heightAnchor.constraint(equalToConstant: 92),
        ])

        let title = NSTextField(labelWithString: "Spacedown")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .center

        let tagline = NSTextField(
            wrappingLabelWithString: "Markdown 速览 · 在 Finder 里选中 .md，按空格即可预览")
        tagline.font = .systemFont(ofSize: 12.5)
        tagline.textColor = .secondaryLabelColor
        tagline.alignment = .center
        tagline.preferredMaxLayoutWidth = Self.columnWidth - 40

        let header = NSStackView(views: [icon, title, tagline])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 8
        header.setCustomSpacing(14, after: icon)
        header.setCustomSpacing(5, after: title)

        // 全窗口只有一件事要做，给它一行主赛道就够了：
        // 包成卡片 + 小标题反而把一件动作伪装成一个需要"折腾"的开关。
        statusLabel.font = .systemFont(ofSize: 12.5)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.preferredMaxLayoutWidth = Self.columnWidth

        setDefaultButton.bezelStyle = .rounded
        setDefaultButton.target = self
        setDefaultButton.action = #selector(setAsDefault(_:))
        // ⏎ 让它当默认按钮：高亮框本身就是"按一下就行"的暗示
        setDefaultButton.keyEquivalent = "\r"

        let action = NSStackView(views: [statusLabel, setDefaultButton])
        action.orientation = .vertical
        action.alignment = .centerX
        action.spacing = 12

        let version = NSTextField(labelWithString: Self.versionLine)
        version.font = .systemFont(ofSize: 11)
        version.textColor = .tertiaryLabelColor
        version.alignment = .center

        uninstallButton.title = "卸载 Spacedown…"
        uninstallButton.bezelStyle = .inline
        uninstallButton.isBordered = false
        uninstallButton.font = .systemFont(ofSize: 11)
        uninstallButton.target = self
        uninstallButton.action = #selector(uninstall(_:))

        let root = NSStackView(views: [header, action, version, uninstallButton])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 18
        root.setCustomSpacing(24, after: header)
        root.setCustomSpacing(22, after: action)
        root.setCustomSpacing(10, after: version)
        root.edgeInsets = NSEdgeInsets(top: 30, left: 34, bottom: 20, right: 34)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 416))
        container.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            action.widthAnchor.constraint(equalToConstant: Self.columnWidth),
        ])
        return container
    }

    // MARK: - 状态

    /// 查当前 `.md` 的默认打开方式。用 `NSWorkspace`：`LSCopyDefaultRoleHandlerForContentType`
    /// 从 macOS 12 起已弃用。
    private func refreshStatus() {
        guard let type = UTType(MarkdownFileType.preferredUTI) else { return }
        let current = NSWorkspace.shared.urlForApplication(toOpen: type)
        let isUs = current?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL

        statusLabel.textColor = .secondaryLabelColor
        if isUs {
            statusLabel.stringValue = "双击 .md 使用 Spacedown 打开。"
            setDefaultButton.title = "已是默认打开方式"
            setDefaultButton.isEnabled = false
        } else {
            // 显式说出是谁在接管 —— 这就是那个循环依赖的解药
            let name = current.map(Self.displayName(of:)) ?? "未知应用"
            statusLabel.stringValue = "双击 .md 现在会用「\(name)」打开。"
            setDefaultButton.title = "设为 .md 默认打开方式"
            setDefaultButton.isEnabled = true
        }
    }

    /// App 的显示名。`displayName(atPath:)` 给的是「Spacedown.app」，这里要的是「Spacedown」。
    private static func displayName(of appURL: URL) -> String {
        if let bundle = Bundle(url: appURL) {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = bundle.object(forInfoDictionaryKey: key) as? String, !name.isEmpty {
                    return name
                }
            }
        }
        let name = FileManager.default.displayName(atPath: appURL.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    // MARK: - 动作

    @objc private func setAsDefault(_ sender: Any) {
        guard let type = UTType(MarkdownFileType.preferredUTI) else { return }
        setDefaultButton.isEnabled = false
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    // 失败要给出兜底路径，别只说"失败了"
                    self.statusLabel.stringValue = "设置失败：\(error.localizedDescription)。"
                        + "也可以在 Finder 里右键 .md → 显示简介 → 打开方式手动改。"
                    self.statusLabel.textColor = .systemRed
                    self.setDefaultButton.isEnabled = true
                } else {
                    self.refreshStatus()
                }
            }
        }
    }

    @objc private func uninstall(_ sender: Any) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "卸载 Spacedown？"
        alert.informativeText = """
        会删除以下内容：

        • /Applications/Spacedown.app
        • 偏好设置（cn.29dev.Spacedown）
        • 空格预览扩展的系统登记
        • 缓存、窗口状态、调试日志
        """
        // macOS 惯例：主操作在右侧、是默认按钮（回车）；取消放左边
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        // 删除是默认动作，所以把 Esc 显式绑给"取消"，不依赖 AppKit 的默认行为
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Uninstaller.run()
    }

    // MARK: - 素材

    /// 应用图标（`Resources/AppIcon.icns`）。先按资源名找，再退回 App 图标 ——
    /// 后者让没有 app bundle 的离屏工具也能拿到图。
    private static var logo: NSImage? {
        NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
    }

    /// 取 bundle 里的真实版本号；裸可执行文件里拿不到时退回 "1.0"。
    private static var versionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "版本 \(short ?? "1.0")"
    }
}
