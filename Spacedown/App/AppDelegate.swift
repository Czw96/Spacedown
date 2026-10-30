import AppKit

/// App 委托：生命周期、打开请求、窗口归属。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var main: MainWindow?
    private var settings: SettingsWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        DebugLog.write("willFinishLaunching")
        // 主菜单必须先于窗口装好：没有 NSApp.mainMenu，⌘Q / ⌘W / ⌘C 全部失效
        NSApp.mainMenu = AppMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.write("didFinishLaunching")
        QuickLookDiagnostics.exportIfRequested()
        activate()
        // 延迟几秒再查，避开启动时建窗口/webview 的高峰
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            UpdateChecker.shared.autoCheckIfNeeded()
        }
        // 双击文件启动时，open(_:) 与这里的先后在不同系统版本上并不一致：
        // 让出一个任务再判断，别抢着弹设置窗（万一还是弹了，openDocument 会把它收掉）。
        Task { @MainActor in
            guard self.main == nil else { return }
            self.showSettings()
        }
    }

    /// ⌘W 的兜底：文档窗不是 key（比如设置窗在前）时，关掉当前 key window。
    ///
    /// 响应链是 keyWindow.firstResponder → … → keyWindow → keyWindow.delegate → NSApp → 本对象。
    /// 文档窗为 key 时会被 `MainWindow.closeWindowOrTab` 先接住，所以这里只处理"其它窗口"。
    /// 没有它的话，设置窗里按 ⌘W 会被无声丢弃 —— 菜单项找不到接收者，什么都不会发生。
    @objc func closeWindowOrTab(_ sender: Any?) {
        NSApp.keyWindow?.performClose(sender)
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

    /// 点 Dock 图标、但没有可见窗口时把窗口带回来。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        if let main {
            main.show()
        } else {
            showSettings()
        }
        return true
    }

    /// 「检查更新…」。
    @objc func checkForUpdates(_ sender: Any?) {
        UpdateChecker.shared.check(manual: true)
    }

    /// 「关于 Spacedown」。
    ///
    /// 不用默认面板：它渲染的版本行是 `Version {short} ({build})`，括号里的 build 号
    /// 对用户没有意义。只传 `.version` 一个选项才是干净的 `Version 1.0`；
    /// 同时传 `.applicationVersion` 会让括号回来。
    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [.version: AppInfo.version])
    }

    // MARK: - 窗口

    /// 菜单「Spacedown → 设置…」（⌘,）与启动兜底都走这里。
    @objc func showSettings(_ sender: Any? = nil) {
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
        // 设置窗只该在"什么都没开"时占位；用户既然要开文件，就把它收掉
        settings?.close()
        settings = nil

        let window: MainWindow
        if let existing = main {
            window = existing
        } else {
            let created = MainWindow()
            created.onClose = { [weak self] _ in self?.main = nil }
            main = created
            window = created
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
