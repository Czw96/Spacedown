import Foundation

/// Bundle 身份信息的唯一读取口。
///
/// 版本号散落在「关于」面板、设置窗、更新检查三处，各写一次 `object(forInfoDictionaryKey:)`
/// 就会出现三种兜底值。统一到这里，谁再要读都不必重复拼 key。
enum AppInfo {

    /// bundle 里真实的 `CFBundleShortVersionString`。裸可执行文件里没有这一项。
    static let marketingVersion: String? =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    /// 界面上显示的版本号。缺版本号时给一个像样的兜底，别让用户看到 "版本 0"。
    static let version: String = marketingVersion ?? "1.0"

    /// `CFBundleDisplayName` → `CFBundleName` → 可执行文件名。
    static let name: String = {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = Bundle.main.object(forInfoDictionaryKey: key) as? String, !name.isEmpty {
                return name
            }
        }
        return ProcessInfo.processInfo.processName
    }()
}
