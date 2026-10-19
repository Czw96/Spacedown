import AppKit
import WebKit

import SharedTheme

/// 布局自检。只在 `DebugLayout` 打开时输出，用于确认那些"差几个 pt"的几何关系。
extension MainWindow {

    /// 交通灯、标签栏、缩放三件套的中线，以及版心相关的菜单项。
    func dumpLayout() {
        guard DebugLog.isEnabled else { return }
        window.layoutIfNeeded()

        DebugLog.write("layout windowHeight=\(logNumber(window.frame.height)) "
            + "tabBarHeight=\(logNumber(TabBarView.height)) tabs=\(tabs.count) current=\(currentIndex)")

        for (name, type) in [("close", NSWindow.ButtonType.closeButton),
                             ("miniaturize", .miniaturizeButton),
                             ("zoom", .zoomButton)] {
            guard let view = window.standardWindowButton(type) else { continue }
            let rect = view.convert(view.bounds, to: nil)
            DebugLog.write("  \(name) centerFromTop=\(logNumber(window.frame.height - rect.midY))")
        }

        let bar = tabBar.convert(tabBar.bounds, to: nil)
        DebugLog.write("  tabBar topFromTop=\(logNumber(window.frame.height - bar.maxY)) "
            + "centerFromTop=\(logNumber(window.frame.height - bar.midY))")

        if let first = tabBar.debugFirstTabFrame {
            DebugLog.write("  firstTab x=\(logNumber(first.minX)) "
                + "topFromTop=\(logNumber(window.frame.height - first.maxY)) "
                + "size=\(logNumber(first.width))x\(logNumber(first.height))")
        }

        // 缩放三件套必须落在同一条中线上（数字按 cap 高中线算），差一点都看得出来
        for (name, fromTop) in tabBar.debugZoomCentersFromTop ?? [] {
            DebugLog.write("  \(name) centerFromTop=\(logNumber(fromTop))")
        }

        dumpMeasureMenu()
    }

    /// 版心宽度那几行菜单项的当前状态。
    func dumpMeasureMenu() {
        let actions: Set<Selector> = [
            #selector(widenMeasure(_:)), #selector(narrowMeasure(_:)), #selector(resetMeasure(_:)),
        ]
        let items = NSApp.mainMenu?.item(withTitle: "显示")?.submenu?.items.filter { item in
            item.tag == AppMenu.measureInfoTag || (item.action.map(actions.contains) ?? false)
        } ?? []

        DebugLog.write("menu[显示] 版心相关条目 \(items.count) 条")
        for item in items {
            DebugLog.write("  「\(item.title)」 enabled=\(item.isEnabled) state=\(item.state.rawValue)")
        }
    }

    /// 版心 / 缩放自检：把「设置值 → 实际宽度 → 要不要横向滚」记进日志。
    ///
    /// - 设置 `MeasurePercent` 之后，占比应当接近该值；
    /// - 放大之后横向滚动必须仍是"无"（`pageZoom` 会重排；`magnification` 会变成"有"）。
    func logContentWidth(_ view: WKWebView) {
        guard DebugLog.isEnabled else { return }
        view.evaluateJavaScript("""
        (function () {
            var content = document.querySelector('.content');
            if (!content) { return null; }
            var root = document.documentElement;
            return { content: Math.round(content.getBoundingClientRect().width),
                     viewport: window.innerWidth,
                     layoutWidth: root.scrollWidth,
                     needsHorizontalScroll: root.scrollWidth > window.innerWidth };
        })()
        """) { [weak self] result, _ in
            guard let self,
                  let data = result as? [String: Any],
                  let content = (data["content"] as? NSNumber)?.doubleValue,
                  let viewport = (data["viewport"] as? NSNumber)?.doubleValue,
                  let layoutWidth = (data["layoutWidth"] as? NSNumber)?.doubleValue else { return }

            let needsScroll = (data["needsHorizontalScroll"] as? NSNumber)?.boolValue ?? false
            let ratio = viewport > 0 ? content / viewport * 100 : 0
            DebugLog.write("  版心=\(logNumber(content)) viewport=\(logNumber(viewport)) "
                + "设置=\(MeasureSettings.percent)% 实际占比=\(logNumber(ratio))% "
                + "zoom=\(logNumber(Double(self.currentTab?.zoom ?? 1))) 布局宽=\(logNumber(layoutWidth)) "
                + "横向滚动=\(needsScroll ? "有 ← 出问题了" : "无")")
        }
    }

    /// 在标签栏下方短暂显示一条提示。
    func showToast(_ text: String) {
        guard let content = window.contentView else { return }
        Toast.show(text, in: content, placement: .top(inset: 26))
    }
}
