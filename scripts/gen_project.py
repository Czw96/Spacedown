#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 Spacedown.xcodeproj。

为什么用脚本而不是手写 project.pbxproj：pbxproj 里每个对象都要 24 位十六进制 UUID，
相互引用的地方有几十处，手写漏一个引用 xcodebuild 只会报 "object not found"。

用法：python3 scripts/gen_project.py

源文件按目录自动发现、分组按目录树递归生成 —— 新增文件不需要改这个脚本，
只要落进下面对应的目录即可。

⚠️ 工程里为什么没有 SwiftPM 包引用：Xcode 接入本地包时会先跑「Resolve Package Graph」，
那一步要编译 Package.swift manifest，而 SwiftPM 会把 manifest 编译塞进 sandbox-exec，
本机一律 `Operation not permitted`。改成原生 target 后，Xcode 与 `swift build`
各自独立、互不依赖。
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

def files_under(base: str, suffixes: tuple[str, ...]) -> list[str]:
    """递归取出 base 下指定后缀的文件，返回仓库相对路径并排序。"""
    root = ROOT / base
    found = [p for p in root.rglob("*") if p.is_file() and p.suffix in suffixes]
    return sorted(str(p.relative_to(ROOT)) for p in found)


CCMARK_SOURCES = (files_under(CORE + "/Sources/CcmarkGfm/src", (".c",))
                  + files_under(CORE + "/Sources/CcmarkGfm/extensions", (".c",)))
MARKDOWNKIT_SOURCES = files_under(CORE + "/Sources/MarkdownKit", (".swift",))
SHAREDTHEME_SOURCES = files_under(CORE + "/Sources/SharedTheme", (".swift",))
SHAREDTHEME_RESOURCE = CORE + "/Sources/SharedTheme/theme.css"

APP_SOURCES = files_under("Spacedown", (".swift",))
APP_PLIST = "Spacedown/Resources/Info.plist"
APP_ICON = "Spacedown/Resources/AppIcon.icns"          # CFBundleIconFile
APP_RESOURCES = ["Spacedown/Resources/uninstall.sh", "Spacedown/Resources/swap.sh"]

EXT_SOURCES = files_under("QuickLookPreview", (".swift",))
EXT_PLIST = "QuickLookPreview/Resources/Info.plist"
EXT_ENTITLEMENTS = "QuickLookPreview/Resources/QuickLookPreview.entitlements"

# XPC 服务：替沙箱里的扩展打开外部链接。
LINKOPENER_SOURCES = files_under("LinkOpener", (".swift",))
LINKOPENER_PLIST = "LinkOpener/Info.plist"
# 协议文件要同时编译进扩展和服务两个 target，但物理上属于 LinkOpener/ ——
# 一个文件只能有一个 fileRef，所以用单独的 build file 给扩展。
EXT_SHARED_SOURCES = ["LinkOpener/LinkOpenerProtocol.swift"]

FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".c": "sourcecode.c.c",
    ".css": "text.css",
    ".plist": "text.plist.xml",
    ".icns": "image.icns",
    ".sh": "text.script.sh",
    ".entitlements": "text.plist.entitlements",
}

# 每个 group 的根目录与它包含的文件（源码 + 需要显示在工程里的资源）
GROUPS = {
    "CcmarkGfm": (CORE + "/Sources/CcmarkGfm", CCMARK_SOURCES),
    "MarkdownKit": (CORE + "/Sources/MarkdownKit", MARKDOWNKIT_SOURCES),
    "SharedTheme": (CORE + "/Sources/SharedTheme", SHAREDTHEME_SOURCES + [SHAREDTHEME_RESOURCE]),
    "Spacedown": ("Spacedown", APP_SOURCES + [APP_PLIST, APP_ICON] + APP_RESOURCES),
    "QuickLookPreview": ("QuickLookPreview",
                         EXT_SOURCES + [EXT_PLIST, EXT_ENTITLEMENTS]),
    "LinkOpener": ("LinkOpener", LINKOPENER_SOURCES + [LINKOPENER_PLIST]),
}

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
    # CcmarkGfm 的 clang module 只存在于 XcodeSupport 那份 modulemap 里。MarkdownKit 的
    # swiftmodule 带着对它的依赖，所以所有 import MarkdownKit 的 target 都要能找到它。
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

# 本机没有 codesigning identity，只能 ad-hoc。正式分发要换 Developer ID + 公证。
SIGNING = {
    "CODE_SIGN_IDENTITY": '"-"',
    "CODE_SIGN_STYLE": "Manual",
    "ENABLE_HARDENED_RUNTIME": "NO",
}

VERSIONING = {
    "CURRENT_PROJECT_VERSION": "1",
    "MARKETING_VERSION": "1.0.6",
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

# framework 让 `import MarkdownKit` 走 -F 自动发现。内部静态链 CcmarkGfm.a，
# 所以宿主不需要 embed 它。
FRAMEWORK_SETTINGS = {
    "DEFINES_MODULE": "YES",
    # framework 也要 Info.plist 才能签名；这里没有自定义项，交给 Xcode 自动生成
    "GENERATE_INFOPLIST_FILE": "YES",
    # @rpath 必须加引号：旧式 plist 里裸 `@` 是非法字符（会整个工程读不出来）
    "DYLIB_INSTALL_NAME_BASE": '"@rpath"',
    "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks",)',
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SKIP_INSTALL": "YES",
}

MARKDOWNKIT_SETTINGS = {**FRAMEWORK_SETTINGS,
                        "PRODUCT_BUNDLE_IDENTIFIER": "cn.29dev.Spacedown.MarkdownKit"}
SHAREDTHEME_SETTINGS = {**FRAMEWORK_SETTINGS,
                        "PRODUCT_BUNDLE_IDENTIFIER": "cn.29dev.Spacedown.SharedTheme"}

APP_SETTINGS = {
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": APP_PLIST,
    "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/../Frameworks",)',
    "PRODUCT_BUNDLE_IDENTIFIER": "cn.29dev.Spacedown",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SKIP_INSTALL": "NO",
}

EXT_SETTINGS = {
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": EXT_PLIST,
    # App 扩展必须沙箱化，否则 macOS 静默不加载它（不报错，扩展永远不被拉起）
    "CODE_SIGN_ENTITLEMENTS": EXT_ENTITLEMENTS,
    # appex 嵌在 App 的 Contents/PlugIns 下，比 App 深两级
    "LD_RUNPATH_SEARCH_PATHS": ('(\n\t\t\t\t\t"$(inherited)",\n'
                                '\t\t\t\t\t"@executable_path/../Frameworks",\n'
                                '\t\t\t\t\t"@executable_path/../../../../Frameworks",\n'
                                '\t\t\t\t)', True),
    "PRODUCT_BUNDLE_IDENTIFIER": "cn.29dev.Spacedown.QuickLookPreview",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SKIP_INSTALL": "YES",
    "WRAPPER_EXTENSION": "appex",
}

# XPC 服务刻意不带 app-sandbox：它的存在意义就是替沙箱里的扩展打开链接
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


def file_ref(ident: str, name: str, filetype: str) -> str:
    """文件的 path 是相对所在 group 的，所以只写文件名 —— 目录由 group 树表达。"""
    return (
        "\t\t%s /* %s */ = {\n"
        "\t\t\tisa = PBXFileReference;\n"
        "\t\t\tlastKnownFileType = %s;\n"
        "\t\t\tpath = \"%s\";\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};\n" % (ident, name, filetype, name)
    )


def group(ident: str, children: list[str], name: str | None = None,
          path: str | None = None) -> str:
    body = "".join("\t\t\t\t%s,\n" % c for c in children)
    extra = ""
    if name:
        extra += "\t\t\tname = %s;\n" % name
    if path:
        extra += "\t\t\tpath = \"%s\";\n" % path
    # sourceTree 必须显式写：省略时 Xcode 不保证按父组解析相对路径。
    return (
        "\t\t%s /* %s */ = {\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n%s\t\t\t);\n%s"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};\n" % (ident, name or path or "Group", body, extra)
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


def group_tree(base: str, file_paths: list[str]) -> tuple[str, str]:
    """按真实目录结构把文件生成为嵌套 PBXGroup。

    返回（组文本, 文件引用文本）。组文本里子组的 path 是相对父组的目录名，
    与 Xcode 自己生成的工程一致。
    """
    base_path = Path(base)
    by_dir: dict[Path, list[str]] = {}
    for path in file_paths:
        rel = Path(path).relative_to(base_path)
        by_dir.setdefault(rel.parent, []).append(rel.name)

    group_text = ""
    ref_text = ""

    def emit(directory: Path) -> str:
        nonlocal group_text, ref_text
        children: list[str] = []

        for filename in sorted(by_dir.get(directory, [])):
            full = str(base_path / directory / filename)
            ident = oid("ref:" + full)
            children.append("%s /* %s */" % (ident, filename))
            ref_text += file_ref(ident, filename, FILE_TYPES[Path(filename).suffix])

        depth = len(directory.parts)
        subdirs = sorted({d.parts[depth] for d in by_dir
                          if len(d.parts) > depth and d.parts[:depth] == directory.parts})
        for subdir in subdirs:
            children.append("%s /* %s */" % (emit(directory / subdir), subdir))

        ident = oid("group:" + str(base_path / directory))
        # 根组的 path 从仓库根写全（主组本身没有 path）；子组只写目录名，相对父组。
        path = str(base_path) if directory == Path(".") else directory.name
        group_text += group(ident, children, path=path)
        return ident

    emit(Path("."))
    return group_text, ref_text


# ---------------------------------------------------------------- 组装

def main() -> None:
    objects: list[str] = []
    project_obj = oid("project")

    all_sources = (CCMARK_SOURCES + MARKDOWNKIT_SOURCES + SHAREDTHEME_SOURCES
                   + APP_SOURCES + EXT_SOURCES + LINKOPENER_SOURCES)
    refs = {p: oid("ref:" + p) for p in all_sources}
    bfs = {p: oid("bf:" + p) for p in all_sources}

    appicon_ref = oid("ref:" + APP_ICON)
    appicon_bf = oid("bf:appicon")
    # 每个资源都单独建 build file —— 之前只给 uninstall.sh 开了后门，
    # 新加的 swap.sh 因此只进了文件树、没进 Resources 构建阶段，bundle 里根本没有它。
    resource_refs = {p: oid("ref:" + p) for p in APP_RESOURCES}
    resource_bfs = {p: oid("bf:res:" + p) for p in APP_RESOURCES}
    theme_css_ref = oid("ref:" + SHAREDTHEME_RESOURCE)
    theme_css_bf = oid("bf:theme.css")

    # --- 产物引用
    products = {
        "libCcmarkGfm.a": "archive.ar",
        "MarkdownKit.framework": "wrapper.framework",
        "SharedTheme.framework": "wrapper.framework",
        "Spacedown.app": "wrapper.application",
        "QuickLookPreview.appex": '"wrapper.app-extension"',
        "LinkOpener.xpc": '"wrapper.xpc-service"',
    }
    prod_refs = {name: oid("prod:" + name) for name in products}

    # --- PBXBuildFile
    bf = "\n/* Begin PBXBuildFile section */\n"
    for p in all_sources:
        bf += "\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (
            bfs[p], Path(p).name, refs[p], Path(p).name)
    bf += "\t\t%s /* theme.css in Resources */ = {isa = PBXBuildFile; fileRef = %s /* theme.css */; };\n" % (
        theme_css_bf, theme_css_ref)
    bf += "\t\t%s /* AppIcon.icns in Resources */ = {isa = PBXBuildFile; fileRef = %s /* AppIcon.icns */; };\n" % (
        appicon_bf, appicon_ref)
    for p in APP_RESOURCES:
        name = Path(p).name
        bf += "\t\t%s /* %s in Resources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (
            resource_bfs[p], name, resource_refs[p], name)

    link_bfs = {}
    for label in ["libCcmarkGfm.a", "MarkdownKit.framework", "SharedTheme.framework",
                  "QuickLookPreview.appex"]:
        link_bfs[("link", label)] = oid("bf:link:" + label)
        bf += "\t\t%s /* %s in Frameworks */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (
            link_bfs[("link", label)], label, prod_refs[label], label)

    # App 与 appex 各自要嵌一份 framework，build file 不能共用
    frameworks = ["MarkdownKit.framework", "SharedTheme.framework"]
    app_embed = {label: oid("bf:embed:app:" + label) for label in frameworks}
    ext_embed = {label: oid("bf:embed:ext:" + label) for label in frameworks}
    ext_link = {label: oid("bf:link:ext:" + label) for label in frameworks}
    for ident, label in ([(app_embed[label], label) for label in frameworks]
                         + [(ext_embed[label], label) for label in frameworks]):
        bf += ("\t\t%s /* %s in Embed Frameworks */ = {isa = PBXBuildFile; fileRef = %s /* %s */; "
               "settings = {ATTRIBUTES = (CodeSignOnCopy,); }; };\n"
               % (ident, label, prod_refs[label], label))
    for ident, label in [(v, k) for k, v in ext_link.items()]:
        bf += "\t\t%s /* %s in Frameworks */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (
            ident, label, prod_refs[label], label)

    embed_appex_bf = oid("bf:embed:appex")
    bf += ("\t\t%s /* QuickLookPreview.appex in Embed Plug-ins */ = {isa = PBXBuildFile; "
           "fileRef = %s /* QuickLookPreview.appex */; };\n"
           % (embed_appex_bf, prod_refs["QuickLookPreview.appex"]))
    embed_xpc_bf = oid("bf:embed:xpc")
    bf += ("\t\t%s /* LinkOpener.xpc in Embed XPC Services */ = {isa = PBXBuildFile; "
           "fileRef = %s /* LinkOpener.xpc */; settings = {ATTRIBUTES = (CodeSignOnCopy,); }; };\n"
           % (embed_xpc_bf, prod_refs["LinkOpener.xpc"]))
    ext_protocol_bf = oid("bf:ext:LinkOpenerProtocol")
    bf += "\t\t%s /* LinkOpenerProtocol.swift in Sources */ = {isa = PBXBuildFile; fileRef = %s /* LinkOpenerProtocol.swift */; };\n" % (
        ext_protocol_bf, refs[EXT_SHARED_SOURCES[0]])
    bf += "/* End PBXBuildFile section */\n\n"
    objects.append(bf)

    # --- target 依赖
    target_ids = {name: oid("target:" + name) for name in GROUPS}
    proxies, deps = {}, {}
    dependency_targets = ["CcmarkGfm", "MarkdownKit", "SharedTheme", "QuickLookPreview", "LinkOpener"]
    for name in dependency_targets:
        proxies[name] = oid("proxy:" + name)
        deps[name] = oid("dep:" + name)

    proxy_src = "\n/* Begin PBXContainerItemProxy section */\n"
    for name in dependency_targets:
        proxy_src += (
            "\t\t%s /* PBXContainerItemProxy */ = {\n"
            "\t\t\tisa = PBXContainerItemProxy;\n"
            "\t\t\tcontainerPortal = %s /* Project object */;\n"
            "\t\t\tproxyType = 1;\n"
            "\t\t\tremoteGlobalIDString = %s;\n"
            "\t\t\tremoteInfo = %s;\n"
            "\t\t};\n" % (proxies[name], project_obj, target_ids[name], name))
    objects.append(proxy_src + "/* End PBXContainerItemProxy section */\n\n")

    # --- Embed 阶段
    objects.append(
        "\n/* Begin PBXCopyFilesBuildPhase section */\n"
        + files_phase(
            oid("phase:embed-plugins"), "PBXCopyFilesBuildPhase", "Embed Plug-ins",
            [(embed_appex_bf, "QuickLookPreview.appex in Embed Plug-ins")],
            extra="\t\t\tdstPath = \"\";\n\t\t\tdstSubfolderSpec = 13;\n\t\t\tname = \"Embed Plug-ins\";\n")
        + files_phase(
            oid("phase:app-embed-fw"), "PBXCopyFilesBuildPhase", "Embed Frameworks",
            [(app_embed[label], label + " in Embed Frameworks") for label in frameworks],
            extra="\t\t\tdstPath = \"\";\n\t\t\tdstSubfolderSpec = 10;\n\t\t\tname = \"Embed Frameworks\";\n")
        + files_phase(
            oid("phase:ext-embed-fw"), "PBXCopyFilesBuildPhase", "Embed Frameworks",
            [(ext_embed[label], label + " in Embed Frameworks") for label in frameworks],
            extra="\t\t\tdstPath = \"\";\n\t\t\tdstSubfolderSpec = 10;\n\t\t\tname = \"Embed Frameworks\";\n")
        + files_phase(
            oid("phase:ext-embed-xpc"), "PBXCopyFilesBuildPhase", "Embed XPC Services",
            [(embed_xpc_bf, "LinkOpener.xpc in Embed XPC Services")],
            # dstSubfolderSpec 必须是 1 + Contents/XPCServices。16 是 iOS 语义
            # （bundle 根），在 macOS 上会让签名报 "unsealed contents in the bundle root"。
            extra="\t\t\tdstPath = Contents/XPCServices;\n\t\t\tdstSubfolderSpec = 1;\n\t\t\tname = \"Embed XPC Services\";\n")
        + "/* End PBXCopyFilesBuildPhase section */\n\n")

    # --- 文件引用（由 group 树生成，见下方的组）
    # --- 构建阶段 id
    phases = {}
    for name in target_ids:
        phases[(name, "Sources")] = oid("phase:%s:sources" % name)
        phases[(name, "Frameworks")] = oid("phase:%s:frameworks" % name)
        phases[(name, "Resources")] = oid("phase:%s:resources" % name)

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
            [(ext_link["MarkdownKit.framework"], "MarkdownKit.framework in Frameworks"),
             (ext_link["SharedTheme.framework"], "SharedTheme.framework in Frameworks")]),
        # XPC 服务只依赖系统框架
        "LinkOpener": empty_phase(phases[("LinkOpener", "Frameworks")],
                                  "PBXFrameworksBuildPhase", "Frameworks"),
    }
    objects.append(
        "\n/* Begin PBXFrameworksBuildPhase section */\n"
        + "".join(fw_phases[name] for name in GROUPS)
        + "/* End PBXFrameworksBuildPhase section */\n\n")

    # --- 组（文件引用在 group_tree 里一并生成）
    products_group = oid("group:Products")
    main_group = oid("group:main")

    groups_text = "\n/* Begin PBXGroup section */\n"
    file_ref_text = "\n/* Begin PBXFileReference section */\n"

    # 产物引用（BUILT_PRODUCTS_DIR）
    for name, filetype in products.items():
        file_ref_text += (
            "\t\t%s /* %s */ = {isa = PBXFileReference; explicitFileType = %s; "
            "includeInIndex = 0; path = %s; sourceTree = BUILT_PRODUCTS_DIR; };\n"
            % (prod_refs[name], name, filetype, name))

    for name, (base, paths) in GROUPS.items():
        text, refs_text = group_tree(base, paths)
        groups_text += text
        file_ref_text += refs_text

    groups_text += group(products_group,
                         ["%s /* %s */" % (prod_refs[n], n) for n in products],
                         name="Products")
    groups_text += group(main_group,
                         ["%s /* %s */" % (oid("group:" + GROUPS[n][0]), n) for n in GROUPS]
                         + ["%s /* Products */" % products_group])
    groups_text += "/* End PBXGroup section */\n\n"

    objects.append(file_ref_text + "/* End PBXFileReference section */\n\n")
    objects.append(groups_text)

    # --- native targets
    def native_target(name: str, product: str, product_type: str,
                      phase_list: list[str], dependencies: list[str],
                      settings_extra: dict, cfg_list: str) -> str:
        ph = "".join("\t\t\t\t%s,\n" % p for p in phase_list)
        dp = "".join("\t\t\t\t%s /* PBXTargetDependency */,\n" % deps[d] for d in dependencies)
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

    cfg_lists = {name: oid("cfglist:" + name) for name in target_ids}

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
                         oid("phase:embed-plugins"), oid("phase:app-embed-fw")],
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
    project_attrs = "".join(
        "\t\t\t\t\t%s = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 27.0;\n\t\t\t\t\t};\n"
        % target_ids[name] for name in target_ids)
    project_targets = "".join(
        "\t\t\t\t%s /* %s */,\n" % (target_ids[name], name) for name in target_ids)
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
    resources = {
        "CcmarkGfm": empty_phase(phases[("CcmarkGfm", "Resources")],
                                 "PBXResourcesBuildPhase", "Resources"),
        "MarkdownKit": empty_phase(phases[("MarkdownKit", "Resources")],
                                   "PBXResourcesBuildPhase", "Resources"),
        "SharedTheme": files_phase(phases[("SharedTheme", "Resources")],
                                   "PBXResourcesBuildPhase", "Resources",
                                   [(theme_css_bf, "theme.css in Resources")]),
        "Spacedown": files_phase(phases[("Spacedown", "Resources")],
                                 "PBXResourcesBuildPhase", "Resources",
                                 [(appicon_bf, "AppIcon.icns in Resources")]
                                 + [(resource_bfs[p], Path(p).name + " in Resources")
                                    for p in APP_RESOURCES]),
        "QuickLookPreview": empty_phase(phases[("QuickLookPreview", "Resources")],
                                        "PBXResourcesBuildPhase", "Resources"),
    }
    objects.append("\n/* Begin PBXResourcesBuildPhase section */\n"
                   + "".join(resources[name] for name in resources)
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
    src_extra = {"QuickLookPreview": [(ext_protocol_bf, EXT_SHARED_SOURCES[0])]}
    objects.append(
        "\n/* Begin PBXSourcesBuildPhase section */\n"
        + "".join(sources_phase(phases[(name, "Sources")],
                                [(bfs[p], p) for p in src_map[name]] + src_extra.get(name, []))
                  for name in src_map)
        + "/* End PBXSourcesBuildPhase section */\n\n")

    # --- target dependency
    objects.append(
        "\n/* Begin PBXTargetDependency section */\n"
        + "".join(
            "\t\t%s /* PBXTargetDependency */ = {\n"
            "\t\t\tisa = PBXTargetDependency;\n"
            "\t\t\ttarget = %s /* %s */;\n"
            "\t\t\ttargetProxy = %s /* PBXContainerItemProxy */;\n"
            "\t\t};\n" % (deps[name], target_ids[name], name, proxies[name])
            for name in dependency_targets)
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
    for name in target_ids:
        for config in ["Debug", "Release"]:
            merged = dict(SIGNING)
            merged.update(VERSIONING)
            merged.update(settings_map[name])
            cfgs += build_config(oid("cfg:%s:%s" % (name, config)), config, merged, {})
    cfgs += "/* End XCBuildConfiguration section */\n\n"
    objects.append(cfgs)

    cl = "\n/* Begin XCConfigurationList section */\n"
    cl += config_list(oid("cfglist:project"), 'PBXProject "Spacedown"',
                      proj_cfg_ids["Debug"], proj_cfg_ids["Release"])
    for name in target_ids:
        cl += config_list(cfg_lists[name], 'PBXNativeTarget "%s"' % name,
                          oid("cfg:%s:Debug" % name), oid("cfg:%s:Release" % name))
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
