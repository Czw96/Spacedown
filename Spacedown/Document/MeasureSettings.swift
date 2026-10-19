import Foundation

import SharedTheme

/// 版心宽度偏好的唯一读写口。
///
/// 语义是「占**可用宽度**的百分比」：`full`（100）= 铺满，两侧只留内容区的内边距；
/// 90 = 两侧各留 5%。值写进 `UserDefaults`，下次启动还在。
///
/// ⚠️ Quick Look 扩展读不到它：App 与扩展是两个 UserDefaults 域，工程里也没有
/// App Group。所以空格预览固定按 100%。
enum MeasureSettings {

    private static let key = "MeasurePercent"

    /// 铺满，同时是取值上界。
    static let full = SharedTheme.fullMeasurePercent
    /// 下界。再窄下去标题会频繁折行，反而更难读。
    static let minimum = 40
    /// 每次加宽/收窄的步长。
    static let step = 10

    static var percent: Int {
        get { clamp(UserDefaults.standard.object(forKey: key) as? Int ?? full) }
        set { UserDefaults.standard.set(clamp(newValue), forKey: key) }
    }

    static func clamp(_ value: Int) -> Int {
        min(full, max(minimum, value))
    }
}
