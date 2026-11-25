import AppKit

/// 检查新版本。
///
/// 数据源是本仓库的 `releases/latest`。只做**检测与提示**：真正的替换交给安装方式（dmg），
/// 避免在没有签名的前提下自己重写 Sparkle 那套原子替换逻辑。
@MainActor
final class UpdateChecker {

    static let shared = UpdateChecker()

    nonisolated private static let feed = URL(string: "https://api.github.com/repos/Czw96/Spacedown/releases/latest")!
    private static let releasesPage = "https://github.com/Czw96/Spacedown/releases"
    /// 正在显示的更新面板。不持有引用的话，窗口一失去焦点就可能被释放。
    private var prompt: UpdatePromptWindow?
    /// 已下载校验完、等待用户点「重新启动」的包。
    private var preparedUpdate: UpdateInstaller.Prepared?

    private static let lastCheckKey = "UpdateLastCheck"
    private static let interval: TimeInterval = 24 * 3600

    /// 裸可执行文件（`--check-updates` 自检）里没有版本号，按 0 处理 —— 任何发布都算更新。
    var currentVersion: String { AppInfo.marketingVersion ?? "0" }

    /// 启动时调用：24 小时内只查一次，失败静默。
    func autoCheckIfNeeded() {
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > Self.interval else { return }
        check(manual: false)
    }

    /// `manual` 决定"已是最新"和"检查失败"要不要弹窗 —— 自动检查只在有新版本时打扰用户。
    func check(manual: Bool) {
        // 面板已经开着就别再开一个：连点两次菜单会叠出两个同样的窗口
        if let prompt {
            prompt.show()
            return
        }
        var request = URLRequest(url: Self.feed)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            Task { @MainActor in
                self.handle(data: data, response: response, error: error, manual: manual)
            }
        }.resume()
    }

    // MARK: - 结果

    private func handle(data: Data?, response: URLResponse?, error: Error?, manual: Bool) {
        guard let data,
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            // 失败不记时间戳：否则一次网络抖动就能让自动检查静默一整天
            if manual { presentFailure(error) }
            return
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let page = (json["html_url"] as? String) ?? Self.releasesPage

        if Self.isNewer(latest, than: currentVersion) {
            guard let release = Self.release(from: json, version: latest) else {
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
    private static func release(from json: [String: Any], version: String) -> UpdateInstaller.Release? {
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
            archive: archive,
            signature: sigAsset.flatMap(url),
            sha256: digest
        )
    }

    private func presentUpdate(_ release: UpdateInstaller.Release) {
        let prompt = UpdatePromptWindow(version: release.version,
                                        currentVersion: currentVersion)
        prompt.onInstall = { [weak self, weak prompt] in
            guard let self, let prompt else { return }
            self.startInstall(release, in: prompt)
        }
        prompt.onLater = { [weak self, weak prompt] in
            if let prepared = self?.preparedUpdate {
                UpdateInstaller.shared.discard(prepared)
                self?.preparedUpdate = nil
            }
            prompt?.orderOut(nil)
            self?.prompt = nil
        }
        prompt.onRestart = { [weak self] in
            guard let prepared = self?.preparedUpdate else { return }
            // apply 里会启动换包脚本并退出 App，走不到下一行
            try? UpdateInstaller.shared.apply(prepared)
        }
        prompt.onCancel = {
            UpdateInstaller.shared.cancel()
        }
        self.prompt = prompt
        prompt.show()
    }

    /// 点「立即更新」之后：先下载 + 校验，完成后停在「重新启动」，不擅自重启。
    private func startInstall(_ release: UpdateInstaller.Release, in prompt: UpdatePromptWindow) {
        prompt.beginProgress()
        Task { @MainActor in
            do {
                let prepared = try await UpdateInstaller.shared.prepare(release) { phase in
                    switch phase {
                    case .downloading(let fraction):
                        prompt.updateProgress(fraction, note: "正在下载…")
                    case .verifying:
                        prompt.updateProgress(nil, note: "正在校验更新包…")
                    case .preparing:
                        prompt.updateProgress(nil, note: "正在准备…")
                    }
                }
                self.preparedUpdate = prepared
                prompt.showReady(version: release.version)
            } catch is CancellationError {
                // 用户自己点的取消：回到初始态，让他能再点一次
                UpdateInstaller.note("用户取消更新")
                prompt.reset()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                UpdateInstaller.note("更新失败：\(message)")
                prompt.showFailure(message)
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
        let current = AppInfo.marketingVersion ?? "0"

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
