import AppKit

/// §5.2 的那几个颜色在 AppKit 侧的镜像。
///
/// ⚠️ 内容区的颜色**唯一来源**是 `Packages/Core/Sources/SharedTheme/theme.css`，
/// 这里只放 CSS 管不到的地方（标签栏、加载底色）需要的值。
/// 改 theme.css 的 `--accent` / `--bg` 时，同步这里。
///
/// 全部走 `NSColor(name:dynamicProvider:)`，所以跟随系统明暗是自动的，
/// 不需要监听 `effectiveAppearance`。
@MainActor
enum Palette {

    /// 强调色 —— 对应 theme.css `--accent`（浅 `#4f46c9` / 深 `#9b93f2`）
    static let accent = dynamic(light: 0x4f46c9, dark: 0x9b93f2)

    /// 页面底色 —— 对应 theme.css `--bg`（浅 `#ffffff` / 深 `#1b1b1d`）。
    /// 用途只有一个：填 `WKWebView` 文档加载完成前的白闪。
    static let pageBackground = dynamic(light: 0xffffff, dark: 0x1b1b1d)

    /// 当前标签的"底色微抬"。浅色下就是白，深色下靠白色叠加提亮 ——
    /// 直接用系统语义色做不到这一点（`textBackgroundColor` 在深色下和标签栏一样深）。
    static let currentTabFill = NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor(white: 1, alpha: 0.10) : .white
    }

    /// 非当前标签的 hover 底色
    static let hoverTabFill = NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.05)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            isDark(appearance) ? NSColor(srgb: dark) : NSColor(srgb: light)
        }
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

private extension NSColor {
    convenience init(srgb rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1
        )
    }
}
