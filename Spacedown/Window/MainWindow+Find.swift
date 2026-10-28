import AppKit
import WebKit

/// 查找：⌘F 打开浮动查找条，⌘G / ⇧⌘G 前后跳。
///
/// 检索本身交给 `WKWebView.find(_:configuration:completionHandler:)`（macOS 11+）：
/// 它会在 Web 进程里做匹配并原生高亮，我们不需要往文档里注入高亮 span ——
/// 那样既会改到渲染结果，也会在重新载入时留下脏东西。
///
/// 代价是拿不到"第几个 / 共几个"：`WKFindResult` 只有一个 `matchFound`。
/// 所以查找条只显示「无结果」，不假装有计数。
extension MainWindow {

    /// ⌘F。没有打开的文档时什么都不做，别弹一个找不到东西的条。
    @objc func showFind(_ sender: Any?) {
        guard currentTab != nil else { return }
        findBar.present(in: webHost)
    }

    /// ⌘G / ↩ / 下箭头。
    @objc func findNext(_ sender: Any?) {
        performFind(backwards: false)
    }

    /// ⇧⌘G / ⇧↩ / 上箭头。
    @objc func findPrevious(_ sender: Any?) {
        performFind(backwards: true)
    }

    /// 收起查找条，焦点还给内容区。
    func dismissFind() {
        guard !findBar.isHidden else { return }
        findBar.dismiss()
        if let tab = currentTab, let view = pool.residentView(for: tab) {
            window.makeFirstResponder(view)
        }
    }

    /// 把查找条的输入接到查找逻辑上。在 `buildContent()` 之后调一次。
    func wireFindBar() {
        findBar.onQueryChange = { [weak self] text in
            guard let self else { return }
            // 空串不做任何事：清空输入不该再跳。
            guard !text.isEmpty else { return }
            performFind(backwards: false)
        }
        findBar.onNext = { [weak self] in self?.findNext(nil) }
        findBar.onPrevious = { [weak self] in self?.findPrevious(nil) }
        findBar.onClose = { [weak self] in self?.dismissFind() }
    }

    private func performFind(backwards: Bool) {
        let query = findBar.query
        guard !query.isEmpty, let tab = currentTab,
              let view = pool.residentView(for: tab) else { return }

        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        // wraps 默认就是 true：找到末尾再按一次会从头开始，跟浏览器一致
        configuration.wraps = true

        view.find(query, configuration: configuration) { [weak self] result in
            self?.findBar.showStatus(result.matchFound ? nil : "无结果")
        }
    }
}
