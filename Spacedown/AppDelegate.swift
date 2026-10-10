import AppKit

/// App 委托。
///
/// 选 AppKit 而不是 SwiftUI 的理由见 docs/技术方案.md §7.1：
/// 多标签、窗口操作、交通灯与自绘标签栏同排 —— AppKit 的控制力强得多，启动开销也更可预测。
///
/// ⚠️ **不要给这个类标 `@main`**：AppKit 为 `NSApplicationDelegate` 提供的默认
/// `main()` 只是转发给 `NSApplicationMain`，而后者靠 nib 来实例化 delegate。
/// 本工程没有 nib，标了 `@main` 的结果是进程在跑、却一个回调都不触发。
/// 真正的入口在 `SpacedownMain.swift`。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var main: MainWindow?
    private var settings: SettingsWindow?

    // MARK: - 生命周期

    func applicationWillFinishLaunching(_ notification: Notification) {
        DebugLog.write("willFinishLaunching")
        // 主菜单必须在窗口之前装好：没有 NSApp.mainMenu，⌘Q / ⌘W / ⌘C 全部失效
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.write("didFinishLaunching")
        activate()
        // 「双击文件启动」时 application(_:open:) 与 didFinishLaunching 的先后
        // 在各系统版本上并不一致。让出一个任务再判断，别抢着弹设置窗；
        // 万一还是弹了，openDocument 里会把它关掉（兜底）。
        Task { @MainActor in
            guard self.main == nil else { return }
            self.showSettings()
        }
    }

    /// 双击文件、拖到 Dock、「打开方式 → Spacedown」都走这里。
    func application(_ application: NSApplication, open urls: [URL]) {
        DebugLog.write("open urls=\(urls.count) \(urls.map(\.lastPathComponent))")
        for url in urls {
            openDocument(at: url)
        }
        application.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 点 Dock 图标、没有窗口时把设置窗带回来。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if main == nil {
                showSettings()
            } else {
                main?.show()
            }
        }
        return true
    }

    /// 「关于 Spacedown」。
    ///
    /// 刻意不用默认的 `orderFrontStandardAboutPanel(_:)`：它渲染的版本行是
    /// `Version {CFBundleShortVersionString} ({CFBundleVersion})` → 显示成
    /// **「Version 1.0 (1)」**，括号里的 build 号对用户没有意义。
    ///
    /// 实测（构造面板后把里面的文本读出来）：
    ///
    /// | 传的选项 | 面板上的版本行 |
    /// |---|---|
    /// | 都不传（默认） | `Version 1.0 (1)` |
    /// | 只传 `.version` | **`Version 1.0`** ✅ |
    /// | 只传 `.applicationVersion` | `Version 1.0` |
    /// | **两个都传** | `Version 1.0 (1.0)` ← 括号又回来了 |
    ///
    /// 所以只传 `.version` 一个，且**不要**同时传 `.applicationVersion`。
    @objc func showAbout(_ sender: Any?) {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        NSApp.orderFrontStandardAboutPanel(options: [.version: short ?? "1.0"])
    }

    // MARK: - 窗口

    /// 菜单「Spacedown → 设置…」（⌘,）与启动兜底都走这里。
    @objc func showSettings(_ sender: Any? = nil) {
        DebugLog.write("showSettings")
        if let settings {
            settings.show()
            return
        }
        let window = SettingsWindow()
        window.onClose = { [weak self] _ in self?.settings = nil }
        settings = window
        window.show()
    }

    private func openDocument(at url: URL) {
        guard url.isFileURL else { return }
        // 设置窗只该在"什么都没开"的时候占着位置；用户既然要开文件，就把它收掉
        settings?.close()
        settings = nil

        let window: MainWindow
        if let existing = main {
            window = existing
        } else {
            window = MainWindow()
            window.onClose = { [weak self] _ in self?.main = nil }
            main = window
        }
        window.open(url)
    }

    private func activate() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
