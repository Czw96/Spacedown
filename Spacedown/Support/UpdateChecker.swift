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
            guard let release = Self.release(from: json, version: latest, page: page) else {
                // 缺 zip 或签名：当作"只能手动下载"处理，别假装能自动更新
                if manual { presentManualOnly(latest: latest, page: page) }
                return
            }
            presentUpdate(release)
        } else if manual {
            let alert = NSAlert()
            alert.messageText = "已是最新版本"
            alert.informativeText = "当前版本 \(currentVersion)。"
            // 不显式加按钮的话，AppKit 会给一个英文 "OK"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    /// 从 release JSON 里挑出自动更新需要的三个东西：zip、同名 `.sig`、sha256 摘要。
    ///
    /// 缺任何一个都返回 nil —— 没有签名的包一律不自动安装（见 `UpdateSigning` 的理由）。
    private static func release(from json: [String: Any], version: String, page: String) -> UpdateInstaller.Release? {
        guard let assets = json["assets"] as? [[String: Any]] else { return nil }
        func url(_ asset: [String: Any]) -> URL? {
            (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
        }
        guard let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let archive = url(zip) else { return nil }
        let zipName = zip["name"] as? String ?? ""
        let sigAsset = assets.first { ($0["name"] as? String) == zipName + ".sig" }

        var digest: String?
        if let raw = zip["digest"] as? String, raw.hasPrefix("sha256:") {
            digest = String(raw.dropFirst("sha256:".count))
        }
        return UpdateInstaller.Release(
            version: version,
            page: URL(string: page) ?? URL(string: releasesPage)!,
            archive: archive,
            signature: sigAsset.flatMap(url),
            sha256: digest
        )
    }

    private func presentUpdate(_ release: UpdateInstaller.Release) {
        let alert = NSAlert()
        alert.messageText = "有新版本 \(release.version)"
        alert.informativeText = "当前版本 \(currentVersion)。\n点「立即更新」会自动下载、验签并重启，不用再拖拽。"
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "稍后")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        UpdateProgress.show("正在更新到 \(release.version)…")
        Task { @MainActor in
            do {
                // 成功的话 App 会自己退出，走不到下一行
                try await UpdateInstaller.shared.install(release)
            } catch {
                UpdateProgress.hide()
                presentInstallFailure(error, page: release.page)
            }
        }
    }

    /// 版本更新但没有可用的自动更新资产（或用户选择手动）。
    private func presentManualOnly(latest: String, page: String) {
        let alert = NSAlert()
        alert.messageText = "有新版本 \(latest)"
        alert.informativeText = "当前版本 \(currentVersion)。\n这次发布缺少自动更新所需文件，请手动下载。"
        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: page) {
            NSWorkspace.shared.open(url)
        }
    }

    private func presentInstallFailure(_ error: Error, page: URL) {
        let alert = NSAlert()
        alert.messageText = "自动更新没有完成"
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(page)
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

/// 更新过程中的小浮窗：一个转圈 + 一行字。
///
/// 用面板而不是模态 alert：下载、验签、解压都在后台，主线程不该被一个模态循环占住
/// （`NSApp.terminate` 也需要主线程能继续跑）。
@MainActor
private enum UpdateProgress {

    private static var window: NSPanel?

    static func show(_ text: String) {
        hide()

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 96),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Spacedown 更新"
        // ⚠️ 程序化创建的窗口必须关掉，否则关窗时多释放一次 → 段错误
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 16),
        ])

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        window = panel
    }

    static func hide() {
        window?.orderOut(nil)
        window = nil
    }
}
