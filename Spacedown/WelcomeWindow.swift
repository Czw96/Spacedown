import AppKit
import UniformTypeIdentifiers

/// 直接双击 App 图标（没带文件）时显示的窗口。
///
/// 存在的原因：`LSHandlerRank` 设的是 **Alternate**（§7.4）—— 我们不抢用户
/// 现有的编辑器当默认打开方式。代价是双击 `.md` 不会进 Spacedown。
///
/// ⚠️ 这里有个**死锁**：默认打开方式被别的编辑器占着时，双击 `.md` 根本不会启动
/// Spacedown，用户也就永远看不到这个按钮。所以状态要显式说出来 ——
/// 明确告诉用户"现在是谁在接管"，以及"其实按空格就能用，不需要改这个"。
@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate {

    var onClose: ((WelcomeWindow) -> Void)?
    var onOpenFile: ((URL) -> Void)?

    private let window: NSWindow
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let setDefaultButton = NSButton()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Spacedown"
        window.center()
        super.init()
        window.delegate = self
        window.contentView = makeView()
        refreshStatus()
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

    // MARK: - 界面

    private func makeView() -> NSView {
        let title = NSTextField(labelWithString: "Spacedown")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        title.alignment = .center

        let subtitle = NSTextField(
            labelWithString: "Markdown 速览 · 在 Finder 里选中 .md 按空格即可预览")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.preferredMaxLayoutWidth = 420

        setDefaultButton.bezelStyle = .rounded
        setDefaultButton.target = self
        setDefaultButton.action = #selector(setAsDefault(_:))

        let open = NSButton(title: "选择文件…", target: self, action: #selector(chooseFile(_:)))
        open.bezelStyle = .rounded

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center
        hintLabel.preferredMaxLayoutWidth = 420
        hintLabel.stringValue = "空格预览走的是 Quick Look 扩展，跟默认打开方式无关；"
            + "只有双击才受它影响。"

        let buttons = NSStackView(views: [setDefaultButton, open])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [title, subtitle, statusLabel, buttons, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 36, bottom: 28, right: 36)

        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    /// 查当前 `.md` 的默认打开方式。
    ///
    /// 用 `NSWorkspace` 而不是 `LSCopyDefaultRoleHandlerForContentType` —— 后者
    /// 在 macOS 12 起已标记弃用。
    private func refreshStatus() {
        guard let type = UTType(MarkdownUTI) else { return }
        let current = NSWorkspace.shared.urlForApplication(toOpen: type)
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let isUs = current?.standardizedFileURL == bundleURL

        if isUs {
            statusLabel.stringValue = "✓ 双击 .md 已经会用 Spacedown 打开。"
            setDefaultButton.title = "已是默认打开方式"
            setDefaultButton.isEnabled = false
        } else {
            let name = current.map { FileManager.default.displayName(atPath: $0.path) } ?? "未知应用"
            statusLabel.stringValue = "当前 .md 的默认打开方式是「\(name)」，"
                + "双击 .md 会用它打开，看到的不是渲染视图。"
            setDefaultButton.title = "设为 .md 默认打开方式"
            setDefaultButton.isEnabled = true
        }
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
                    self.statusLabel.stringValue = "设置失败：\(error.localizedDescription)。"
                        + "也可以在 Finder 里右键 → 显示简介 → 打开方式手动改。"
                    self.setDefaultButton.isEnabled = true
                } else {
                    self.refreshStatus()
                }
            }
        }
    }

    @objc private func chooseFile(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if let type = UTType(MarkdownUTI) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            onOpenFile?(url)
        }
        window.close()
    }
}

/// `.md` / `.markdown` 的实际 UTI（mdls 实测）。见 docs/技术方案.md §6.2。
let MarkdownUTI = "net.daringfireball.markdown"
