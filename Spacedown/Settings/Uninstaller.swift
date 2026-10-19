import Foundation

/// 卸载：把 App 本体和用户侧残留一起删掉，然后退出。
///
/// App 没法删掉正在运行的自己，所以清理交给 bundle 里的 `uninstall.sh`：
/// 它先等本进程退出，再逐项删除（**不按前缀扫目录** —— 用户目录里不该出现
/// "删一片"的动作）。
enum Uninstaller {

    /// 复制脚本到临时目录再执行。
    ///
    /// 不直接执行 bundle 里的那份：脚本最后会 `rm -rf` 掉自己所在的 bundle，
    /// 边读边删是件不可靠的事。
    static func run() {
        guard let source = Bundle.main.url(forResource: "uninstall", withExtension: "sh") else {
            DebugLog.write("卸载失败：uninstall.sh 不在 bundle 里")
            return
        }

        let script = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spacedown-uninstall.sh")
        do {
            try? FileManager.default.removeItem(at: script)
            try FileManager.default.copyItem(at: source, to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: script.path)
        } catch {
            DebugLog.write("卸载失败：写脚本 \(error.localizedDescription)")
            return
        }

        // nohup + `&`：App 退出之后脚本还得继续跑完
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

    /// 单引号包裹，路径里有空格或引号也安全（`'` 自身转义成 `'\''`）。
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
