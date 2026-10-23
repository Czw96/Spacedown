import Foundation
import MarkdownKit
import SharedTheme

// spacedown-bench：解析吞吐基准。
// 用法：
//   spacedown-bench                      合成语料，默认 5 档 × 各 N 次
//   spacedown-bench --file <path.md>     对单个真实文件重复测
//   spacedown-bench --iter 500
//
// 输出 p50/p95/p99 与吞吐（MB/s）。结果记进 docs/benchmarks.md。

struct Bench {
    let name: String
    let bytes: Int          // 输入字节数
    let times: [Double]     // 毫秒
    var p50: Double { quantile(0.50) }
    var p95: Double { quantile(0.95) }
    var p99: Double { quantile(0.99) }
    var minMs: Double { quantile(0.0) }
    var throughputMBs: Double {
        // 用 p50 算吞吐
        let mb = Double(bytes) / 1_048_576.0
        return mb / (p50 / 1000.0)
    }
    private func quantile(_ q: Double) -> Double {
        guard !times.isEmpty else { return 0 }
        let s = times.sorted()
        let idx = min(s.count - 1, max(0, Int((Double(s.count - 1) * q).rounded())))
        return s[idx]
    }
}

func nowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

// MARK: - 合成语料

/// 生成约 `targetBytes` 字节的 Markdown。结构贴近真实文档：
/// 标题 / 段落 / 列表 / 表格 / 代码块 / 链接 / 强调 混合。
func makeCorpus(targetBytes: Int) -> Data {
    var parts: [String] = []
    var size = 0
    var i = 0
    while size < targetBytes {
        parts.append("""
        ## 章节 \(i) 标题

        这是一段用于基准测试的正文，包含 **加粗**、*斜体*、[链接](https://29dev.cn) 与 `行内代码`。
        段落需要有足够长度才能逼近真实 README 的形态，因此这里继续补充一些中文与 English 混排的文本。

        - 列表项 \(i)-1，带 **强调**
        - 列表项 \(i)-2，带 [链接](https://example.com/a/b/c)
          - 嵌套项 \(i)-2-1
          - 嵌套项 \(i)-2-2

        1. 有序项 \(i)-1
        2. 有序项 \(i)-2

        | 名称 | 数量 | 单价 | 备注 |
        | --- | ---: | ---: | --- |
        | 键盘 | \(i) | 399.00 | 机械 |
        | 显示器 | \(i + 1) | 1299.00 | 4K |
        | 线缆 | \(i + 2) | 19.90 | ~~降价~~ |

        ```swift
        let value = items.filter { $0.count > \(i) }
            .map { $0.name }
            .joined(separator: ", ")
        print(value)
        ```

        > 引用块 \(i)：引用里也能有 **强调** 与 `代码`。

        - [ ] 未完成任务 \(i)
        - [x] 已完成任务 \(i)

        ---
        """)
        let last = parts.last ?? ""
        size += last.utf8.count
        i += 1
    }
    return Data(parts.joined(separator: "\n\n").utf8)
}

/// 病态输入：深层嵌套引用 + 大量未闭合括号。验证不会出现指数级退化。
func makePathological() -> Data {
    var s = ""
    for i in 0..<2000 { s += String(repeating: ">", count: 1) + " 嵌套层 \(i)\n" }
    s += "\n" + String(repeating: "[a](b", count: 20_000) + "\n"
    s += "\n" + String(repeating: "*强调", count: 30_000) + "\n"
    return Data(s.utf8)
}

// MARK: - 主流程

let args = CommandLine.arguments
func value(_ flag: String, default d: String) -> String {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return d }
    return args[i + 1]
}
let iterations = Int(value("--iter", default: "200")) ?? 200

let renderer = MarkdownRenderer()

func run(name: String, data: Data, iterations: Int) -> Bench {
    // 预热：把 cmark 的扩展注册、以及第一次的缺页/分支预测成本挪出计时区间
    _ = renderer.renderHTML(data)
    _ = renderer.renderHTML(data)

    var times: [Double] = []
    times.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let t0 = nowNanos()
        let html = renderer.renderHTML(data)
        let t1 = nowNanos()
        // 防止优化器把整段干掉
        if html.utf8.count < 0 { print("unreachable") }
        times.append(Double(t1 - t0) / 1_000_000.0)
    }
    return Bench(name: name, bytes: data.count, times: times)
}

func printRow(_ b: Bench) {
    let kb = Double(b.bytes) / 1024
    let sizeStr = kb >= 1024 ? String(format: "%.1f MB", kb / 1024) : String(format: "%.0f KB", kb)
    print(String(
        format: "%-14@ %9@ %9.3f %9.3f %9.3f %9.3f %10.1f",
        b.name as NSString, sizeStr as NSString, b.minMs, b.p50, b.p95, b.p99, b.throughputMBs
    ))
}

print("Spacedown Bench · MarkdownKit")
print(String(format: "swift: %@", ProcessInfo.processInfo.operatingSystemVersionString as NSString))
print("")
print(String(
    format: "%-14@ %9@ %9@ %9@ %9@ %9@ %10@",
    "case" as NSString, "size" as NSString, "min ms" as NSString,
    "p50 ms" as NSString, "p95 ms" as NSString, "p99 ms" as NSString, "MB/s" as NSString
))
print(String(repeating: "-", count: 72))

if let idx = args.firstIndex(of: "--file"), idx + 1 < args.count {
    // 相对路径按当前工作目录解析，打错很常见——给一句能看懂的报错，别裸崩
    let path = args[idx + 1]
    let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    let data: Data
    do {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
    } catch {
        print("读不到文件：\(url.path)")
        exit(1)
    }
    if args.contains("--print") {
        print(renderer.renderHTML(data))
    } else if let oi = args.firstIndex(of: "--out"), oi + 1 < args.count {
        // 端到端：Markdown → HTML 片段 → SharedTheme 完整文档 → 落盘，供肉眼检查。
        // 带上基准目录，相对路径图片才会像 App 里那样内联成 base64（只影响 --out，
        // 计时与 --print 不内联，避免把文件 IO 算进渲染耗时）。
        let body = Data(renderer.renderHTML(data).utf8)
        let doc = SharedTheme.document(body: body, baseDirectory: url.deletingLastPathComponent())
        try! doc.write(to: URL(fileURLWithPath: args[oi + 1]))
        print("wrote \(doc.count) bytes -> \(args[oi + 1])")
    } else {
        printRow(run(name: url.lastPathComponent, data: data, iterations: iterations))
    }
} else {
    // 小文件多跑、大文件少跑，避免总时长失控
    let plan: [(String, Int, Int)] = [
        ("1KB",    1_024,        max(iterations, 500)),
        ("10KB",   10_240,       max(iterations, 500)),
        ("50KB",   51_200,       iterations),
        ("500KB",  512_000,      min(iterations, 100)),
        ("5MB",    5_242_880,    min(iterations, 20)),
    ]
    for (name, size, iter) in plan {
        let data = makeCorpus(targetBytes: size)
        printRow(run(name: name, data: data, iterations: iter))
    }
    printRow(run(name: "pathological", data: makePathological(), iterations: min(iterations, 20)))
}

print("")
print("注：本基准只测『Markdown → HTML』，不含 WKWebView 载入——后者才是端到端耗时的主体。")
