import Foundation

/// 文件监听：外部修改 → 窗口自动刷新。
///
/// 每个文件一根 `DispatchSource`。标签数量本来就被 web view 池限制在几十个量级，
/// 不需要 FSEvents 单流那种"任意规模"的方案。
///
/// **单例**：App 只有一个主窗口，一条监听链路就够。做成单例还让事件闭包只捕获
/// `URL`（Sendable），回到主 actor 时取 `shared`，不必在 `@Sendable` 闭包里捕获 `self`。
@MainActor
final class FileWatcher {

    static let shared = FileWatcher()

    /// 去抖窗口。编辑器保存常触发 5~10 个 write 事件。
    private static let debounce: TimeInterval = 0.12

    /// 文件身份 + 修改标记。四元组一致就认为没变，不重渲染。
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

    /// 监听源：盯文件本身，或者盯父目录。
    ///
    /// 两个源不是二选一的美化：
    /// - `.file` 才能接住「原地写」（编辑器改写同一个 inode），
    /// - `.directory` 才能接住「文件消失 → 又在原路径出现」，
    ///   以及原子保存（写临时文件再 rename）之后换掉的 inode。
    private enum WatchKind { case file, directory }

    private struct Entry {
        var fileSource: DispatchSourceFileSystemObject?
        var directorySource: DispatchSourceFileSystemObject?
        var stamp: FileStamp
        /// 文件源此刻盯着的 inode；0 表示只有目录源。
        var watchedInode: ino_t = 0
    }

    private var entries: [URL: Entry] = [:]
    private var debounces: [URL: Task<Void, Never>] = [:]

    /// 变化回调，在主 actor 上调用。
    var onChange: ((URL) -> Void)?

    private init() {}

    /// 把监听集合对齐到这批文件。多退少补，重复调用是幂等的。
    func watch(_ urls: [URL]) {
        let wanted = Set(urls)
        // 先落地成数组再停：`entries.keys` 是字典的视图，边遍历边删是未定义行为
        for url in entries.keys.filter({ !wanted.contains($0) }) {
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
            entry.fileSource = makeSource(.file, url: url)
            entry.watchedInode = stamp.inode
        }
        if entry.fileSource == nil {
            entry.directorySource = makeSource(.directory, url: url)
            entry.watchedInode = 0
        }
        entries[url] = entry
    }

    private func stop(_ url: URL) {
        debounces[url]?.cancel()
        debounces[url] = nil
        guard let entry = entries.removeValue(forKey: url) else { return }
        // fd 在各自的 cancelHandler 里关
        entry.fileSource?.cancel()
        entry.directorySource?.cancel()
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

        let stamp = FileStamp(url)
        guard stamp != entry.stamp else { return }
        rearm(url, stamp: stamp)
        onChange?(url)
    }

    /// 按文件当前的状态换监听源。
    ///
    /// inode 变了就必须重建文件源：旧的 fd 跟着已删除的 inode 走，
    /// 之后再也不会收到事件（表现是预览只刷新一次）。
    private func rearm(_ url: URL, stamp: FileStamp) {
        guard var entry = entries[url] else { return }

        if stamp.exists {
            if entry.fileSource == nil || entry.watchedInode != stamp.inode {
                entry.fileSource?.cancel()
                entry.directorySource?.cancel()
                entry.directorySource = nil
                entry.fileSource = makeSource(.file, url: url)
                entry.watchedInode = entry.fileSource == nil ? 0 : stamp.inode
            }
            // 文件在、但 fd 打不开时退回目录源，至少还能等到它被换掉
            if entry.fileSource == nil, entry.directorySource == nil {
                entry.directorySource = makeSource(.directory, url: url)
            }
        } else if entry.fileSource != nil || entry.directorySource == nil {
            entry.fileSource?.cancel()
            entry.fileSource = nil
            entry.watchedInode = 0
            entry.directorySource = makeSource(.directory, url: url)
        }

        entry.stamp = stamp
        entries[url] = entry
    }

    /// 建一根已 resume 的源。事件闭包只捕获 `URL`，其余走 `shared`。
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
