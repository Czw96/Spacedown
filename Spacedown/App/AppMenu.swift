import AppKit

/// 代码构建主菜单。
///
/// 工程里没有 nib，而主菜单不是可选项：没有 `NSApp.mainMenu`，⌘Q / ⌘W / ⌘C
/// 这些标准快捷键全部失效 —— 它们的实现就在菜单项里。
///
/// 动作类条目一律不设 target，走响应链：第一响应者 → 窗口 → 窗口 delegate
/// （`MainWindow`）→ `NSApp`。
@MainActor
enum AppMenu {

    /// 「显示 → 版心宽度」那一行实时值的 tag。
    static let measureInfoTag = 9001

    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(applicationMenu())
        main.addItem(fileMenu())
        main.addItem(editMenu())
        main.addItem(viewMenu())
        main.addItem(windowMenu())
        return main
    }

    // MARK: - 各个菜单

    private static func applicationMenu() -> NSMenuItem {
        menu("Spacedown", items: [
            // 自己实现「关于」：默认面板会显示「Version 1.0 (1)」，见 AppDelegate.showAbout
            item("关于 Spacedown", action: #selector(AppDelegate.showAbout(_:))),
            .separator(),
            // ⌘, 是 macOS 的肌肉记忆；设置窗同时是"没开文件"时的启动窗
            item("设置…", action: #selector(AppDelegate.showSettings(_:)), key: ","),
            item("检查更新…", action: #selector(AppDelegate.checkForUpdates(_:))),
            .separator(),
            item("隐藏 Spacedown", action: #selector(NSApplication.hide(_:)), key: "h", target: NSApp),
            item("隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)),
                 key: "h", modifiers: [.command, .option], target: NSApp),
            item("显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), target: NSApp),
            .separator(),
            item("退出 Spacedown", action: #selector(NSApplication.terminate(_:)), key: "q", target: NSApp),
        ])
    }

    private static func fileMenu() -> NSMenuItem {
        menu("文件", items: [
            item("打开…", action: #selector(MainWindow.openDocument(_:)), key: "o"),
            // 文档窗里是"关标签 / 最后一个时关窗"（MainWindow.closeWindowOrTab），
            // 其它窗口（比如设置窗）当 key 时由 AppDelegate 的同名动作兜底关窗
            item("关闭", action: #selector(MainWindow.closeWindowOrTab(_:)), key: "w"),
            item("重新载入", action: #selector(MainWindow.reloadDocument(_:)), key: "r"),
            .separator(),
            item("在 Finder 中显示", action: #selector(MainWindow.revealInFinder(_:)),
                 key: "r", modifiers: [.command, .shift]),
            item("用默认编辑器打开", action: #selector(MainWindow.openInDefaultEditor(_:)),
                 key: "e", modifiers: [.command, .option]),
        ])
    }

    /// 编辑菜单**不能省**：⌘C / ⌘A 的按键匹配就挂在菜单项上（见文件头注释）。
    /// 少了它，web view 里的文字选得中却复制不出来 —— 这是 v1.0.2 之前的一个真 bug。
    ///
    /// 只读查看器给「复制 / 全选」两项就够，剪切/粘贴/删除没有意义。
    /// 动作走响应链（target 为 nil），最终由 `WKWebView` 的 `copy:` / `selectAll:` 接住。
    private static func editMenu() -> NSMenuItem {
        menu("编辑", items: [
            item("复制", action: #selector(NSText.copy(_:)), key: "c"),
            item("全选", action: #selector(NSText.selectAll(_:)), key: "a"),
            .separator(),
            // 查找走 web view 自己的 `find(_:configuration:completionHandler:)`，
            // 没有文档时这些动作会被方法体里的 guard 挡掉
            item("查找…", action: #selector(MainWindow.showFind(_:)), key: "f"),
            item("查找下一个", action: #selector(MainWindow.findNext(_:)), key: "g"),
            item("查找上一个", action: #selector(MainWindow.findPrevious(_:)),
                 key: "g", modifiers: [.command, .shift]),
        ])
    }

    private static func viewMenu() -> NSMenuItem {
        // 只显示当前值，标题由 MeasureMenuDelegate 在菜单打开时填
        let measureInfo = item("版心宽度", action: nil)
        measureInfo.tag = measureInfoTag
        measureInfo.isEnabled = false

        var items: [NSMenuItem] = [
            // 放大刻意是两个条目：可见的那个负责把「⌘+」显示出来，
            // 隐藏的那个才真正接得住按键 —— 原因见 shortcutAlias
            item("放大", action: #selector(MainWindow.zoomIn(_:)), key: "+"),
            shortcutAlias("放大", action: #selector(MainWindow.zoomIn(_:)), key: "="),
            item("缩小", action: #selector(MainWindow.zoomOut(_:)), key: "-"),
            item("实际大小", action: #selector(MainWindow.zoomActualSize(_:)), key: "0"),
            .separator(),
            // 版心宽度与缩放同组：它们都是"看的方式"
            measureInfo,
            item("加宽版心", action: #selector(MainWindow.widenMeasure(_:)),
                 key: "=", modifiers: [.command, .option]),
            item("收窄版心", action: #selector(MainWindow.narrowMeasure(_:)),
                 key: "-", modifiers: [.command, .option]),
            item("版心自适应（铺满）", action: #selector(MainWindow.resetMeasure(_:)),
                 key: "0", modifiers: [.command, .option]),
            .separator(),
            // ⌃⇥ 是主键；⌘⇧[ / ⌘⇧] 是给用惯浏览器的人的第二入口
            item("下一个标签", action: #selector(MainWindow.nextTab(_:)), key: "\t", modifiers: .control),
            item("上一个标签", action: #selector(MainWindow.previousTab(_:)),
                 key: "\t", modifiers: [.control, .shift]),
            item("下一个标签", action: #selector(MainWindow.nextTab(_:)),
                 key: "]", modifiers: [.command, .shift]),
            item("上一个标签", action: #selector(MainWindow.previousTab(_:)),
                 key: "[", modifiers: [.command, .shift]),
            .separator(),
        ]

        // ⌘1~⌘9：第 9 个固定是"最后一个标签"，与浏览器一致
        for number in 1...9 {
            let tabItem = item("标签 \(number)", action: #selector(MainWindow.selectTab(_:)), key: "\(number)")
            tabItem.tag = number
            items.append(tabItem)
        }

        items.append(.separator())
        items.append(item("接管 Markdown 空格预览",
                          action: #selector(MainWindow.claimQuickLookPreview(_:))))
        let viewMenu = menu("显示", items: items)
        viewMenu.submenu?.delegate = MeasureMenuDelegate.shared
        return viewMenu
    }

    private static func windowMenu() -> NSMenuItem {
        let windowMenu = menu("窗口", items: [
            item("最小化", action: #selector(NSWindow.performMiniaturize(_:)), key: "m"),
            item("缩放", action: #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), target: NSApp),
        ])
        NSApp.windowsMenu = windowMenu.submenu
        return windowMenu
    }

    // MARK: - 拼装

    private static func menu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for item in items { submenu.addItem(item) }
        holder.submenu = submenu
        return holder
    }

    private static func item(
        _ title: String,
        action: Selector?,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = .command,
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        return item
    }

    /// 加一个「只参与快捷键匹配、不出现在菜单里」的别名条目。
    ///
    /// `NSMenuItem.isHidden` 只影响显示，不影响键等价匹配。放大需要它的原因：
    /// 菜单匹配用的是 `charactersIgnoringModifiers`，而 ⇧⌘= 的这个值就是 `"="`，
    /// 所以 keyEquivalent `"+"` 永远匹配不到真实按键；`"="` 才是管用的写法，
    /// `"+"` 条目只负责把「⌘+」显示给用户看。（⌘- 与 ⌘0 没有这个问题。）
    private static func shortcutAlias(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let alias = item(title, action: action, key: key)
        alias.isHidden = true
        return alias
    }
}

/// 让「显示 → 版心宽度」那一行始终是当前值。
///
/// 那一行只在菜单被打开的那一刻需要最新值，`menuNeedsUpdate(_:)` 正是这个时机；
/// 这样改宽度的代码路径里就不必到处补"记得刷新菜单标题"。
@MainActor
final class MeasureMenuDelegate: NSObject, NSMenuDelegate {

    static let shared = MeasureMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let info = menu.item(withTag: AppMenu.measureInfoTag) else { return }
        let percent = MeasureSettings.percent
        info.title = percent == MeasureSettings.full ? "版心宽度：铺满" : "版心宽度：\(percent)%"
    }
}
