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
        dumpQuickLookLogIfRequested()
        activate()
        // 「双击文件启动」时 application(_:open:) 与 didFinishLaunching 的先后
        // 在各系统版本上并不一致。让出一个任务再判断，别抢着弹设置窗；
        // 万一还是弹了，openDocument 里会把它关掉（兜底）。
        Task { @MainActor in
            guard self.main == nil else { return }
            self.showSettings()
        }
    }

    /// 导出 Quick Look 诊断报告到桌面（**只在 `DebugDumpQLLog` 打开时做**）。
    ///
    /// ## 为什么由主 App 来干这件事
    ///
    /// 这两样东西在沙箱里都读不到：
    /// - 统一日志：`log: Cannot run while sandboxed`
    /// - 插件状态：`pluginkit -m` → `unauthorized discovery flag (PKDiscoverAll)`
    ///
    /// 而主 App 恰恰**不在沙箱里** —— 于是它可以当那只手，把"空格预览到底走的谁"这件事
    /// 的证据一次性取出来。诊断这一整类问题（扩展没被调用 / 被别家抢走）都靠它：
    ///
    /// ```bash
    /// defaults write cn.29dev.Spacedown DebugDumpQLLog -bool true
    /// ```
    ///
    /// 打开后每次启动 App 都会写一份 `~/Desktop/spacedown-ql.txt`，看完关掉即可。
    private func dumpQuickLookLogIfRequested() {
        guard UserDefaults.standard.bool(forKey: "DebugDumpQLLog") else { return }

        // ⚠️ **必须异步**。这功能曾经同步跑（还 `Thread.sleep(5)` 触发一次预览），
        // 结果是：开着这个开关时**每次启动窗口都要卡 5 秒**、还会弹出一个 Quick Look 面板 ——
        // 实际表现就是"双击打不开"。诊断功能绝不能挂在启动路径上。
        //
        // 另外，触发预览要单独一个开关（`DebugQLTrigger`）：平时只想收集日志时，
        // 不该顺带把面板弹到用户脸上。
        if UserDefaults.standard.bool(forKey: "DebugQLClaim") {
            Self.claimQuickLookPreview()
            Thread.sleep(forTimeInterval: 1.5)
        }
        let trigger = UserDefaults.standard.bool(forKey: "DebugQLTrigger")
        let probe = UserDefaults.standard.string(forKey: "DebugQLProbePath")
            ?? (FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/Spacedown-链接测试.md").path)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            var previewStarted = false
            var previewPid: Int32 = 0
            if trigger {
                let preview = Process()
                preview.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
                preview.arguments = ["-p", probe]
                preview.standardOutput = Pipe()
                preview.standardError = Pipe()
                if (try? preview.run()) != nil {
                    previewStarted = true
                    previewPid = preview.processIdentifier
                    Thread.sleep(forTimeInterval: 5)     // 已在后台队列，不挡界面
                    preview.terminate()
                }
            }

            var report = "# Spacedown · Quick Look 诊断报告\n# \(Date())\n"
            report += "# 探针文件: \(probe)\n"
            if previewStarted {
                report += "# 已触发 qlmanage -p（pid \(previewPid)），等待 5 秒后终止\n\n"
            } else if trigger {
                report += "# ⚠️ qlmanage 没能启动 —— 下面第一节必然是空的\n\n"
            } else {
                report += "# 未触发预览（DebugQLTrigger 关闭），只收集既有日志\n\n"
            }
            report += "## 一、扩展日志（subsystem cn.29dev.Spacedown，近 30 分钟）\n"
            report += self.runTool("/usr/bin/log", ["show", "--last", "30m", "--style", "compact",
                                                    "--predicate", "subsystem == \"cn.29dev.Spacedown\""])
            report += "\n## 二、系统登记的全部 Quick Look 预览扩展（+ 启用 / - 禁用）\n"
            report += self.runTool("/usr/bin/pluginkit", ["-m", "-p", "com.apple.quicklook.preview"])
            report += "\n## 三、我们这条\n"
            report += self.runTool("/usr/bin/pluginkit", ["-m", "-i", "cn.29dev.Spacedown.QuickLookPreview"])
            report += "\n## 四、WPS 那条\n"
            report += self.runTool("/usr/bin/pluginkit", ["-m", "-i", "com.kingsoft.wpsoffice.mac.WPSQuickLook"])
            // ⚠️ 这两段是关键：扩展登记正常却一行日志都没有时，**失败原因只会在系统侧**。
            // 这一段是问系统："关于 Spacedown 你记了什么"，以及"quicklookd / pkd 最近在忙什么"。
            report += "\n## 五、系统侧关于 Spacedown 的记录（近 30 分钟）\n"
            report += self.runTool("/usr/bin/log", ["show", "--last", "30m", "--style", "compact",
                                                    "--predicate", "eventMessage CONTAINS \"Spacedown\""])
            report += "\n## 六、quicklookd / pkd 最近的记录（近 30 分钟，可能很长）\n"
            report += self.runTool("/usr/bin/log", ["show", "--last", "30m", "--style", "compact",
                                                    "--predicate",
                                                    "process == \"quicklookd\" OR process == \"pkd\""])
            // ⚠️ 这一段是找"WebContent 为什么一启动就被杀"的关键：前面几段都看不到渲染引擎自己的话。
            report += "\n## 七、WebKit 渲染引擎自己的记录（近 30 分钟）\n"
            report += self.runTool("/usr/bin/log", ["show", "--last", "30m", "--style", "compact",
                                                    "--predicate",
                                                    "subsystem BEGINSWITH \"com.apple.WebKit\" OR "
                                                    + "process CONTAINS \"WebContent\" OR process CONTAINS \"WebKit\""])

            let out = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/spacedown-ql.txt")
            do {
                try report.write(to: out, atomically: true, encoding: .utf8)
                DebugLog.write("已导出 QL 诊断 → \(out.path)（\(report.utf8.count) 字节）")
            } catch {
                DebugLog.write("导出 QL 诊断失败: \(error.localizedDescription)")
            }
        }
    }

    /// 让 markdown 的空格预览真正归我们。**这是幂等的"修复"动作**。
    ///
    /// 四步缺一不可（每一步都踩过坑）：
    /// 1. `lsregister -f` 把 App 重新登记进 LaunchServices —— **只登记，绝不 `-u`**。
    ///    （之前我为了清"构建目录里的重复登记"反复 `-u`，最后一次把它彻底反登记掉，
    ///    结果 pkd 里查不到我们、WPS 又被 ignore ⇒ 系统只剩**纯文本兜底** ✗）
    /// 2. `pluginkit -a` 把扩展加进 pkd 的插件表（`-e` 只能改状态，加不回来）。
    /// 3. `pluginkit -e use` 选我们、`-e ignore` 关掉 WPS。
    /// 4. `qlmanage -r` / `-r cache` 让 Quick Look 重建索引。
    ///
    /// 只能在**非沙箱**进程里跑；主 App 合适，扩展自己不行。
    static func claimQuickLookPreview() {
        let appex = Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/QuickLookPreview.appex").path
        let plan: [(String, [String])] = [
            ("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
             ["-f", Bundle.main.bundlePath]),
            ("/usr/bin/pluginkit", ["-a", appex]),
            ("/usr/bin/pluginkit", ["-e", "use", "-i", "cn.29dev.Spacedown.QuickLookPreview"]),
            ("/usr/bin/pluginkit", ["-e", "ignore", "-i", "com.kingsoft.wpsoffice.mac.WPSQuickLook"]),
            ("/usr/bin/qlmanage", ["-r"]),
            ("/usr/bin/qlmanage", ["-r", "cache"]),
        ]
        for (path, args) in plan {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            // ⚠️ **不要 `waitUntilExit()`**：`qlmanage -r` 这类可能长时间不返回，
            // 会把调用方（后台队列）挂住 —— 之前诊断报告因此一直没生成，很难看出原因。
            // 给它们 0.4 秒自己跑就是了，反正不依赖返回值。
            Thread.sleep(forTimeInterval: 0.4)
        }
        DebugLog.write("已修复 Quick Look：登记 + pluginkit -a + 选举 + 重建索引")
    }

    /// 跑一个命令行工具并把它的输出收回来（stdout + stderr 合并）。
    private func runTool(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? "（输出不是 UTF-8，\(data.count) 字节）\n"
            return text.isEmpty ? "（无输出，退出码 \(process.terminationStatus)）\n" : text
        } catch {
            return "（无法运行 \(path)：\(error.localizedDescription)）\n"
        }
    }

    /// 双击文件、拖到 Dock、「打开方式 → Spacedown」都走这里。
    func application(_ application: NSApplication, open urls: [URL]) {        DebugLog.write("open urls=\(urls.count) \(urls.map(\.lastPathComponent))")
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
