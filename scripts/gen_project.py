#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 Spacedown.xcodeproj。

为什么用脚本而不是手写 project.pbxproj：
pbxproj 里每个对象都要 24 位十六进制 UUID，且相互引用的地方有几十处，
手写漏一个引用 xcodebuild 只报 "object not found"，排查成本很高。

用法：python3 scripts/gen_project.py
改结构（加源码文件 / 加 target）时重跑一次即可。

⚠️ 为什么工程里**没有** SwiftPM 包引用：
Xcode 接入本地 SwiftPM 包时会先跑一遍「Resolve Package Graph」，那一步要编译
Package.swift manifest，而 SwiftPM 会把 manifest 编译塞进 sandbox-exec。
本机（以及 CI 上带沙箱的 shell）里 sandbox-exec 套受限 profile 一律
`Operation not permitted` —— 连 `(version 1)(deny default)` 都过不去，
所以整条 SwiftPM 链路不可用。改成原生 target 后，Xcode 与 `swift build` 各自独立、
互不依赖，两边都能编。
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
XCODEPROJ = ROOT / "Spacedown.xcodeproj"
CORE = "Packages/Core"

# ---------------------------------------------------------------- 对象 ID 分配

_ids: dict[str, str] = {}
_seq = 0


def oid(name: str) -> str:
    global _seq
    if name not in _ids:
        _seq += 1
        _ids[name] = "%024X" % _seq
    return _ids[name]


def ref_of(name: str) -> str:
    """带注释的引用写法，pbxproj 里的惯例。"""
    return "%s /* %s */" % (oid(name), name)


# ---------------------------------------------------------------- 源码清单

def c_sources(sub: str) -> list[str]:
    root = ROOT / CORE / "Sources" / "CcmarkGfm" / sub
    return sorted(str(p.relative_to(ROOT)) for p in root.glob("*.c"))


CCMARK_SOURCES = c_sources("src") + c_sources("extensions")
MARKDOWNKIT_SOURCES = ["Packages/Core/Sources/MarkdownKit/MarkdownRenderer.swift"]
SHAREDTHEME_SOURCES = ["Packages/Core/Sources/SharedTheme/Theme.swift"]
SHAREDTHEME_RESOURCE = "Packages/Core/Sources/SharedTheme/theme.css"

APP_SOURCES = [
    "Spacedown/SpacedownMain.swift",
    "Spacedown/AppDelegate.swift",
    "Spacedown/DebugLog.swift",
    "Spacedown/MainMenu.swift",
    "Spacedown/MainWindow.swift",
    "Spacedown/TabBar.swift",
    "Spacedown/WebViewPool.swift",
    "Spacedown/DocumentTab.swift",
    "Spacedown/FileWatcher.swift",
    "Spacedown/Palette.swift",
    "Spacedown/SettingsWindow.swift",
]
APP_PLIST = "Spacedown/Info.plist"
APP_ICON = "Spacedown/AppIcon.icns"      # app icon (.icns, CFBundleIconFile)
EXT_SOURCES = ["QuickLookPreview/PreviewViewController.swift"]
EXT_PLIST = "QuickLookPreview/Info.plist"

# XPC 服务：替沙箱里的扩展打开外部链接（沙箱里调 NSWorkspace 会让进程被 SIGTRAP 杀掉）。
LINKOPENER_SOURCES = ["LinkOpener/main.swift", "LinkOpener/LinkOpenerProtocol.swift"]
LINKOPENER_PLIST = "LinkOpener/Info.plist"
# 协议文件要**同时**编译进扩展和服务两个 target，但它物理上属于 LinkOpener/ ——
# 一个文件只能有一个 fileRef，所以不能塞进 EXT_SOURCES（那个会驱动组的孩子，路径会错）。
EXT_SHARED_SOURCES = ["LinkOpener/LinkOpenerProtocol.swift"]

MODULEMAP_DIR = "Packages/Core/XcodeSupport/CcmarkGfm"

# 文件引用的 `path` 是**相对所在 group** 的（sourceTree = <group>），不是相对仓库根。
# 每个 target 的 group 都自带 path，所以这里再剥一层前缀。
GROUP_BASES = [
    "Packages/Core/Sources/CcmarkGfm",
    "Packages/Core/Sources/MarkdownKit",
    "Packages/Core/Sources/SharedTheme",
    "Spacedown",
    "QuickLookPreview",
    "LinkOpener",
]


def rel_for(p: str) -> str:
    for base in GROUP_BASES:
        if p.startswith(base + "/"):
            return p[len(base) + 1:]
    raise SystemExit("文件不属于任何已知 group 基目录: " + p)

# ---------------------------------------------------------------- 构建设置

MACOS_MIN = "13.0"

PROJECT_COMMON = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "GCC_WARN_UNUSED_VARIABLE": "YES",
    "MACOSX_DEPLOYMENT_TARGET": MACOS_MIN,
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "SDKROOT": "macosx",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "SWIFT_VERSION": "6.0",
    # CcmarkGfm 是静态库，它的 clang module 只存在于 XcodeSupport 那份 modulemap 里。
    # MarkdownKit 的 swiftmodule 带着对它的依赖，所以**所有**会 import MarkdownKit 的
    # target 都得能找到这份 modulemap，否则报
    # "Unable to resolve module dependency: 'CcmarkGfm'"（踩过）。
    "SWIFT_INCLUDE_PATHS": '"$(SRCROOT)/Packages/Core/XcodeSupport/CcmarkGfm"',
}

PROJECT_DEBUG = {
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": ('("DEBUG=1", "$(inherited)",)', True),
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"',
    "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
}

PROJECT_RELEASE = {
    "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
    "ENABLE_NS_ASSERTIONS": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
}

# 签名：本机没有任何 codesigning identity（security find-identity 返回 0 个），
# 只能 ad-hoc。M6 做公证分发时必须换成 Developer ID 并打开 hardened runtime。
SIGNING = {
    "CODE_SIGN_IDENTITY": '"-"',
    "CODE_SIGN_STYLE": "Manual",
    "ENABLE_HARDENED_RUNTIME": "NO",
}

VERSIONING = {
    "CURRENT_PROJECT_VERSION": "1",
    "MARKETING_VERSION": "1.0",
}

CCMARK_SETTINGS = {
    "DEFINES_MODULE": "YES",
    "EXECUTABLE_EXTENSION": "a",
    "HEADER_SEARCH_PATHS": ('(\n\t\t\t\t\t"$(SRCROOT)/Packages/Core/Sources/CcmarkGfm/src",\n'
                            '\t\t\t\t\t"$(SRCROOT)/Packages/Core/Sources/CcmarkGfm/include",\n'
                            '\t\t\t\t\t"$(SRCROOT)/Packages/Core/Sources/CcmarkGfm/extensions",\n'
                            '\t\t\t\t)', True),
    "MODULEMAP_FILE": '"$(SRCROOT)/Packages/Core/XcodeSupport/CcmarkGfm/module.modulemap"',
    "OTHER_CFLAGS": ('("-O3", "-mcpu=apple-m1",)', True),
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SKIP_INSTALL": "YES",
}

# MarkdownKit 是 framework：让 `import MarkdownKit` 走 -F 自动发现，最稳。
# 内部静态链 CcmarkGfm.a，所以宿主不需要 embed 它。
MARKDOWNKIT_SETTINGS = {
    "DEFINES_MODULE": "YES",
    # framework 也要 Info.plist 才能签名；这里没有自定义项，交给 Xcode 自动生成
    "GENERATE_INFOPLIST_FILE": "YES",
    # @rpath 必须加引号：旧式 plist 里裸 `@` 是非法字符（会整个工程读不出来）
    "DYLIB_INSTALL_NAME_BASE": '"@rpath"',
    "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks",)',
    "PRODUCT_BUNDLE_IDENTIFIER": "cn.29dev.Spacedown.MarkdownKit",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SKIP_INSTALL": "YES",
}

SHAREDTHEME_SETTINGS = {
    "DEFINES_MODULE": "YES",
    "GENERATE_INFOPLIST_FILE": "YES",
    # @rpath 必须加引号：旧式 plist 里裸 `@` 是非法字符（会整个工程读不出来）
    "DYLIB_INSTALL_NAME_BASE": '"@rpath"',
    "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks",)',
    "PRODUCT_BUNDLE_IDENTIFIER": "cn.29dev.Spacedown.SharedTheme",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SKIP_INSTALL": "YES",
}

APP_SETTINGS = {
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "Spacedown/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/../Frameworks",)',
    "PRODUCT_BUNDLE_IDENTIFIER": "cn.29dev.Spacedown",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SKIP_INSTALL": "NO",
}

EXT_SETTINGS = {
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "QuickLookPreview/Info.plist",
    # ⚠️ 必需：**App 扩展必须沙箱化**，否则 macOS 静默不加载它 ——
    # 表现为"扩展永远不会被拉起（日志一行都没有）+ 系统设置里看不到它 + 空格预览
    # 退回去用别家扩展"。完整归因见 docs/技术方案.md §15.6 与那个 entitlements 文件里的注释。
    "CODE_SIGN_ENTITLEMENTS": "QuickLookPreview/QuickLookPreview.entitlements",
    # appex 嵌在 App 的 Contents/PlugIns 下，比 App 深两级，所以补一条向上四级的路径
    "LD_RUNPATH_SEARCH_PATHS": ('(\n\t\t\t\t\t"$(inherited)",\n'
                                '\t\t\t\t\t"@executable_path/../Frameworks",\n'
                                '\t\t\t\t\t"@executable_path/../../../../Frameworks",\n'
                                '\t\t\t\t)', True),
    "PRODUCT_BUNDLE_IDENTIFIER": "cn.29dev.Spacedown.QuickLookPreview",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SKIP_INSTALL": "YES",
    "WRAPPER_EXTENSION": "appex",
}

# XPC 服务：**刻意不带 app-sandbox 权限** —— 它的存在意义就是替沙箱里的扩展
# 做那件被沙箱禁止的事（打开链接）。加了沙箱等于自废武功。
LINKOPENER_SETTINGS = {
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": LINKOPENER_PLIST,
    "MACH_O_TYPE": "mh_execute",
    "PRODUCT_BUNDLE_IDENTIFIER": "cn.29dev.Spacedown.LinkOpener",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SKIP_INSTALL": "YES",
    "WRAPPER_EXTENSION": "xpc",
}


# ---------------------------------------------------------------- 片段生成

def settings_block(settings: dict) -> str:
    lines = []
    for key in sorted(settings):
        value = settings[key]
        if isinstance(value, tuple):
            value = value[0]
        lines.append("\t\t\t\t%s = %s;" % (key, value))
    return "\n".join(lines)


def build_config(ident: str, name: str, base: dict, extra: dict) -> str:
    merged = dict(base)
    merged.update(extra)
    return (
        "\t\t%s /* %s */ = {\n"
        "\t\t\tisa = XCBuildConfiguration;\n"
        "\t\t\tbuildSettings = {\n%s\n\t\t\t};\n"
        "\t\t\tname = %s;\n"
        "\t\t};\n" % (ident, name, settings_block(merged), name)
    )


def file_ref(ident: str, path: str, filetype: str) -> str:
    return (
        "\t\t%s /* %s */ = {\n"
        "\t\t\tisa = PBXFileReference;\n"
        "\t\t\tlastKnownFileType = %s;\n"
        "\t\t\tpath = \"%s\";\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};\n" % (ident, Path(path).name, filetype, path)
    )


def group(ident: str, children: list[str], name: str | None = None,
          path: str | None = None) -> str:
    body = "".join("\t\t\t\t%s,\n" % c for c in children)
    extra = ""
    if name:
        extra += "\t\t\tname = %s;\n" % name
    if path:
        extra += "\t\t\tpath = \"%s\";\n" % path
    st = "" if (name or path) else "\t\t\tsourceTree = \"<group>\";\n"
    return (
        "\t\t%s /* %s */ = {\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n%s\t\t\t);\n%s%s"
        "\t\t};\n" % (ident, name or path or "Group", body, extra, st)
    )


def sources_phase(ident: str, pairs: list[tuple[str, str]]) -> str:
    body = "".join(
        "\t\t\t\t%s /* %s in Sources */,\n" % (bf, Path(p).name)
        for bf, p in pairs)
    return (
        "\t\t%s /* Sources */ = {\n"
        "\t\t\tisa = PBXSourcesBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n%s\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n" % (ident, body))


def empty_phase(ident: str, isa: str, comment: str) -> str:
    return (
        "\t\t%s /* %s */ = {\n"
        "\t\t\tisa = %s;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n" % (ident, comment, isa))


def files_phase(ident: str, isa: str, comment: str,
                items: list[tuple[str, str]], extra: str = "") -> str:
    body = "".join("\t\t\t\t%s /* %s */,\n" % (bf, label) for bf, label in items)
    return (
        "\t\t%s /* %s */ = {\n"
        "\t\t\tisa = %s;\n"
        "\t\t\tbuildActionMask = 2147483647;\n%s"
        "\t\t\tfiles = (\n%s\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n" % (ident, comment, isa, extra, body))


def config_list(ident: str, owner: str, debug: str, release: str) -> str:
    return (
        "\t\t%s /* Build configuration list for %s */ = {\n"
        "\t\t\tisa = XCConfigurationList;\n"
        "\t\t\tbuildConfigurations = (\n"
        "\t\t\t\t%s /* Debug */,\n"
        "\t\t\t\t%s /* Release */,\n"
        "\t\t\t);\n"
        "\t\t\tdefaultConfigurationIsVisible = 0;\n"
        "\t\t\tdefaultConfigurationName = Release;\n"
        "\t\t};\n" % (ident, owner, debug, release))


# ---------------------------------------------------------------- 组装

def main() -> None:
    objects: list[str] = []

    project_obj = oid("project")

    # --- 源码文件引用 + build file
    all_sources = (CCMARK_SOURCES + MARKDOWNKIT_SOURCES + SHAREDTHEME_SOURCES
                   + APP_SOURCES + EXT_SOURCES)
    all_sources = list(all_sources) + LINKOPENER_SOURCES
    refs = {p: oid("ref:" + p) for p in all_sources}
    bfs = {p: oid("bf:" + p) for p in all_sources}

    appicon_ref = oid("ref:" + APP_ICON)
    appicon_bf = oid("bf:appicon")
    theme_css_ref = oid("ref:" + SHAREDTHEME_RESOURCE)
    theme_css_bf = oid("bf:theme.css")
    app_plist_ref = oid("ref:" + APP_PLIST)
    ext_plist_ref = oid("ref:" + EXT_PLIST)
    linkopener_plist_ref = oid("ref:" + LINKOPENER_PLIST)

    # 产物引用
    products = {
        "libCcmarkGfm.a": ("archive.ar", "libCcmarkGfm.a"),
        "MarkdownKit.framework": ("wrapper.framework", "MarkdownKit.framework"),
        "SharedTheme.framework": ("wrapper.framework", "SharedTheme.framework"),
        "Spacedown.app": ("wrapper.application", "Spacedown.app"),
        "QuickLookPreview.appex": ("wrapper.cfbundle", "QuickLookPreview.appex"),
        "LinkOpener.xpc": ("wrapper.cfbundle", "LinkOpener.xpc"),
    }
    prod_refs = {
        name: oid("prod:" + name) for name in products
    }
    # QuickLookPreview.appex 的 explicitFileType 用 app-extension
    prod_filetypes = {
        "libCcmarkGfm.a": "archive.ar",
        "MarkdownKit.framework": "wrapper.framework",
        "SharedTheme.framework": "wrapper.framework",
        "Spacedown.app": "wrapper.application",
        "QuickLookPreview.appex": '"wrapper.app-extension"',
        "LinkOpener.xpc": '"wrapper.xpc-service"',
    }

    # --- PBXBuildFile
    bf = "\n/* Begin PBXBuildFile section */\n"
    for p in all_sources:
        bf += "\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (
            bfs[p], Path(p).name, refs[p], Path(p).name)
    bf += "\t\t%s /* theme.css in Resources */ = {isa = PBXBuildFile; fileRef = %s /* theme.css */; };\n" % (
        theme_css_bf, theme_css_ref)
    bf += "\t\t%s /* AppIcon.icns in Resources */ = {isa = PBXBuildFile; fileRef = %s /* AppIcon.icns */; };\n" % (
        appicon_bf, appicon_ref)
    # 链接 / 嵌入
    link_bfs = {}
    for label, product in [
        ("libCcmarkGfm.a", "libCcmarkGfm.a"),
        ("MarkdownKit.framework", "MarkdownKit.framework"),
        ("SharedTheme.framework", "SharedTheme.framework"),
        ("QuickLookPreview.appex", "QuickLookPreview.appex"),
    ]:
        key = ("link", label)
        link_bfs[key] = oid("bf:link:" + label)
        bf += "\t\t%s /* %s in Frameworks */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (
            link_bfs[key], label, prod_refs[product], product)
    # App 与 appex 各自要嵌一份 framework，PBXBuildFile 不能共用（同一个 fileRef
    # 出现在两个 target 的不同阶段里是可以的，但 Xcode 生成时也是各建一条）
    embed_bfs = {}
    for label in ["MarkdownKit.framework", "SharedTheme.framework"]:
        embed_bfs[("embed", label)] = oid("bf:embed:" + label)
    ext_embed_bfs = {label: oid("bf:embed:ext:" + label)
                     for label in ["MarkdownKit.framework", "SharedTheme.framework"]}
    ext_link_bfs = {label: oid("bf:link:ext:" + label)
                    for label in ["MarkdownKit.framework", "SharedTheme.framework"]}
    for ident, label in ([(embed_bfs[("embed", k)], k) for k in ext_embed_bfs]
                         + [(v, k) for k, v in ext_embed_bfs.items()]):
        bf += "\t\t%s /* %s in Embed Frameworks */ = {isa = PBXBuildFile; fileRef = %s /* %s */; settings = {ATTRIBUTES = (CodeSignOnCopy,); }; };\n" % (
            ident, label, prod_refs[label], label)
    for ident, label in [(v, k) for k, v in ext_link_bfs.items()]:
        bf += "\t\t%s /* %s in Frameworks */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (
            ident, label, prod_refs[label], label)
    embed_appex_bf = oid("bf:embed:appex")
    bf += "\t\t%s /* QuickLookPreview.appex in Embed Plug-ins */ = {isa = PBXBuildFile; fileRef = %s /* QuickLookPreview.appex */; };\n" % (
        embed_appex_bf, prod_refs["QuickLookPreview.appex"])
    embed_xpc_bf = oid("bf:embed:xpc")
    bf += "\t\t%s /* LinkOpener.xpc in Embed XPC Services */ = {isa = PBXBuildFile; fileRef = %s /* LinkOpener.xpc */; settings = {ATTRIBUTES = (CodeSignOnCopy,); }; };\n" % (
        embed_xpc_bf, prod_refs["LinkOpener.xpc"])
    ext_protocol_bf = oid("bf:ext:LinkOpenerProtocol")
    bf += "\t\t%s /* LinkOpenerProtocol.swift in Sources */ = {isa = PBXBuildFile; fileRef = %s /* LinkOpenerProtocol.swift */; };\n" % (
        ext_protocol_bf, refs["LinkOpener/LinkOpenerProtocol.swift"])
    bf += "/* End PBXBuildFile section */\n\n"
    objects.append(bf)

    # --- target 依赖（container item proxy）
    target_ids = {
        "CcmarkGfm": oid("target:CcmarkGfm"),
        "MarkdownKit": oid("target:MarkdownKit"),
        "SharedTheme": oid("target:SharedTheme"),
        "Spacedown": oid("target:Spacedown"),
        "QuickLookPreview": oid("target:QuickLookPreview"),
        "LinkOpener": oid("target:LinkOpener"),
    }
    proxies = {}
    deps = {}
    for t in ["CcmarkGfm", "MarkdownKit", "SharedTheme", "QuickLookPreview", "LinkOpener"]:
        proxies[t] = oid("proxy:" + t)
        deps[t] = oid("dep:" + t)

    proxy_src = "\n/* Begin PBXContainerItemProxy section */\n"
    for t in ["CcmarkGfm", "MarkdownKit", "SharedTheme", "QuickLookPreview", "LinkOpener"]:
        proxy_src += (
            "\t\t%s /* PBXContainerItemProxy */ = {\n"
            "\t\t\tisa = PBXContainerItemProxy;\n"
            "\t\t\tcontainerPortal = %s /* Project object */;\n"
            "\t\t\tproxyType = 1;\n"
            "\t\t\tremoteGlobalIDString = %s;\n"
            "\t\t\tremoteInfo = %s;\n"
            "\t\t};\n" % (proxies[t], project_obj, target_ids[t], t))
    proxy_src += "/* End PBXContainerItemProxy section */\n\n"
    objects.append(proxy_src)

    # --- Embed 阶段
    embed_phase = oid("phase:embed-plugins")
    objects.append(
        "\n/* Begin PBXCopyFilesBuildPhase section */\n"
        + files_phase(
            embed_phase, "PBXCopyFilesBuildPhase", "Embed Plug-ins",
            [(embed_appex_bf, "QuickLookPreview.appex in Embed Plug-ins")],
            extra="\t\t\tdstPath = \"\";\n\t\t\tdstSubfolderSpec = 13;\n\t\t\tname = \"Embed Plug-ins\";\n")
        + files_phase(
            oid("phase:app-embed-fw"), "PBXCopyFilesBuildPhase", "Embed Frameworks",
            [(embed_bfs[("embed", "MarkdownKit.framework")], "MarkdownKit.framework in Embed Frameworks"),
             (embed_bfs[("embed", "SharedTheme.framework")], "SharedTheme.framework in Embed Frameworks")],
            extra="\t\t\tdstPath = \"\";\n\t\t\tdstSubfolderSpec = 10;\n\t\t\tname = \"Embed Frameworks\";\n")
        + files_phase(
            oid("phase:ext-embed-fw"), "PBXCopyFilesBuildPhase", "Embed Frameworks",
            [(ext_embed_bfs["MarkdownKit.framework"], "MarkdownKit.framework in Embed Frameworks"),
             (ext_embed_bfs["SharedTheme.framework"], "SharedTheme.framework in Embed Frameworks")],
            extra="\t\t\tdstPath = \"\";\n\t\t\tdstSubfolderSpec = 10;\n\t\t\tname = \"Embed Frameworks\";\n")
        + files_phase(
            oid("phase:ext-embed-xpc"), "PBXCopyFilesBuildPhase", "Embed XPC Services",
            [(embed_xpc_bf, "LinkOpener.xpc in Embed XPC Services")],
            # ⚠️ 那个 `dstSubfolderSpec` 的取值是试出来的，别照抄别处的经验值：
            #
            # | 写法 | 实际落点 | 结果 |
            # |---|---|---|
            # | `16`（Xcode 界面上叫 Embed XPC Services 的那个值） | `<appex>/XPCServices/`（**bundle 根**，和 Contents 平级） | ✗ 签名直接失败：`unsealed contents present in the bundle root` |
            # | `0` + `$(CONTENTS_FOLDER_PATH)/XPCServices` | 解析失败 | ✗ `The file "LinkOpener.xpc" doesn't exist` |
            # | **`1` + `Contents/XPCServices`** | `<appex>/Contents/XPCServices/` | ✓ 正确 |
            #
            # 也就是 `16` 是 **iOS 语义**（那里 bundle 根就是产品本身）；macOS 包必须把一切
            # 放在 `Contents/` 下，得自己把它拼出来。
            extra="\t\t\tdstPath = Contents/XPCServices;\n\t\t\tdstSubfolderSpec = 1;\n\t\t\tname = \"Embed XPC Services\";\n")
        + "/* End PBXCopyFilesBuildPhase section */\n\n")

    # --- 文件引用
    fr = "\n/* Begin PBXFileReference section */\n"
    for p in CCMARK_SOURCES:
        fr += file_ref(refs[p], rel_for(p), "sourcecode.c.c")
    for p in MARKDOWNKIT_SOURCES + SHAREDTHEME_SOURCES + APP_SOURCES + EXT_SOURCES + LINKOPENER_SOURCES:
        fr += file_ref(refs[p], rel_for(p), "sourcecode.swift")
    fr += file_ref(theme_css_ref, rel_for(SHAREDTHEME_RESOURCE), "text.css")
    fr += file_ref(appicon_ref, rel_for(APP_ICON), "image.icns")
    fr += file_ref(app_plist_ref, rel_for(APP_PLIST), "text.plist.xml")
    fr += file_ref(ext_plist_ref, rel_for(EXT_PLIST), "text.plist.xml")
    fr += file_ref(linkopener_plist_ref, rel_for(LINKOPENER_PLIST), "text.plist.xml")
    for name, _ in products.items():
        fr += (
            "\t\t%s /* %s */ = {isa = PBXFileReference; explicitFileType = %s; "
            "includeInIndex = 0; path = %s; sourceTree = BUILT_PRODUCTS_DIR; };\n"
            % (prod_refs[name], name, prod_filetypes[name], name))
    fr += "/* End PBXFileReference section */\n\n"
    objects.append(fr)

    # --- 各 target 的构建阶段 id
    phases = {}
    for t in target_ids:
        phases[(t, "Sources")] = oid("phase:%s:sources" % t)
        phases[(t, "Frameworks")] = oid("phase:%s:frameworks" % t)
        phases[(t, "Resources")] = oid("phase:%s:resources" % t)

    fw_phases = {
        "CcmarkGfm": empty_phase(phases[("CcmarkGfm", "Frameworks")],
                                 "PBXFrameworksBuildPhase", "Frameworks"),
        "MarkdownKit": files_phase(
            phases[("MarkdownKit", "Frameworks")], "PBXFrameworksBuildPhase", "Frameworks",
            [(link_bfs[("link", "libCcmarkGfm.a")], "libCcmarkGfm.a in Frameworks")]),
        "SharedTheme": empty_phase(phases[("SharedTheme", "Frameworks")],
                                   "PBXFrameworksBuildPhase", "Frameworks"),
        "Spacedown": files_phase(
            phases[("Spacedown", "Frameworks")], "PBXFrameworksBuildPhase", "Frameworks",
            [(link_bfs[("link", "MarkdownKit.framework")], "MarkdownKit.framework in Frameworks"),
             (link_bfs[("link", "SharedTheme.framework")], "SharedTheme.framework in Frameworks")]),
        "QuickLookPreview": files_phase(
            phases[("QuickLookPreview", "Frameworks")], "PBXFrameworksBuildPhase", "Frameworks",
            [(ext_link_bfs["MarkdownKit.framework"], "MarkdownKit.framework in Frameworks"),
             (ext_link_bfs["SharedTheme.framework"], "SharedTheme.framework in Frameworks")]),
        # XPC 服务只依赖系统框架，不需要链我们的
        "LinkOpener": empty_phase(phases[("LinkOpener", "Frameworks")],
                                  "PBXFrameworksBuildPhase", "Frameworks"),
    }
    objects.append(
        "\n/* Begin PBXFrameworksBuildPhase section */\n"
        + "".join(fw_phases[t] for t in ["CcmarkGfm", "MarkdownKit", "SharedTheme",
                                         "Spacedown", "QuickLookPreview", "LinkOpener"])
        + "/* End PBXFrameworksBuildPhase section */\n\n")

    # --- 组
    def src_children(paths: list[str]) -> list[str]:
        return [refs[p] + " /* %s */" % Path(p).name for p in paths]

    # 组一律直接挂在 mainGroup 下、路径从仓库根写全。
    # 试过「Products/Core（name+path）+ 子组 Sources/XXX」的嵌套写法，Xcode 解析子组
    # 文件时只取子组自己的 path（拼出来的路径少了 Packages/Core），CpResource 直接报
    # 「no such file」。扁平挂载没有这种歧义。
    groups = {
        "CcmarkGfm": (oid("group:CcmarkGfm"), src_children(CCMARK_SOURCES),
                      "Packages/Core/Sources/CcmarkGfm"),
        "MarkdownKit": (oid("group:MarkdownKit"), src_children(MARKDOWNKIT_SOURCES),
                        "Packages/Core/Sources/MarkdownKit"),
        "SharedTheme": (oid("group:SharedTheme"),
                        src_children(SHAREDTHEME_SOURCES)
                        + [theme_css_ref + " /* theme.css */"],
                        "Packages/Core/Sources/SharedTheme"),
        "Spacedown": (oid("group:Spacedown"),
                      src_children(APP_SOURCES)
                      + [appicon_ref + " /* AppIcon.icns */",
                         app_plist_ref + " /* Info.plist */"],
                      "Spacedown"),
        "QuickLookPreview": (oid("group:QuickLookPreview"),
                             src_children(EXT_SOURCES) + [ext_plist_ref + " /* Info.plist */"],
                             "QuickLookPreview"),
        "LinkOpener": (oid("group:LinkOpener"),
                       src_children(LINKOPENER_SOURCES)
                       + [linkopener_plist_ref + " /* Info.plist */"],
                       "LinkOpener"),
    }
    products_group = oid("group:Products")
    main_group = oid("group:main")

    children_main = [
        groups[t][0] + " /* %s */" % t
        for t in ["CcmarkGfm", "MarkdownKit", "SharedTheme",
                  "Spacedown", "QuickLookPreview", "LinkOpener"]
    ] + [products_group + " /* Products */"]

    g = "\n/* Begin PBXGroup section */\n"
    g += group(main_group, children_main)
    for _t, (gid, ch, path) in groups.items():
        g += group(gid, ch, path=path)
    g += group(products_group,
               [prod_refs[n] + " /* %s */" % n for n in
                ["Spacedown.app", "QuickLookPreview.appex", "LinkOpener.xpc",
                 "MarkdownKit.framework", "SharedTheme.framework", "libCcmarkGfm.a"]],
               name="Products")
    g += "/* End PBXGroup section */\n\n"
    objects.append(g)

    # --- native targets
    def native_target(name: str, product: str, product_type: str,
                      phase_list: list[str], dependencies: list[str],
                      settings_extra: dict, cfg_list: str) -> str:
        ph = "".join("\t\t\t\t%s,\n" % p for p in phase_list)
        dp = "".join("\t\t\t\t%s /* PBXTargetDependency */,\n" % deps[d] for d in dependencies)
        cfg = dict(SIGNING)
        cfg.update(VERSIONING)
        cfg.update(settings_extra)
        # buildSettings 已并入 XCBuildConfiguration，这里只放结构
        return (
            "\t\t%s /* %s */ = {\n"
            "\t\t\tisa = PBXNativeTarget;\n"
            "\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget \"%s\" */;\n"
            "\t\t\tbuildPhases = (\n%s\t\t\t);\n"
            "\t\t\tbuildRules = (\n\t\t\t);\n"
            "\t\t\tdependencies = (\n%s\t\t\t);\n"
            "\t\t\tname = %s;\n"
            "\t\t\tproductName = %s;\n"
            "\t\t\tproductReference = %s /* %s */;\n"
            "\t\t\tproductType = \"%s\";\n"
            "\t\t};\n"
            % (target_ids[name], name, cfg_list, name, ph, dp, name, name,
               prod_refs[product], product, product_type))

    cfg_lists = {t: oid("cfglist:" + t) for t in target_ids}

    objects.append(
        "\n/* Begin PBXNativeTarget section */\n"
        + native_target("CcmarkGfm", "libCcmarkGfm.a",
                        "com.apple.product-type.library.static",
                        [phases[("CcmarkGfm", "Sources")], phases[("CcmarkGfm", "Frameworks")]],
                        [], {}, cfg_lists["CcmarkGfm"])
        + native_target("MarkdownKit", "MarkdownKit.framework",
                        "com.apple.product-type.framework",
                        [phases[("MarkdownKit", "Sources")],
                         phases[("MarkdownKit", "Frameworks")],
                         phases[("MarkdownKit", "Resources")]],
                        ["CcmarkGfm"], {}, cfg_lists["MarkdownKit"])
        + native_target("SharedTheme", "SharedTheme.framework",
                        "com.apple.product-type.framework",
                        [phases[("SharedTheme", "Sources")],
                         phases[("SharedTheme", "Frameworks")],
                         phases[("SharedTheme", "Resources")]],
                        [], {}, cfg_lists["SharedTheme"])
        + native_target("Spacedown", "Spacedown.app",
                        "com.apple.product-type.application",
                        [phases[("Spacedown", "Sources")],
                         phases[("Spacedown", "Frameworks")],
                         phases[("Spacedown", "Resources")],
                         embed_phase, oid("phase:app-embed-fw")],
                        ["MarkdownKit", "SharedTheme", "QuickLookPreview"], {},
                        cfg_lists["Spacedown"])
        + native_target("QuickLookPreview", "QuickLookPreview.appex",
                        "com.apple.product-type.app-extension",
                        [phases[("QuickLookPreview", "Sources")],
                         phases[("QuickLookPreview", "Frameworks")],
                         phases[("QuickLookPreview", "Resources")],
                         oid("phase:ext-embed-fw"), oid("phase:ext-embed-xpc")],
                        ["MarkdownKit", "SharedTheme", "LinkOpener"], {},
                        cfg_lists["QuickLookPreview"])
        + native_target("LinkOpener", "LinkOpener.xpc",
                        "com.apple.product-type.xpc-service",
                        [phases[("LinkOpener", "Sources")],
                         phases[("LinkOpener", "Frameworks")]],
                        [], {}, cfg_lists["LinkOpener"])
        + "/* End PBXNativeTarget section */\n\n")

    # --- project
    # 注意：`%` 的优先级高于 `+`，上面那种「末尾统一 % args」的写法会把最后一组相邻
    # 字面量单独格式化掉。这里先拼好再格式化。
    project_attrs = "".join(
        "\t\t\t\t\t%s = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 27.0;\n\t\t\t\t\t};\n"
        % target_ids[t] for t in target_ids)
    project_targets = "".join(
        "\t\t\t\t%s /* %s */,\n" % (target_ids[t], t) for t in target_ids)
    objects.append((
        "\n/* Begin PBXProject section */\n"
        "\t\t%s /* Project object */ = {\n"
        "\t\t\tisa = PBXProject;\n"
        "\t\t\tattributes = {\n"
        "\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
        "\t\t\t\tLastUpgradeCheck = 2700;\n"
        "\t\t\t\tTargetAttributes = {\n"
        + project_attrs
        + "\t\t\t\t};\n"
        "\t\t\t};\n"
        "\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXProject \"Spacedown\" */;\n"
        "\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n"
        "\t\t\tdevelopmentRegion = en;\n"
        "\t\t\thasScannedForEncodings = 0;\n"
        "\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
        "\t\t\tmainGroup = %s;\n"
        "\t\t\tproductRefGroup = %s /* Products */;\n"
        "\t\t\tprojectDirPath = \"\";\n"
        "\t\t\tprojectRoot = \"\";\n"
        "\t\t\ttargets = (\n"
        + project_targets
        + "\t\t\t);\n"
        "\t\t};\n"
        "/* End PBXProject section */\n\n"
    ) % (project_obj, oid("cfglist:project"), main_group, products_group))

    # --- resources
    res = {
        "CcmarkGfm": empty_phase(phases[("CcmarkGfm", "Resources")],
                                 "PBXResourcesBuildPhase", "Resources"),
        "MarkdownKit": empty_phase(phases[("MarkdownKit", "Resources")],
                                   "PBXResourcesBuildPhase", "Resources"),
        "SharedTheme": files_phase(phases[("SharedTheme", "Resources")],
                                   "PBXResourcesBuildPhase", "Resources",
                                   [(theme_css_bf, "theme.css in Resources")]),
        "Spacedown": files_phase(phases[("Spacedown", "Resources")],
                                 "PBXResourcesBuildPhase", "Resources",
                                 [(appicon_bf, "AppIcon.icns in Resources")]),
        "QuickLookPreview": empty_phase(phases[("QuickLookPreview", "Resources")],
                                        "PBXResourcesBuildPhase", "Resources"),
    }
    objects.append("\n/* Begin PBXResourcesBuildPhase section */\n"
                   + "".join(res[t] for t in ["CcmarkGfm", "MarkdownKit", "SharedTheme",
                                              "Spacedown", "QuickLookPreview"])
                   + "/* End PBXResourcesBuildPhase section */\n\n")

    # --- sources
    src_map = {
        "CcmarkGfm": CCMARK_SOURCES,
        "MarkdownKit": MARKDOWNKIT_SOURCES,
        "SharedTheme": SHAREDTHEME_SOURCES,
        "Spacedown": APP_SOURCES,
        "QuickLookPreview": EXT_SOURCES,
        "LinkOpener": LINKOPENER_SOURCES,
    }
    # 扩展还要多编译一份 XPC 协议（那个文件属于 LinkOpener 组，所以用单独的 build file）
    src_extra = {"QuickLookPreview": [(ext_protocol_bf, "LinkOpener/LinkOpenerProtocol.swift")]}
    objects.append(
        "\n/* Begin PBXSourcesBuildPhase section */\n"
        + "".join(sources_phase(phases[(t, "Sources")],
                                [(bfs[p], p) for p in src_map[t]] + src_extra.get(t, []))
                  for t in src_map)
        + "/* End PBXSourcesBuildPhase section */\n\n")

    # --- target dependency
    objects.append(
        "\n/* Begin PBXTargetDependency section */\n"
        + "".join(
            "\t\t%s /* PBXTargetDependency */ = {\n"
            "\t\t\tisa = PBXTargetDependency;\n"
            "\t\t\ttarget = %s /* %s */;\n"
            "\t\t\ttargetProxy = %s /* PBXContainerItemProxy */;\n"
            "\t\t};\n" % (deps[t], target_ids[t], t, proxies[t])
            for t in ["CcmarkGfm", "MarkdownKit", "SharedTheme", "QuickLookPreview",
                      "LinkOpener"])
        + "/* End PBXTargetDependency section */\n\n")

    # --- 构建配置
    settings_map = {
        "CcmarkGfm": CCMARK_SETTINGS,
        "MarkdownKit": MARKDOWNKIT_SETTINGS,
        "SharedTheme": SHAREDTHEME_SETTINGS,
        "Spacedown": APP_SETTINGS,
        "QuickLookPreview": EXT_SETTINGS,
        "LinkOpener": LINKOPENER_SETTINGS,
    }
    cfgs = "\n/* Begin XCBuildConfiguration section */\n"
    proj_cfg_ids = {}
    for name, extra in [("Debug", PROJECT_DEBUG), ("Release", PROJECT_RELEASE)]:
        ident = oid("cfg:project:" + name)
        proj_cfg_ids[name] = ident
        cfgs += build_config(ident, name, PROJECT_COMMON, extra)
    for t in target_ids:
        for name in ["Debug", "Release"]:
            merged = dict(SIGNING)
            merged.update(VERSIONING)
            merged.update(settings_map[t])
            ident = oid("cfg:%s:%s" % (t, name))
            cfgs += build_config(ident, name, merged, {})
    cfgs += "/* End XCBuildConfiguration section */\n\n"
    objects.append(cfgs)

    cl = "\n/* Begin XCConfigurationList section */\n"
    cl += config_list(oid("cfglist:project"), 'PBXProject "Spacedown"',
                      proj_cfg_ids["Debug"], proj_cfg_ids["Release"])
    for t in target_ids:
        cl += config_list(cfg_lists[t], 'PBXNativeTarget "%s"' % t,
                          oid("cfg:%s:Debug" % t), oid("cfg:%s:Release" % t))
    cl += "/* End XCConfigurationList section */\n"
    objects.append(cl)

    # --- 写出
    if not XCODEPROJ.exists():
        XCODEPROJ.mkdir()
    content = (
        "// !$*UTF8*$!\n"
        "{\n"
        "\tarchiveVersion = 1;\n"
        "\tclasses = {\n\t};\n"
        "\tobjectVersion = 56;\n"
        "\tobjects = {\n\n"
        + "".join(objects)
        + "\t};\n"
        "\trootObject = %s /* Project object */;\n"
        "}\n" % project_obj
    )
    (XCODEPROJ / "project.pbxproj").write_text(content, encoding="utf-8")

    # 校验：所有被引用的对象 id 都有定义
    declared = set(re.findall(r"\n\t\t([0-9A-F]{24}) ", content))
    used = set(re.findall(r"([0-9A-F]{24}) /\*", content))
    missing = used - declared
    if missing:
        raise SystemExit("未定义的对象引用: %s" % sorted(missing))

    print("wrote %s (%d bytes, %d objects)"
          % (XCODEPROJ / "project.pbxproj", len(content), len(declared)))


if __name__ == "__main__":
    main()
