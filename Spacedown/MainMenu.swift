import AppKit

/// 代码构建主菜单。
///
/// 工程里没有 MainMenu.xib（纯代码启动），而**主菜单不是可选项**：
/// 没有 `NSApp.mainMenu`，⌘Q / ⌘W / ⌘C 这些标准快捷键全部失效 —— 它们本来的实现
/// 就在菜单项里。这也是「App 起来之后按 ⌘Q 没反应」的原因。
///
/// 标签/缩放类动作的 `target` 都留 nil，走响应链：从第一响应者一路到
/// `NSWindow` → `NSWindow.delegate`（也就是 `MainWindow`）→ `NSApp`。
@MainActor
enum MainMenu {

    /// 「显示 → 版心宽度」那一行实时值的 tag。菜单打开时由 `MenuUpdater` 填标题。
    static let measureInfoTag = 9001

    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(applicationMenu())
        main.addItem(fileMenu())
        main.addItem(viewMenu())
        main.addItem(windowMenu())
        return main
    }

    // MARK: - 各菜单

    private static func applicationMenu() -> NSMenuItem {
        holder("Spacedown", [
            // 自己接：默认的 orderFrontStandardAboutPanel 会显示「Version 1.0 (1)」，
            // 见 AppDelegate.showAbout 的注释（版本行只留 1.0，不要括号里的 build 号）
            item("关于 Spacedown", #selector(AppDelegate.showAbout(_:))),
            .separator(),
            // ⌘, 是 macOS 的肌肉记忆。设置窗同时也是"没开文件"时的启动窗（AppDelegate.showSettings）
            item("设置…", #selector(AppDelegate.showSettings(_:)), ","),
            .separator(),
            item("隐藏 Spacedown", #selector(NSApplication.hide(_:)), "h", target: NSApp),
            item("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp),
            item("显示全部", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp),
            .separator(),
            item("退出 Spacedown", #selector(NSApplication.terminate(_:)), "q", target: NSApp),
        ])
    }

    private static func fileMenu() -> NSMenuItem {
        holder("文件", [
            item("打开…", #selector(MainWindow.openDocument(_:)), "o"),
            item("关闭标签", #selector(MainWindow.closeCurrentTab(_:)), "w"),
            item("重新载入", #selector(MainWindow.reloadDocument(_:)), "r"),
            .separator(),
            item("在 Finder 中显示", #selector(MainWindow.revealInFinder(_:)), "r", [.command, .shift]),
            item("用默认编辑器打开", #selector(MainWindow.openInDefaultEditor(_:)), "e", [.command, .option]),
        ])
    }

    private static func viewMenu() -> NSMenuItem {
        // 「版心宽度」那一行只用来显示当前值，打开菜单时由 MenuUpdater 填标题
        let measureInfo = item("版心宽度", nil)
        measureInfo.tag = measureInfoTag
        measureInfo.isEnabled = false

        var items: [NSMenuItem] = [
            // 放大刻意是**两个条目**：看得见的那个负责把「⌘+」显示出来，
            // 隐藏的那个才真正接得住按键 —— 原因见 hiddenAlias 的注释。
            item("放大", #selector(MainWindow.zoomIn(_:)), "+"),
            hiddenAlias("放大", #selector(MainWindow.zoomIn(_:)), "="),
            item("缩小", #selector(MainWindow.zoomOut(_:)), "-"),
            item("实际大小", #selector(MainWindow.zoomActualSize(_:)), "0"),
            .separator(),
            // 版心宽度：和缩放同一组 —— 它们都是"看的方式"，不该分家。
            // ⚠️ 加宽那条同样**不能写 "+"**（⇧⌘= 的 charactersIgnoringModifiers 是 "="），
            // 见 hiddenAlias 的注释。
            measureInfo,
            item("加宽版心", #selector(MainWindow.widenMeasure(_:)), "=", [.command, .option]),
            item("收窄版心", #selector(MainWindow.narrowMeasure(_:)), "-", [.command, .option]),
            item("版心自适应（铺满）", #selector(MainWindow.resetMeasure(_:)), "0", [.command, .option]),
            .separator(),
            // ⌃⇥ 是主键；⌘⇧[ / ⌘⇧] 是留给用惯 Chrome 的人的第二入口
            item("下一个标签", #selector(MainWindow.nextTab(_:)), "\t", .control),
            item("上一个标签", #selector(MainWindow.previousTab(_:)), "\t", [.control, .shift]),
            item("下一个标签", #selector(MainWindow.nextTab(_:)), "]", [.command, .shift]),
            item("上一个标签", #selector(MainWindow.previousTab(_:)), "[", [.command, .shift]),
            .separator(),
        ]
        // ⌘1~⌘9：第 9 个固定是"最后一个标签"，跟 Safari / Chrome 一致
        for number in 1...9 {
            let menuItem = item("标签 \(number)", #selector(MainWindow.selectTab(_:)), "\(number)")
            menuItem.tag = number
            items.append(menuItem)
        }
        let menu = holder("显示", items)
        // 每次打开「显示」都把「版心宽度」那一行刷成当前值
        menu.submenu?.delegate = MenuUpdater.shared
        return menu
    }

    private static func windowMenu() -> NSMenuItem {
        let menu = holder("窗口", [
            item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("缩放", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("前置全部窗口", #selector(NSApplication.arrangeInFront(_:)), target: NSApp),
        ])
        NSApp.windowsMenu = menu.submenu
        return menu
    }

    // MARK: - 拼装

    private static func holder(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for item in items { menu.addItem(item) }
        holder.submenu = menu
        return holder
    }

    private static func item(
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command,
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        menuItem.target = target
        return menuItem
    }

    /// 加一个「只参与快捷键匹配、不出现在菜单里」的别名条目。
    ///
    /// `NSMenuItem.isHidden` 只影响显示，**不影响键等价匹配**（实测：隐藏项照样命中）。
    ///
    /// 为什么放大需要它：**`⌘+` 这个写法按不出来**。实测办法是把构造出来的 `NSEvent`
    /// 喂给 `NSMenu.performKeyEquivalent(with:)`，结果如下：
    ///
    /// | 物理按键 | keyEquivalent `"+"` | keyEquivalent `"="` |
    /// |---|---|---|
    /// | ⌘= | ✗ | ✓ |
    /// | ⇧⌘=（也就是大家心里的「⌘+」） | ✗ | ✓ |
    ///
    /// 原因是菜单匹配拿的是 `charactersIgnoringModifiers`，而 ⇧⌘= 的这个值就是 `"="`
    /// —— 所以 `"+"` 永远匹配不上任何真实按键。结论：`"="` 才是管用的那个写法，
    /// 而 `"+"` 条目只负责把「⌘+」这四个字符显示给用户看。
    /// （`⌘-` 与 `⌘0` 没有这个问题，物理按键与字符一一对应，所以不需要别名。）
    private static func hiddenAlias(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let alias = item(title, action, key)
        alias.isHidden = true
        return alias
    }
}

/// 让「显示 → 版心宽度」那一行永远是当前值。
///
/// 为什么用菜单代理、而不是在每次改宽度时顺手改标题：
/// 那一行只在**菜单被打开的那一刻**需要是最新值，`menuNeedsUpdate(_:)` 正是这个时机。
/// 这样"改宽度"的代码路径里就不用到处补一句"记得刷新菜单标题"。
@MainActor
final class MenuUpdater: NSObject, NSMenuDelegate {

    static let shared = MenuUpdater()

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let info = menu.item(withTag: MainMenu.measureInfoTag) else { return }
        let percent = MeasureSettings.percent
        info.title = percent == MeasureSettings.full
            ? "版心宽度：铺满"
            : "版心宽度：\(percent)%"
    }
}
