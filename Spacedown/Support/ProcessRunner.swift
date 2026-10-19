import Foundation

/// 跑命令行工具。只用于系统工具（`pluginkit` / `qlmanage` / `lsregister` / `log`）。
enum ProcessRunner {

    /// 只启动、不等待。给那些可能长时间不返回的工具（`qlmanage -r`）用。
    static func launch(_ path: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
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
