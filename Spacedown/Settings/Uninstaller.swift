import AppKit

/// 卸载：清理用户侧残留并退出。
///
/// 两段式：
/// 1. **立即**把 App 移进废纸篓 —— 用户点完就能看到结果，也给了反悔的余地；
/// 2. 退出后由 `uninstall.sh` 完成 App 自己做不到的部分（偏好、缓存、系统登记）。
///
/// 脚本先复制到临时目录再执行：它最后会删掉来源 bundle，边读边删不可靠。
@MainActor
enum Uninstaller {

    static func run(permanently: Bool) {
        unregisterSystemEntries()
        guard let script = stageScript() else { return }
        launch(script)

        if permanently {
            if removeBundle() {
                NSApp.terminate(nil)
                return
            }
            // 删不掉（bundle 被占用等）就退回废纸篓，别让用户卡在"什么都没发生"
        }
        recycleAndQuit()
    }

    /// 直接从磁盘删除 bundle。失败时由调用方退回废纸篓。
    private static func removeBundle() -> Bool {
        do {
            try FileManager.default.removeItem(at: Bundle.main.bundleURL)
            return true
        } catch {
            DebugLog.write("直接删除失败：\(error.localizedDescription)，改移废纸篓")
            return false
        }
    }

    /// 趁 bundle 还在原路径，先注销系统登记 —— 移进废纸篓之后这个路径就不存在了，
    /// 按路径注销会落空。脚本里还会再做一遍，重复调用是幂等的。
    private static func unregisterSystemEntries() {
        ProcessRunner.launch("/usr/bin/pluginkit",
                             arguments: ["-e", "ignore", "-i", "cn.29dev.Spacedown.QuickLookPreview"])
        ProcessRunner.launch(QuickLookClaim.lsregisterPath,
                             arguments: ["-u", Bundle.main.bundlePath])
    }

    // MARK: - 脚本

    private static func stageScript() -> URL? {
        guard let source = Bundle.main.url(forResource: "uninstall", withExtension: "sh") else {
            DebugLog.write("卸载失败：uninstall.sh 不在 bundle 里")
            return nil
        }

        let script = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spacedown-uninstall.sh")
        do {
            try? FileManager.default.removeItem(at: script)
            try FileManager.default.copyItem(at: source, to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: script.path)
            return script
        } catch {
            DebugLog.write("卸载失败：写脚本 \(error.localizedDescription)")
            return nil
        }
    }

    /// `nohup + &`：App 退出之后脚本还得继续跑完。
    private static func launch(_ script: URL) {
        let command = ["nohup", "/bin/bash", shellQuoted(script.path),
                       shellQuoted(Bundle.main.bundlePath), "\(getpid())",
                       shellQuoted(FileManager.default.homeDirectoryForCurrentUser.path)]
            .joined(separator: " ") + " >/dev/null 2>&1 &"

        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/bin/bash")
        runner.arguments = ["-c", command]
        do {
            try runner.run()
        } catch {
            DebugLog.write("卸载失败：无法启动脚本 \(error.localizedDescription)")
        }
    }

    // MARK: - 立即效果

    /// 把 App 移进废纸篓再退出。
    ///
    /// 回收失败（bundle 被占用等）不影响卸载：脚本会用 `rm -rf` 兜底。
    private static func recycleAndQuit() {
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
            // 回调是 nonisolated 的，取好字符串再跳回主 actor
            let reason = error?.localizedDescription
            Task { @MainActor in
                if let reason {
                    DebugLog.write("移入废纸篓失败：\(reason)，交给脚本删除")
                }
                NSApp.terminate(nil)
            }
        }
        // 回调迟迟不来时别卡住用户；terminate 幂等，重复调用无副作用
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            NSApp.terminate(nil)
        }
    }

    /// 单引号包裹，路径里有空格或引号也安全（`'` 自身转义成 `'\''`）。
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
