import AppKit

/// 卸载：彻底删除 App 本体与用户侧残留，然后退出。
///
/// **不进废纸篓**。运行中的 App 可以删掉自己的 bundle —— 进程持有的是已经 unlink 的
/// inode，直到退出都不受影响（实测 `FileManager.removeItem` 返回成功、原路径消失）。
/// 万一删不掉（权限、bundle 被占用），退出后的 `uninstall.sh` 会再删一次作为兜底。
@MainActor
enum Uninstaller {

    static func run() {
        unregisterSystemEntries()

        guard let script = stageScript() else {
            // 脚本丢了也要尽量把自己删掉，别让用户点了没反应
            removeBundle()
            NSApp.terminate(nil)
            return
        }
        launch(script)
        removeBundle()
        NSApp.terminate(nil)
    }

    /// 趁 bundle 还在原路径，先注销系统登记 —— 删除之后这个路径就不存在了，
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
            DebugLog.write("卸载：uninstall.sh 不在 bundle 里")
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
            DebugLog.write("卸载：写脚本失败 \(error.localizedDescription)")
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
            DebugLog.write("卸载：无法启动脚本 \(error.localizedDescription)")
        }
    }

    // MARK: - 删除本体

    private static func removeBundle() {
        do {
            try FileManager.default.removeItem(at: Bundle.main.bundleURL)
            DebugLog.write("卸载：已删除 \(Bundle.main.bundlePath)")
        } catch {
            DebugLog.write("卸载：直接删除失败（\(error.localizedDescription)），交给脚本")
        }
    }

    /// 单引号包裹，路径里有空格或引号也安全（`'` 自身转义成 `'\''`）。
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
