import Foundation

/// 导出 Quick Look 诊断报告。
///
/// 为什么由主 App 做：统一日志（`log: Cannot run while sandboxed`）与插件状态
/// （`pluginkit -m` → `unauthorized discovery flag`）在沙箱里都读不到，而主 App 不在沙箱里。
///
/// 开关：`defaults write cn.29dev.Spacedown DebugDumpQLLog -bool true`
/// 打开后每次启动写一份 `~/Desktop/spacedown-ql.txt`。
/// `DebugQLTrigger` 额外触发一次 `qlmanage -p`，`DebugQLClaim` 先跑一遍接管动作。
enum QuickLookDiagnostics {

    private static let reportPath = "Desktop/spacedown-ql.txt"
    private static let defaultProbePath = "Desktop/Spacedown-链接测试.md"

    /// 诊断整段都在后台队列上跑 —— 它可能 sleep、跑 `qlmanage`，
    /// 绝不能挂在启动路径上（那会表现成"双击打不开"）。
    static func exportIfRequested() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "DebugDumpQLLog") else { return }

        let shouldClaim = defaults.bool(forKey: "DebugQLClaim")
        let shouldTrigger = defaults.bool(forKey: "DebugQLTrigger")
        let probe = defaults.string(forKey: "DebugQLProbePath") ?? defaultProbePath

        DispatchQueue.global(qos: .utility).async {
            if shouldClaim {
                QuickLookClaim.claim()
                Thread.sleep(forTimeInterval: 1.5)
            }

            var preview: (pid: Int32, started: Bool)?
            if shouldTrigger {
                preview = triggerPreview(at: probe)
            }

            let report = makeReport(probe: probe, triggered: shouldTrigger, preview: preview)
            write(report)
        }
    }

    // MARK: - 触发一次预览

    /// 起一个 `qlmanage -p` 并等 5 秒（已在后台队列，不挡界面）。
    private static func triggerPreview(at path: String) -> (pid: Int32, started: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return (0, false) }
        Thread.sleep(forTimeInterval: 5)
        process.terminate()
        return (process.processIdentifier, true)
    }

    // MARK: - 报告

    private static func makeReport(
        probe: String,
        triggered: Bool,
        preview: (pid: Int32, started: Bool)?
    ) -> String {
        var report = "# Spacedown · Quick Look 诊断报告\n# \(Date())\n# 探针文件: \(probe)\n"

        if let preview, preview.started {
            report += "# 已触发 qlmanage -p（pid \(preview.pid)），等待 5 秒后终止\n\n"
        } else if triggered {
            report += "# ⚠️ qlmanage 没能启动 —— 第一节必然是空的\n\n"
        } else {
            report += "# 未触发预览（DebugQLTrigger 关闭），只收集既有日志\n\n"
        }

        for section in sections {
            report += "\n## \(section.title)\n"
            report += ProcessRunner.output(of: section.tool, arguments: section.arguments)
        }
        return report
    }

    /// 需要一并取回的几路证据。日志段落是找出"扩展没被调用 / 被别家抢走"的关键：
    /// 前面几节都看不到渲染引擎自己的话，失败原因只会落在系统侧。
    private static let sections: [(title: String, tool: String, arguments: [String])] = [
        ("一、扩展日志（subsystem cn.29dev.Spacedown，近 30 分钟）",
         "/usr/bin/log",
         ["show", "--last", "30m", "--style", "compact",
          "--predicate", "subsystem == \"cn.29dev.Spacedown\""]),

        ("二、系统登记的全部 Quick Look 预览扩展（+ 启用 / - 禁用）",
         "/usr/bin/pluginkit",
         ["-m", "-p", "com.apple.quicklook.preview"]),

        ("三、我们这条",
         "/usr/bin/pluginkit",
         ["-m", "-i", QuickLookClaim.extensionBundleID]),

        ("四、WPS 那条",
         "/usr/bin/pluginkit",
         ["-m", "-i", "com.kingsoft.wpsoffice.mac.WPSQuickLook"]),

        ("五、系统侧关于 Spacedown 的记录（近 30 分钟）",
         "/usr/bin/log",
         ["show", "--last", "30m", "--style", "compact",
          "--predicate", "eventMessage CONTAINS \"Spacedown\""]),

        ("六、quicklookd / pkd 最近的记录（近 30 分钟，可能很长）",
         "/usr/bin/log",
         ["show", "--last", "30m", "--style", "compact",
          "--predicate", "process == \"quicklookd\" OR process == \"pkd\""]),

        ("七、WebKit 渲染引擎自己的记录（近 30 分钟）",
         "/usr/bin/log",
         ["show", "--last", "30m", "--style", "compact",
          "--predicate", "subsystem BEGINSWITH \"com.apple.WebKit\" OR "
              + "process CONTAINS \"WebContent\" OR process CONTAINS \"WebKit\""]),
    ]

    private static func write(_ report: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(reportPath)
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            DebugLog.write("已导出 QL 诊断 → \(url.path)（\(report.utf8.count) 字节）")
        } catch {
            DebugLog.write("导出 QL 诊断失败: \(error.localizedDescription)")
        }
    }
}
