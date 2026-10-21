import AppKit

/// 程序入口。
///
/// 不能给 `AppDelegate` 标 `@main`：AppKit 提供的默认 `main()` 只是转给
/// `NSApplicationMain`，而后者靠 nib 实例化 delegate。本工程是纯代码启动、没有 nib，
/// 标了 `@main` 的结果是进程能起来、`AppDelegate` 却从未被创建 ——
/// 表现为"双击打开什么都没有"，而且不崩溃、不报错。
@main
enum SpacedownMain {

    /// `NSApplication.delegate` 是 weak 的，必须由这里持有。
    @MainActor
    private static let delegate = AppDelegate()

    @MainActor
    static func main() {
        // 诊断用：不起界面，直接打印检查更新的结果
        if CommandLine.arguments.contains("--check-updates") {
            UpdateChecker.printStatus()
            return
        }

        let application = NSApplication.shared
        // 纯代码启动不会自动设激活策略；不设就没有菜单栏、不接收键盘事件
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }
}
