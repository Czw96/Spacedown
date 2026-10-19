import AppKit

/// 内容区之外的那几个界面色。
///
/// 内容区的颜色唯一来源是 `theme.css`，这里只放 CSS 管不到的地方（标签栏、加载底色）。
/// 改动 `--accent` / `--bg` 时需要同步这里，`pageBackground` 就是为了在文档加载完成前
/// 不闪一块白。
///
/// 全部走 `NSColor(name:dynamicProvider:)`，跟随系统明暗是自动的。
@MainActor
public enum Palette {

    /// 页面底色，对应 `theme.css` 的 `--bg`。
    public static let pageBackground = dynamic(light: 0xFFFFFF, dark: 0x1B1B1D)

    /// 窗口底色（标签栏那一圈 + 内容卡片四周的留白）。
    /// 比内容暗一档，内容才有"一张纸浮在上面"的分层感。
    public static let chromeBackground = dynamic(light: 0xF2F2F3, dark: 0x131315)

    /// 当前标签的"底色微抬"。深色下靠叠一层白提亮 ——
    /// 系统语义色做不到这一点（`textBackgroundColor` 在深色下与标签栏一样深）。
    public static let currentTabFill = NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor(white: 1, alpha: 0.10) : .white
    }

    /// 非当前标签的悬停底色。
    public static let hoverTabFill = NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.05)
    }

    public static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(srgb: isDark(appearance) ? dark : light)
        }
    }

    public static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

private extension NSColor {
    convenience init(srgb rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
