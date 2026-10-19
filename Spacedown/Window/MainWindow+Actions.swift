import AppKit

import SharedTheme

/// 菜单与工具栏动作。
extension MainWindow {

    // MARK: - 打开与关闭

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = MarkdownFileType.openPanelTypes
        // 本机有些 markdown 扩展名被别家认领成各自的 UTI，不在白名单里会被灰掉；
        // 这里是逐文件明确指定，所以放开这一层。
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        // 只剩一个标签时 ⌘W 关窗口，和浏览器一致
        if currentIndex >= 0 && tabs.count > 1 {
            closeTab(at: currentIndex)
        } else {
            window.performClose(sender)
        }
    }

    /// 右键菜单里的"关闭标签"：关的是右键点中的那个，不是当前标签。
    @objc func closeTabFromMenu(_ sender: NSMenuItem) {
        closeTab(at: sender.tag)
    }

    @objc func closeOtherTabsFromMenu(_ sender: NSMenuItem) {
        closeOthers(keeping: sender.tag)
    }

    @objc func nextTab(_ sender: Any?) {
        guard tabs.count > 1 else { return }
        select((currentIndex + 1) % tabs.count)
    }

    @objc func previousTab(_ sender: Any?) {
        guard tabs.count > 1 else { return }
        select((currentIndex - 1 + tabs.count) % tabs.count)
    }

    @objc func selectTab(_ sender: NSMenuItem) {
        // ⌘9 固定跳到最后一个（浏览器惯例），不是"第 9 个"
        select(sender.tag >= 9 ? tabs.count - 1 : sender.tag - 1)
    }

    @objc func reloadDocument(_ sender: Any?) {
        guard let tab = currentTab, let view = pool.residentView(for: tab) else { return }
        load(tab, into: view, restoreScroll: true)
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = currentTab?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func openInDefaultEditor(_ sender: Any?) {
        guard let url = currentTab?.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 缩放

    /// 缩放走 `pageZoom`，**不是 `magnification`**。
    ///
    /// `magnification` 只把画面视觉放大、不重排：版心宽度（CSS px）不变，视口能看到的
    /// 内容却变少，必然压出横向滚动条。`pageZoom` 改的是布局缩放，视口变窄、内容跟着
    /// 重排折行，永远不会横向滚。
    ///
    /// 所以捏合缩放（`allowsMagnification`）也一并关掉 —— 它属于前者，留着会重新引入
    /// 同一个问题，两套缩放叠加还会互相干扰。入口保留 ⌘+ / ⌘− / ⌘0 与工具栏三件套。
    private static let zoomRange: ClosedRange<CGFloat> = 0.25...5.0

    @objc func zoomIn(_ sender: Any?) {
        setZoom((currentTab?.zoom ?? 1) * 1.1)
    }

    @objc func zoomOut(_ sender: Any?) {
        setZoom((currentTab?.zoom ?? 1) / 1.1)
    }

    @objc func zoomActualSize(_ sender: Any?) {
        setZoom(1)
    }

    func setZoom(_ value: CGFloat) {
        guard let tab = currentTab, let view = pool.residentView(for: tab) else { return }
        let clamped = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        view.pageZoom = clamped
        // web view 是复用的，切换标签时缩放不会自己回到 1，所以模型必须记住
        tab.zoom = clamped
        updateZoomLabel()
    }

    func updateZoomLabel() {
        tabBar.setZoomPercent(Int((currentTab?.zoom ?? 1) * 100))
    }

    // MARK: - 版心宽度

    @objc func widenMeasure(_ sender: Any?) {
        setMeasure(MeasureSettings.percent + MeasureSettings.step)
    }

    @objc func narrowMeasure(_ sender: Any?) {
        setMeasure(MeasureSettings.percent - MeasureSettings.step)
    }

    @objc func resetMeasure(_ sender: Any?) {
        setMeasure(MeasureSettings.full)
    }

    func setMeasure(_ value: Int) {
        let clamped = MeasureSettings.clamp(value)
        // 已经顶到边界就不做无谓的重渲染
        guard clamped != MeasureSettings.percent else { return }
        MeasureSettings.percent = clamped
        applyMeasureChange()
    }

    /// 版心宽度变了：当前标签立刻重渲染，其余实例标记为"内容过期"。
    ///
    /// 这是**渲染期参数**（写进 HTML 的覆盖样式里），不是纯 CSS 变量，
    /// 所以必须重新出 HTML —— 同一份文件也要重来。
    private func applyMeasureChange() {
        pool.invalidateContent()

        guard let tab = currentTab, let view = pool.residentView(for: tab) else { return }
        // 先取回眼下读到哪儿了，重渲染后滚回原处
        view.evaluateJavaScript("window.scrollY") { [weak self] result, _ in
            guard let self else { return }
            tab.scrollY = (result as? NSNumber)?.doubleValue ?? 0
            self.load(tab, into: view, restoreScroll: true)
        }
    }

    // MARK: - 菜单校验

    /// 顶到上/下界时把对应条目灰掉，「铺满」顺带用勾表示当前状态。
    ///
    /// ⚠️ 对不认识的条目必须返回 true：这个方法一旦实现就接管了整张菜单的启用判定，
    /// 漏掉一条（比如缩放、切标签）会让它莫名其妙变灰。
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(widenMeasure(_:)):
            return MeasureSettings.percent < MeasureSettings.full

        case #selector(narrowMeasure(_:)):
            return MeasureSettings.percent > MeasureSettings.minimum

        case #selector(resetMeasure(_:)):
            let isFull = MeasureSettings.percent == MeasureSettings.full
            item.state = isFull ? .on : .off
            return !isFull

        default:
            return true
        }
    }

    // MARK: - 空格预览

    /// 接管 markdown 的空格预览。
    ///
    /// 系统设置里没有「快速查看」这一类目的扩展开关，所以这个菜单项是唯一入口；
    /// 动作本身要跑 `pluginkit`，只能由非沙箱的主 App 在后台执行。
    @objc func claimQuickLookPreview(_ sender: Any?) {
        DispatchQueue.global(qos: .utility).async {
            QuickLookClaim.claim()
        }
        showToast("已请求接管空格预览，几秒后生效")
    }
}

extension MainWindow: NSMenuItemValidation {}
