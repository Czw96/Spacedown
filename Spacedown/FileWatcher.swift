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

    private struct Entry {
        let source: DispatchSourceFileSystemObject
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
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = Self.makeSource(descriptor: descriptor, url: url)
        entries[url] = Entry(source: source, stamp: FileStamp(url))
        source.resume()
    }

    private func stop(_ url: URL) {
        debounces[url]?.cancel()
        debounces[url] = nil
        guard let entry = entries.removeValue(forKey: url) else { return }
        // 关 fd 在 cancelHandler 里做
        entry.source.cancel()
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
        guard now != entry.stamp else { return }

        // 原子保存（写临时文件再 rename）会换 inode，旧 fd 已经盯不住新文件了，重挂
        if now.exists && now.inode != entry.stamp.inode {
            stop(url)
            start(url)
        } else {
            entries[url]?.stamp = now
        }
        guard now.exists else { return }
        onChange?(url)
    }

    /// 事件闭包只捕获 `URL`，别的一律走 `shared` —— 见类型注释。
    private static func makeSource(descriptor: Int32, url: URL) -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
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
        return source
    }
}
