import AppKit

/// 带布局钩子的窗口。
///
/// 存在的唯一理由：交通灯位置自愈。AppKit 会在上屏、成为 key、改尺寸等时机重新布局
/// 标题栏，把挪过的按钮摆回原位；挂到 `layoutIfNeeded()` 上就变成自愈 ——
/// 无论 AppKit 什么时候重排，排完立刻再对齐一次。
///
/// 不会死循环：对齐时先比对目标位置，已经对齐就直接返回。
final class SpacedownWindow: NSWindow {

    var onLayout: (() -> Void)?

    /// ⚠️ 必须关掉 `isReleasedWhenClosed`，否则关窗时段错误崩溃。
    ///
    /// 程序化创建的 `NSWindow` 这个标志默认为 `true`：关窗时 AppKit 释放窗口一次，
    /// 而控制器还持有一份强引用，ARC 之后再释放一次就是"多释放一次"。
    /// 崩溃栈上没有任何业务代码（`objc_release` → autorelease pool drain），
    /// 从崩溃报告里看不出原因，所以这里显式关掉。
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style,
                   backing: backingStoreType, defer: flag)
        isReleasedWhenClosed = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("只走代码路径") }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        onLayout?()
    }
}
