// swift-tools-version:6.0
import PackageDescription

// 仅 macOS：见 docs/技术方案.md「平台范围」
//
// ⚠️ 版本号必须与 `scripts/gen_project.py` 的 MACOS_MIN（13.0）以及 README /
// 技术方案里的"目标机"口径一致。这里曾写 .v12，而 App target 是 13.0 ——
// 两套构建链路的生效版本不同，`swift build` 出来的工具会比 App 更宽松。
let package = Package(
    name: "SpacedownCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MarkdownKit", targets: ["MarkdownKit"]),
        .library(name: "SharedTheme", targets: ["SharedTheme"]),
    ],
    targets: [
        // vendored cmark-gfm 0.29.0.gfm.7（C 源码在 Sources/CcmarkGfm/src 与 extensions）
        // 不裁剪渲染器：latex/man/plaintext/commonmark/xml 一并编入，避免改 CMake 依赖图。
        // extensions/*.c 会 #include "parser.h" / "html.h"，这些内部头留在 src/ 下，
        // 因此显式加一条搜索路径；include/ 由 SwiftPM 自动加入（对 Swift 公开的那几个头）。
        //
        // -O3 + -mcpu=apple-m1：项目只支持 M 系列（不做 universal2），所以可以放心
        // 按架构指定调度模型。注意 SwiftPM 的 cSettings 无法按架构分支，
        // 如果哪天要恢复 x86_64，这两条必须一起去掉。
        .target(
            name: "CcmarkGfm",
            cSettings: [
                .headerSearchPath("src"),
                .unsafeFlags(["-O3", "-mcpu=apple-m1"]),
            ]
        ),
        .target(
            name: "SharedTheme",
            resources: [.copy("theme.css")],
            // 让 SharedTheme 知道自己在 SwiftPM 下构建（Xcode 构建时没有 Bundle.module）
            swiftSettings: [.define("SPACEDOWN_SPM_BUILD")]
        ),
        .target(name: "MarkdownKit", dependencies: ["CcmarkGfm"]),
        .executableTarget(name: "Bench", dependencies: ["MarkdownKit", "SharedTheme"]),
        // 单独测 WKWebView 成本的 M0 spike 工具（AppKit + WebKit）
        .executableTarget(name: "WebViewBench"),
        // 滚动主线程成本：同一个 HTML 跑多种 CSS 变体，横向比较帧间隔
        .executableTarget(name: "ScrollBench"),
    ]
)
