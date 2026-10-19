import Foundation

/// 让 markdown 的空格预览归本 App —— 幂等的"修复"动作。
///
/// 四步缺一不可：
/// 1. `lsregister -f` 把 App 重新登记进 LaunchServices（只登记，不要 `-u`）
/// 2. `pluginkit -a` 把扩展加进 pkd 的插件表（`-e` 只能改状态，加不回来）
/// 3. `pluginkit -e use` 选我们、`-e ignore` 关掉 WPS 的同类型扩展
/// 4. `qlmanage -r` 让 Quick Look 重建索引
///
/// 只能在**非沙箱**进程里跑（`pluginkit -e` 在沙箱里会被拒绝），所以入口在主 App 的菜单。
/// 关掉 WPS 那条是安全的：它的 QL 扩展只认 markdown，docx / xlsx 走系统
/// `Office.qlgenerator`，不受影响。
enum QuickLookClaim {

    static let extensionBundleID = "cn.29dev.Spacedown.QuickLookPreview"
    private static let wpsBundleID = "com.kingsoft.wpsoffice.mac.WPSQuickLook"
    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/"
        + "Frameworks/LaunchServices.framework/Support/lsregister"

    /// 执行整套动作。同步阻塞约 2.4 秒，调用方不要放在主线程上。
    static func claim() {
        let appex = Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/QuickLookPreview.appex").path

        let steps: [(path: String, arguments: [String])] = [
            (lsregister, ["-f", Bundle.main.bundlePath]),
            ("/usr/bin/pluginkit", ["-a", appex]),
            ("/usr/bin/pluginkit", ["-e", "use", "-i", extensionBundleID]),
            ("/usr/bin/pluginkit", ["-e", "ignore", "-i", wpsBundleID]),
            ("/usr/bin/qlmanage", ["-r"]),
            ("/usr/bin/qlmanage", ["-r", "cache"]),
        ]

        for step in steps {
            ProcessRunner.launch(step.path, arguments: step.arguments)
            // 不等 `waitUntilExit()`：`qlmanage -r` 可能长时间不返回，会把调用方挂住
            Thread.sleep(forTimeInterval: 0.4)
        }
        DebugLog.write("已接管空格预览：登记 + pluginkit -a + 选举 + 重建索引")
    }
}
