import Foundation

/// 极简调试日志，写 `/tmp/spacedown-debug.log`。
///
/// 不用 `os.Logger`：这台机器上 `log show` 在受限环境里读不到，而 App 是双击启动的，
/// stderr 也没有地方看。直接写文件，土，但一定拿得到。
///
/// 开关走 UserDefaults（`open --env` 送进来的环境变量到不了 App 进程）：
///
///     defaults write cn.29dev.Spacedown DebugLayout -bool true
///     cat /tmp/spacedown-debug.log
///     defaults delete cn.29dev.Spacedown DebugLayout
enum DebugLog {

    static let path = "/tmp/spacedown-debug.log"

    /// 每次启动的第一条日志会重建文件，所以要知道"这次启动写过没有"。
    private static let lock = NSLock()
    /// 由 `lock` 保护；`nonisolated(unsafe)` 只是让 Swift 6 允许这个可变全局。
    nonisolated(unsafe) private static var started = false

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "DebugLayout")
    }

    /// 线程安全：可能同时被主线程与后台诊断队列调用。
    static func write(_ line: String) {
        guard isEnabled else { return }

        lock.lock()
        defer { lock.unlock() }

        // 首次写入时重建文件，并留下本次启动的时间戳
        if !started {
            started = true
            FileLog.append("--- Spacedown launch \(Date()) ---", to: path, truncate: true)
        }
        FileLog.append(line, to: path)
    }
}

/// 日志里的小数：统一保留一位。
func logNumber(_ value: Double) -> String {
    String(format: "%.1f", value)
}
