import Foundation

/// 往固定路径的日志文件里追加一行。
///
/// ⚠️ `/tmp` 是**全局可写**目录：别的本地用户可以事先在那里摆一个指向任意文件的符号
/// 链接，等我们以写方式打开，内容就落进那个文件里。所以这里一律用 `O_NOFOLLOW` 打开 ——
/// 一旦发现是链接就放弃写日志（能写日志是便利，不该成为攻击面）。
enum FileLog {

    /// 追加一行。`truncate` 为真时先把文件清空（启动时重建日志用）。
    ///
    /// - Returns: 是否写入成功。
    @discardableResult
    static func append(_ line: String, to path: String, truncate: Bool = false) -> Bool {
        let flags = truncate
            ? O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW
            : O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW
        let descriptor = open(path, flags, 0o600)
        guard descriptor >= 0 else { return false }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: Data((line + "\n").utf8))
            try handle.synchronize()
            return true
        } catch {
            return false
        }
    }
}
