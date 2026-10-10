import Foundation

/// 文件监听：外部修改 → 窗口自动刷新（docs/技术方案.md §7.3）。
///
/// 取的是 §7.3 里"每文件一个 `DispatchSource`"那条（标注为 ≤20 个文件"够用"），
/// 而不是 FSEvents 单流。单流的收益是"任意规模"，代价是要写 C 回调 + 自己按路径分发；
/// 而标签数本来就被 LRU 池和 UI 限制在几十个量级，换不回来。
///
/// **单例**：App 只有一个主窗口，一条监听链路就够。做成单例还有个额外好处 ——
/// 事件闭包只捕获 `URL`（Sendable），回到主 actor 时取 `shared`，
/// 不需要在 `@Sendable` 闭包里捕获 `self`（Swift 6 下那会直接编译不过）。
@MainActor
final class FileWatcher {

    static let shared = FileWatcher()

    /// 去抖窗口。编辑器保存常触发 5~10 个 write 事件。
    private static let debounce: TimeInterval = 0.12

    /// 文件身份 + 修改标记。四元组一致就认为没变，不重渲染 —— 这是省 CPU 的大头。
    struct FileStamp: Equatable {
        var device: dev_t = 0
        var inode: ino_t = 0
        var size: off_t = 0
        var mtime: TimeInterval = 0

        init() {}

        init(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            mtime = TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        }

        var exists: Bool { inode != 0 }
    }

    /// 监听什么。**两个源不是二选一的美化，是功能必需**：
    ///
    /// - `.file` 盯文件本身，才能接住「原地写」（编辑器直接改写同一个 inode）；
    /// - `.dir` 盯父目录的目录项变化，才能接住「文件消失 → 又在原路径出现」。
    ///
    /// 只盯文件的话，`rm` 掉再写回同名文件时，旧 fd 攥着的是**已删除的那个 inode**，
    /// 新文件是另一个 inode —— 此后一个事件都收不到，预览再也不刷新（旧实现正是这么漏的）。
    /// 反过来只盯目录也不行：原地写不改变目录项，只有文件源能收到。
    private enum WatchKind { case file, dir }

    private struct Entry {
        var file: DispatchSourceFileSystemObject?
        var dir: DispatchSourceFileSystemObject?
        var stamp: FileStamp
    }

    private var entries: [URL: Entry] = [:]
    private var debounces: [URL: Task<Void, Never>] = [:]

    /// 变化回调。**在主 actor 上调用**。
    var onChange: ((URL) -> Void)?

    private init() {}

    /// 把监听集合对齐到给定的这批文件。多退少补，重复调用是幂等的。
    func watch(_ urls: [URL]) {
        let wanted = Set(urls)
        for url in Array(entries.keys) where !wanted.contains(url) {
            stop(url)
        }
        for url in wanted where entries[url] == nil {
            start(url)
        }
    }

    // MARK: - 内部

    private func start(_ url: URL) {
        let stamp = FileStamp(url)
        var entry = Entry(stamp: stamp)
        if stamp.exists {
            entry.file = makeSource(.file, url: url)
        }
        // 文件不存在（或连 fd 都开不出来）时先用目录源占位
        if entry.file == nil {
            entry.dir = makeSource(.dir, url: url)
        }
        entries[url] = entry
    }

    private func stop(_ url: URL) {
        debounces[url]?.cancel()
        debounces[url] = nil
        guard let entry = entries.removeValue(forKey: url) else { return }
        // 关 fd 在各自的 cancelHandler 里做
        entry.file?.cancel()
        entry.dir?.cancel()
    }

    private func receive(_ url: URL) {
        debounces[url]?.cancel()
        debounces[url] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.settle(url)
        }
    }

    private func settle(_ url: URL) {
        debounces[url] = nil
        guard let entry = entries[url] else { return }

        let now = FileStamp(url)
        guard now != entry.stamp else { return }   // 没变就不重渲染 —— 省 CPU 的大头

        // 原子保存（写临时文件再 rename）会换 inode，文件被删会让 stamp 归零：
        // 两种都由 rearm 决定接下来该盯哪一根源。
        entries[url]?.stamp = now
        rearm(url, fileExists: now.exists, hadFileSource: entry.file != nil)
        onChange?(url)
    }

    /// 在「文件在 / 不在」之间切换时换一根监听源。
    private func rearm(_ url: URL, fileExists: Bool, hadFileSource: Bool) {
        if fileExists, !hadFileSource {
            entries[url]?.dir?.cancel()
            entries[url]?.dir = nil
            entries[url]?.file = makeSource(.file, url: url)
        } else if !fileExists, hadFileSource {
            entries[url]?.file?.cancel()
            entries[url]?.file = nil
            entries[url]?.dir = makeSource(.dir, url: url)
        }
    }

    /// 建一根已 resume 的源。事件闭包只捕获 `URL`，别的一律走 `shared` —— 见类型注释。
    private func makeSource(_ kind: WatchKind, url: URL) -> DispatchSourceFileSystemObject? {
        let path = kind == .file ? url.path : url.deletingLastPathComponent().path
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        let mask: DispatchSource.FileSystemEvent = kind == .file
            ? [.write, .delete, .rename, .extend, .attrib]
            : [.write, .delete, .rename]
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: mask,
            queue: .main
        )
        source.setEventHandler { [url] in
            Task { @MainActor in
                FileWatcher.shared.receive(url)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        return source
    }
}
