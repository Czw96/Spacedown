import WebKit

import SharedTheme

/// 注入页面的滚动帧率探针。
///
/// 采样是**被动**的：程序化滚动用户看得见，所以挂在 `scroll` 事件上 ——
/// 用户自己滚的那一瞬间才开始记帧间隔，停下来约 180ms 出一份统计。
@MainActor
enum ScrollProbe {

    static let messageName = "scrollProbe"

    static let script = WKUserScript(source: """
    (function () {
        var frames = [], raf = 0, idle = 0, last = 0, running = false;
        function tick(ts) {
            if (last) { frames.push(ts - last); }
            last = ts;
            if (frames.length < 900) { raf = requestAnimationFrame(tick); }
        }
        function stop() {
            running = false;
            if (raf) { cancelAnimationFrame(raf); raf = 0; }
            var n = frames.length;
            if (n < 4) { return; }
            var sorted = frames.slice().sort(function (a, b) { return a - b; });
            var sum = 0;
            for (var i = 0; i < n; i++) { sum += frames[i]; }
            window.webkit.messageHandlers.\(messageName).postMessage({
                count: n,
                mean: sum / n,
                p50: sorted[Math.floor(n * 0.5)],
                p95: sorted[Math.floor(n * 0.95)],
                worst: sorted[n - 1],
                dropped: frames.filter(function (d) { return d > 17.0; }).length
            });
            frames = []; last = 0;
        }
        window.addEventListener('scroll', function () {
            if (!running) { running = true; frames = []; last = 0; raf = requestAnimationFrame(tick); }
            if (idle) { clearTimeout(idle); }
            idle = setTimeout(stop, 180);
        }, { passive: true });
    })();
    """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)

    /// 一次采样。fps 由实际帧间隔均值反推。
    struct Sample {
        let frames: Int
        let fps: Double
        let p50: Double
        let p95: Double
        let worst: Double
        let dropped: Int

        init?(body: Any) {
            guard let payload = body as? [String: Any],
                  let frames = payload["count"] as? Int else { return nil }
            let mean = payload["mean"] as? Double ?? 0
            self.frames = frames
            self.fps = mean > 0 ? 1000 / mean : 0
            self.p50 = payload["p50"] as? Double ?? 0
            self.p95 = payload["p95"] as? Double ?? 0
            self.worst = payload["worst"] as? Double ?? 0
            self.dropped = payload["dropped"] as? Int ?? 0
        }
    }
}
