import Foundation

/// 跑命令行工具。只用于系统工具（`pluginkit` / `qlmanage` / `lsregister` / `log` / `ditto`）。
enum ProcessRunner {

    /// 只启动、不等待。给那些可能长时间不返回的工具（`qlmanage -r`）用。
    ///
    /// 子进程的输出接 `/dev/null` 而不是 `Pipe()`：没人读的管道写满之后会把这个
    /// 我们并不打算等的进程堵死。
    static func launch(_ path: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// 跑完并返回退出码；启动失败返回 nil。
    @discardableResult
    static func status(_ path: String, arguments: [String]) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// 跑完并收回 stdout + stderr（合并）。
    static func output(of path: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else {
                return "（输出不是 UTF-8，\(data.count) 字节）\n"
            }
            return text.isEmpty ? "（无输出，退出码 \(process.terminationStatus)）\n" : text
        } catch {
            return "（无法运行 \(path)：\(error.localizedDescription)）\n"
        }
    }
}
