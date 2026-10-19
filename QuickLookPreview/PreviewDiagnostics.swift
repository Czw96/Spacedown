import Foundation
import os

/// 预览扩展的日志与取证工具。
///
/// 统一日志是沙箱里唯一可用的通道（往 `~/Library/Logs` 或 `/tmp` 写文件会被静默拒绝）：
///
///     log stream --predicate 'subsystem == "cn.29dev.Spacedown"' --style compact
enum PreviewDiagnostics {

    static let logger = Logger(subsystem: "cn.29dev.Spacedown", category: "quicklook")

    /// 本类型第一次被访问的时刻，用来量"进程启动 → 收到预览请求"这段看不到的开销。
    static let launchedAt = now()

    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end - start) / 1_000_000
    }

    static func formatted(_ milliseconds: Double) -> String {
        String(format: "%.2f", milliseconds)
    }

    /// 把一行 JSON 追加到磁盘上的候选位置。**只在 Debug 构建里存在**：
    /// 它是取证工具，不该跟着发行版出去（会往 `/tmp` 明文写文件名）。
    ///
    /// 落盘是否成功本身就是被测对象之一 —— 沙箱下这两个路径不一定可写。
    static func record(_ kind: String, _ extra: String = "") {
        #if DEBUG
        let line = """
        {"ts":\(now() / 1_000_000), "kind":"\(kind)", "pid":\(ProcessInfo.processInfo.processIdentifier)\(extra)}
        """
        let data = Data((line + "\n").utf8)
        let paths = [
            "/tmp/spacedown-ql-diag.jsonl",
            NSHomeDirectory() + "/Library/Logs/Spacedown/diag.jsonl",
        ]
        for path in paths {
            let directory = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        #endif
    }
}
