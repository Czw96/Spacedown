import AppKit
import WebKit
import Foundation

// WebViewBench：单独测 WKWebView 的成本。
//
// 用法：.build/release/WebViewBench <file.html> [<file2.html> ...]
//
// 测三件事，用来验证「解析不是瓶颈、webview 才是」这个判断：
//   1. 冷启动：第一次创建 WKWebView + 载入（含 WebContent 进程 spawn）
//   2. 二次导航：同一个 webview 再载一次（进程已热，只剩导航 + 排版）
//   3. 第二个 webview：再建一个（进程已热，但 webview 是新的）
//
// 注意：不跑 NSApplication.run()，直接用 RunLoop 泵事件，方便测完就退出。

let args = CommandLine.arguments.dropFirst()
guard !args.isEmpty else {
    print("用法: WebViewBench <file.html> [...]")
    exit(2)
}

final class Nav: NSObject, WKNavigationDelegate {
    var finished = false
    var failed = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed = true
        finished = true
        print("  载入失败: \(error.localizedDescription)")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// 窗口放在屏幕外：WKWebView 需要挂在窗口层级里才会正常排版
let screen = NSRect(x: -3000, y: -3000, width: 1000, height: 800)
let window = NSWindow(contentRect: screen, styleMask: [], backing: .buffered, defer: false)

let nav = Nav()

func pump(until condition: @escaping () -> Bool, timeout: TimeInterval = 20) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
    }
}

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b - a) / 1_000_000.0 }

func newWebView() -> WKWebView {
    let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
    wv.navigationDelegate = nav
    window.contentView = wv
    return wv
}

func load(_ wv: WKWebView, _ url: URL) -> Double {
    nav.finished = false
    nav.failed = false
    let t0 = now()
    wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    pump(until: { nav.finished })
    return ms(t0, now())
}

print(String(format: "%-34@ %10@ %10@ %10@", "case" as NSString, "cold ms" as NSString, "nav2 ms" as NSString, "wv2 ms" as NSString))
print(String(repeating: "-", count: 68))

for path in args {
    let url = URL(fileURLWithPath: path)
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attrs[.size] as? Int else { continue }
    let sizeStr = size >= 1_048_576
        ? String(format: "%.1fMB", Double(size) / 1_048_576)
        : String(format: "%dKB", size / 1024)

    // 1. 冷启动
    let wv1 = newWebView()
    let cold = load(wv1, url)

    // 2. 同一 webview 二次导航
    let nav2 = load(wv1, url)

    // 3. 第二个 webview（进程已热）：建实例与载入合并计时
    let t2 = now()
    let wv2 = newWebView()
    _ = load(wv2, url)
    let wv2Total = ms(t2, now())

    print(String(format: "%-34@ %10.1f %10.1f %10.1f",
                 "\(url.lastPathComponent) (\(sizeStr))" as NSString,
                 cold, nav2, wv2Total))
}

print("")
print("cold ms = 首次创建 WKWebView + 载入（含 WebContent 进程 spawn）")
print("nav2 ms = 同一 webview 再载一次（进程已热）")
print("wv2 ms  = 新建第二个 webview + 载入（进程已热）")
