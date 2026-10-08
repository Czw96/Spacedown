import AppKit

/// 真正的程序入口。
///
/// ⚠️ **为什么不能给 `AppDelegate` 直接标 `@main`。**
///
/// AppKit 给 `NSApplicationDelegate` 提供了一个默认的 `main()`，但它的实现只有一行：
///
/// ```swift
/// extension NSApplicationDelegate {
///     public static func main() {
///         exit(NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv))
///     }
/// }
/// ```
///
/// 它把"创建 delegate"这件事**完全交给了 nib**（`NSApplicationMain` 会去读
/// `NSMainNibFile`，在 nib 里实例化 delegate 并连线）。
///
/// 而这个工程是纯代码启动、**没有 nib**。结果是：进程起得来、`NSApplication` 也在跑，
/// 但 **`AppDelegate` 从来没有被实例化过** —— `applicationWillFinishLaunching`、
/// `application(_:open:)` 一个都不会被调用，也就不会出现任何窗口。
/// 表现就是"双击打开什么都没有"，而且**不崩溃、不报错、留不下任何日志**，极难定位
/// （靠 `DebugLog` 逐点打点才找到）。
///
/// 所以这里自己把 delegate 建出来接上。
@main
enum SpacedownMain {

    /// `NSApplication.delegate` 是 **weak** 的，必须有别的地方持有它，
    /// 否则会被立刻释放掉 —— 又是"什么都没有"。
    @MainActor
    private static let delegate = AppDelegate()

    @MainActor
    static func main() {
        let application = NSApplication.shared
        // 纯代码启动不会自动设激活策略；不设的话进程能跑但没有菜单栏、不接收键盘事件
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }
}
