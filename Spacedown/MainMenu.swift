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
            item("关于 Spacedown", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp),
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
        var items: [NSMenuItem] = [
            item("放大", #selector(MainWindow.zoomIn(_:)), "+"),
            item("缩小", #selector(MainWindow.zoomOut(_:)), "-"),
            item("实际大小", #selector(MainWindow.zoomActualSize(_:)), "0"),
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
        return holder("显示", items)
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
}
