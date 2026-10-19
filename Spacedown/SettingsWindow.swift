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
    private let uninstallButton = HoverLinkButton()

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 416),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // ⚠️ 不关掉这个标志，**关设置窗时会段错误崩溃**（程序化创建的窗口默认为 true，
        // 关窗时 AppKit 释放一次、ARC 再释放一次）。完整说明与复现数据见
        // `SpacedownWindow` 的注释 —— 这条是那个崩溃的直接责任人。
        window.isReleasedWhenClosed = false
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

        // 卸载：**刻意做得不起眼**（小字、无边框、放在版本行下面）。
        // 它是"离开"的出口，不该和"设为默认打开方式"抢注意力。
        uninstallButton.title = "卸载 Spacedown…"
        uninstallButton.bezelStyle = .inline
        uninstallButton.isBordered = false
        uninstallButton.font = .systemFont(ofSize: 11)
        // 平时是 secondary（tertiary 在浅色下几乎看不见），**悬停才变红** ——
        // 卸载是不可逆动作，破坏性应该在交互那一刻才显现，而不是一直红着喊。
        uninstallButton.contentTintColor = .secondaryLabelColor
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
            statusLabel.stringValue = "双击 .md 使用 Spacedown 打开。"
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

    // MARK: - 卸载

    /// 把 App 本体和所有用户侧残留一起删掉。
    ///
    /// **为什么交给一个独立脚本**：App 没法删掉正在运行的自己，脚本会先等本进程退出。
    /// **为什么逐项删而不是扫目录**：用户目录里不该出现"按前缀删一片"的动作。
    @objc private func uninstall(_ sender: Any) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "卸载 Spacedown？"
        alert.informativeText = """
        会删除以下内容，不可撤销：

        • /Applications/Spacedown.app
        • 偏好设置（cn.29dev.Spacedown）
        • 空格预览扩展的沙箱容器与系统登记
        • 缓存、窗口状态、调试日志
        """
        // 第一个按钮是默认（回车）—— 默认**不删**。
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "卸载")
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        Self.runUninstallScript()
        NSApp.terminate(nil)
    }

    private static func runUninstallScript() {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
            + "LaunchServices.framework/Support/lsregister"
        let script = """
        #!/bin/bash
        # Spacedown 卸载脚本：由 App 写到临时目录后执行，先等 App 退出再清理。
        set -u
        APP="$1"; PID="$2"; HOME_DIR="$3"
        LSREG="\(lsregister)"

        for _ in $(seq 1 100); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.1
        done

        # 注销空格预览扩展与 App 自身（**卸载场景下反登记才是对的**）
        /usr/bin/pluginkit -e ignore -i cn.29dev.Spacedown.QuickLookPreview >/dev/null 2>&1
        "$LSREG" -u "$APP" >/dev/null 2>&1
        /usr/bin/qlmanage -r >/dev/null 2>&1
        /usr/bin/qlmanage -r cache >/dev/null 2>&1

        rm -rf "$APP"

        /usr/bin/defaults delete cn.29dev.Spacedown >/dev/null 2>&1
        rm -f  "$HOME_DIR/Library/Preferences/cn.29dev.Spacedown.plist"
        rm -rf "$HOME_DIR/Library/Saved Application State/cn.29dev.Spacedown.savedState"
        rm -rf "$HOME_DIR/Library/Containers/cn.29dev.Spacedown.QuickLookPreview"
        rm -rf "$HOME_DIR/Library/Caches/cn.29dev.Spacedown"
        rm -rf "$HOME_DIR/Library/HTTPStorages/cn.29dev.Spacedown"
        rm -f  /tmp/spacedown-debug.log

        rm -f "$0"
        """
        let path = NSTemporaryDirectory() + "spacedown-uninstall.sh"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        } catch {
            DebugLog.write("写卸载脚本失败: \(error.localizedDescription)")
            return
        }
        // `nohup ... &` 让它脱离本进程：App 退出之后脚本还得继续跑完。
        let command = "nohup /bin/bash " + shellQuoted(path)
            + " " + shellQuoted(Bundle.main.bundlePath)
            + " \(getpid()) "
            + shellQuoted(FileManager.default.homeDirectoryForCurrentUser.path)
            + " >/dev/null 2>&1 &"
        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/bin/bash")
        runner.arguments = ["-c", command]
        try? runner.run()
    }

    /// 单引号包裹，路径里有空格/引号也安全。
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\\''"#) + "'"
    }

    /// 页脚。取 bundle 里的真实版本号；裸可执行文件里拿不到时退回 "1.0"。
    private static var versionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "版本 \(short ?? "1.0")"
    }
}

/// `.md` / `.markdown` 的实际 UTI（mdls 实测）。见 docs/技术方案.md §6.2。
let MarkdownUTI = "net.daringfireball.markdown"

/// 悬停时略微加重的文字按钮（用于「卸载…」）。
///
/// 为什么不用带边框的按钮：卸载是**低频 + 不可逆**的动作，按 macOS 惯例应当**降权**。
/// 一个边框按钮会把它和主操作摆成同级、还容易误点 ✗。
///
/// 为什么悬停**不变红**：红色是"立刻要出事"的信号，用在这里只是装饰性示警，
/// 反而显得廉价。灰色加一档（secondary → label）已经足够说明"这是可点的"。
final class HoverLinkButton: NSButton {

    private var trackArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackArea { removeTrackingArea(trackArea) }
        // `.activeInActiveApp`：设置窗在前台时才跟踪（后台不需要响应悬停）
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp],
                                  owner: self)
        addTrackingArea(area)
        trackArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        contentTintColor = .labelColor
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = .secondaryLabelColor
    }
}
