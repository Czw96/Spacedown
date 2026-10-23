import AppKit

/// 检查新版本。
///
/// 数据源是公开发布仓库的 `releases/latest`（源码仓库是私有的，那里没有可匿名读取的
/// Release）。只做**检测与提示**：真正的替换交给安装方式（dmg / brew），
/// 避免在没有签名的前提下自己重写 Sparkle 那套原子替换逻辑。
@MainActor
final class UpdateChecker {

    static let shared = UpdateChecker()

    nonisolated private static let feed = URL(string: "https://api.github.com/repos/Czw96/homebrew-spacedown/releases/latest")!
    private static let releasesPage = "https://github.com/Czw96/homebrew-spacedown/releases"
    private static let lastCheckKey = "UpdateLastCheck"
    private static let interval: TimeInterval = 24 * 3600

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// 启动时调用：24 小时内只查一次，失败静默。
    func autoCheckIfNeeded() {
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > Self.interval else { return }
        check(manual: false)
    }

    /// `manual` 决定"已是最新"和"检查失败"要不要弹窗 —— 自动检查只在有新版本时打扰用户。
    func check(manual: Bool) {
        var request = URLRequest(url: Self.feed)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, _, error in
            Task { @MainActor in
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
                self.handle(data: data, error: error, manual: manual)
            }
        }.resume()
    }

    // MARK: - 结果

    private func handle(data: Data?, error: Error?, manual: Bool) {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            if manual { presentFailure(error) }
            return
        }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let page = (json["html_url"] as? String) ?? Self.releasesPage

        if Self.isNewer(latest, than: currentVersion) {
            presentUpdate(latest: latest, page: page)
        } else if manual {
            let alert = NSAlert()
            alert.messageText = "已是最新版本"
            alert.informativeText = "当前版本 \(currentVersion)。"
            // 不显式加按钮的话，AppKit 会给一个英文 "OK"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    private func presentUpdate(latest: String, page: String) {
        let alert = NSAlert()
        alert.messageText = "有新版本 \(latest)"
        alert.informativeText = "当前版本 \(currentVersion)。\n下载新版本后拖进「应用程序」覆盖即可。"
        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: page) {
            NSWorkspace.shared.open(url)
        }
    }

    private func presentFailure(_ error: Error?) {
        let alert = NSAlert()
        alert.messageText = "检查更新失败"
        alert.informativeText = error?.localizedDescription ?? "无法连接发布仓库，请稍后再试。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - 版本比较

    /// 按点分数字比较（`1.0.10 > 1.0.9`），非数字段按 0 处理。
    nonisolated static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - 命令行自检

    /// `Spacedown --check-updates`：不启动界面，直接打印检查结果。
    /// 用于排查「检查更新没反应」——能分清是网络不通还是版本号判断出错。
    nonisolated static func printStatus() {
        let semaphore = DispatchSemaphore(value: 0)
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

        var request = URLRequest(url: feed)
        request.timeoutInterval = 12
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                print("检查失败：\(error?.localizedDescription ?? "响应格式不对")")
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            print("当前版本：\(current)")
            print("最新版本：\(latest)")
            print(isNewer(latest, than: current) ? "有新版本" : "已是最新")
        }.resume()

        _ = semaphore.wait(timeout: .now() + 20)
    }
}
