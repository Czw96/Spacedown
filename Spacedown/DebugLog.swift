import Foundation

/// 极简调试日志，写 `/tmp/spacedown-debug.log`。
///
/// 为什么不用 `os.Logger` / `NSLog`：这台机器上 `log show` 报
/// `Cannot run while sandboxed`（跳出沙箱也一样），而 App 是双击启动的，
/// stderr 没有地方看。所以直接写文件 —— 土，但一定拿得到。
///
/// 开关（UserDefaults 而不是环境变量：`open --env` 送进来的变量**到不了 App 进程**，实测）：
///
/// ```bash
/// defaults write cn.29dev.Spacedown DebugLayout -bool true
/// # …复现…
/// cat /tmp/spacedown-debug.log
/// defaults delete cn.29dev.Spacedown DebugLayout
/// ```
@MainActor
enum DebugLog {

    static let path = "/tmp/spacedown-debug.log"

    private static var truncated = false

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "DebugLayout")
    }

    static func write(_ line: String) {
        guard isEnabled else { return }

        var payload = Data()
        if !truncated {
            truncated = true
            try? FileManager.default.removeItem(atPath: path)
            payload.append(Data("--- Spacedown launch \(Date()) ---\n".utf8))
        }
        payload.append(Data((line + "\n").utf8))

        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(payload)
            try? handle.synchronize()
            handle.closeFile()
        } else {
            try? payload.write(to: URL(fileURLWithPath: path))
        }
    }
}
