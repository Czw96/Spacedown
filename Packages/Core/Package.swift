// swift-tools-version:6.0
import PackageDescription

// 仅 macOS。版本号必须与 `scripts/gen_project.py` 的 MACOS_MIN 以及 README 里的
// "目标机"口径一致 —— 两套构建链路的生效版本不同的话，`swift build` 出来的工具
// 会比 App 更宽松。
let package = Package(
    name: "SpacedownCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MarkdownKit", targets: ["MarkdownKit"]),
        .library(name: "SharedTheme", targets: ["SharedTheme"]),
    ],
    targets: [
        // vendored cmark-gfm。不裁剪渲染器：latex/man/plaintext/commonmark/xml
        // 一并编入，避免改 CMake 依赖图。extensions/*.c 会 include "parser.h" /
        // "html.h"，这些内部头留在 src/ 下，所以显式加一条搜索路径。
        //
        // -O3 + -mcpu=apple-m1：项目只支持 Apple Silicon（不做 universal2）。
        // 若将来要恢复 x86_64，这两条必须一起去掉。
        .target(
            name: "CcmarkGfm",
            cSettings: [
                .headerSearchPath("src"),
                .unsafeFlags(["-O3", "-mcpu=apple-m1"]),
            ]
        ),
        // 渲染外壳 + 共享视图层（主题、色板、Toast、链接语义、文档装载）。
        // 主 App 与 Quick Look 扩展共用，避免两端各写一份。
        .target(
            name: "SharedTheme",
            resources: [.copy("theme.css")],
            // 让 SharedTheme 知道自己在 SwiftPM 下构建（Xcode 构建时没有 Bundle.module）
            swiftSettings: [.define("SPACEDOWN_SPM_BUILD")]
        ),
        .target(name: "MarkdownKit", dependencies: ["CcmarkGfm"]),

        // 开发期工具，不参与 App 打包
        .executableTarget(
            name: "Bench",
            dependencies: ["MarkdownKit", "SharedTheme"],
            path: "Sources/DevTools/Bench"
        ),
        .executableTarget(name: "WebViewBench", path: "Sources/DevTools/WebViewBench"),
        .executableTarget(name: "ScrollBench", path: "Sources/DevTools/ScrollBench"),
    ]
)
