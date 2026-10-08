import AppKit
import UniformTypeIdentifiers

/// 「Spacedown 设置」窗口。
///
/// 两个角色：
/// 1. **设置页** —— 菜单「Spacedown → 设置…」（<kbd>⌘</kbd><kbd>,</kbd>）打开。
///    目前唯一可操作的事：`双击 .md 时用谁打开`，一个按钮搞定。
/// 2. **启动兜底** —— 直接双击 App 图标（没带文件）时显示它，否则 App 起来后一个窗口都没有。
///
/// ⚠️ 这里有个**死锁**要说清楚：`LSHandlerRank` 是 **Alternate**（技术方案 §7.4），
/// 我们不抢用户现有的编辑器当默认打开方式。代价是：默认打开方式被别的编辑器占着时，
/// 双击 `.md` 根本不会启动 Spacedown，用户也就永远看不到那个按钮。
/// 所以状态行必须**显式说出"现在是谁在接管"** —— 光有一个按钮是不够的。
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {

    var onClose: ((SettingsWindow) -> Void)?

    /// 内容列宽 —— 状态行的折行宽度和居中区域共同用它。
    private static let columnWidth: CGFloat = 400

    private let window: NSWindow
    /// 当前 `.md` 默认打开方式的说明。出错时同一行变成红色文字（就这一条，不再单独开一行）。
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let setDefaultButton = NSButton()

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 416),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // 不设标题：头部已有 Logo + 名字，标题栏再来一份"Spacedown 设置"是重复的。
        window.title = ""
        super.init()
        window.delegate = self
        window.contentView = makeContentView()
        refreshStatus()        // ⚠️ 必须在量高度之前：状态行字数会决定它占几行
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

    /// 窗口高度跟着内容走。
    ///
    /// 列宽是固定的，高度却随字体度量/系统版本变 —— 写死一个数要么在底部留一大片空白
    /// （实测写 416 时多出 62pt），要么把页脚裁掉。所以按 `fittingSize` 定尺寸，
    /// 底部只留根 stack 自带的 inset。
    private func sizeToFitContent() {
        guard let content = window.contentView,
              let root = content.subviews.first else { return }
        root.layoutSubtreeIfNeeded()
        let height = root.fittingSize.height
        guard height > 0 else { return }
        window.setContentSize(NSSize(width: 520, height: height.rounded(.up)))
    }

    // MARK: - 界面

    private func makeContentView() -> NSView {
        // 顶部：图标 + 名字 + 一句话。设置/关于面板的惯例就是先给身份，再给设置项。
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

        // 中间：一句话说清现状 + 一个一键动作。
        //
        // 这里刻意**不做成"设置项"**（没有分组标题、没有卡片、没有"打开方式"这种标签）：
        // 全窗口就这一件事要做 —— 把 `.md` 的默认打开方式设给自己 —— 给它一行主赛道就够了，
        // 包成 card + 小标题反而把一件动作伪装成一个需要"折腾"的开关。
        statusLabel.font = .systemFont(ofSize: 12.5)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.preferredMaxLayoutWidth = Self.columnWidth

        setDefaultButton.bezelStyle = .rounded
        setDefaultButton.target = self
        setDefaultButton.action = #selector(setAsDefault(_:))
        // ⏎ 让它当默认按钮：蓝色的高亮框本身就是"按一下就行"的暗示。
        setDefaultButton.keyEquivalent = "\r"

        let action = NSStackView(views: [statusLabel, setDefaultButton])
        action.orientation = .vertical
        action.alignment = .centerX
        action.spacing = 12

        let version = NSTextField(labelWithString: Self.versionLine)
        version.font = .systemFont(ofSize: 11)
        version.textColor = .tertiaryLabelColor
        version.alignment = .center

        let root = NSStackView(views: [header, action, version])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 18
        root.setCustomSpacing(24, after: header)
        root.setCustomSpacing(22, after: action)
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

    /// 查当前 `.md` 的默认打开方式。
    ///
    /// 用 `NSWorkspace` 而不是 `LSCopyDefaultRoleHandlerForContentType` —— 后者
    /// 在 macOS 12 起已标记弃用。
    private func refreshStatus() {
        guard let type = UTType(MarkdownUTI) else { return }
        let current = NSWorkspace.shared.urlForApplication(toOpen: type)
        let isUs = current?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL

        statusLabel.textColor = .secondaryLabelColor
        if isUs {
            statusLabel.stringValue = "双击 .md 已经会用 Spacedown 打开。"
            setDefaultButton.title = "已是默认打开方式"
            setDefaultButton.isEnabled = false
        } else {
            // 显式说出是谁在接管 —— 这就是那个死锁的解药（见类型注释）
            let name = current.map(Self.displayName(of:)) ?? "未知应用"
            statusLabel.stringValue = "双击 .md 现在会用「\(name)」打开。"
            setDefaultButton.title = "设为 .md 默认打开方式"
            setDefaultButton.isEnabled = true
        }
    }

    /// App 的显示名。
    ///
    /// `FileManager.displayName(atPath:)` 给的是「Spacedown.app」这种带后缀的名字，
    /// 而设置页里该显示「Spacedown」—— 所以优先问它自己 Info.plist 里的显示名。
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
        guard let type = UTType(MarkdownUTI) else { return }
        setDefaultButton.isEnabled = false
        NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL, toOpen: type
        ) { [weak self] error in
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

    // MARK: - 素材

    /// 应用图标（`Spacedown/AppIcon.icns`，几何源在 `design/logo/build_logo.py`）。
    ///
    /// 先按资源名找，再退回 `NSApp.applicationIconImage` —— 后者让离屏渲染的预览工具
    /// 也能拿到真图标（它没有 app bundle）。
    private static var logo: NSImage? {
        NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
    }

    /// 页脚。取 bundle 里的真实版本号；裸可执行文件里拿不到时退回 "1.0"。
    private static var versionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "版本 \(short ?? "1.0")"
    }
}

/// `.md` / `.markdown` 的实际 UTI（mdls 实测）。见 docs/技术方案.md §6.2。
let MarkdownUTI = "net.daringfireball.markdown"
