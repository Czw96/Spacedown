<div align="center">
  <img src="docs/img/icon.png" width="120" alt="Spacedown icon">
  <h1>Spacedown</h1>
  <p><b>Press space on a Markdown file in Finder — see it rendered.</b><br>
  Native rendering · Quick Look extension · read-only multi-tab viewer</p>

  <p>
    <a href="README.md">简体中文</a> ｜ <b>English</b>
  </p>

  <p>
    macOS 13+ · Apple Silicon · MIT ·
    <a href="https://github.com/Czw96/homebrew-spacedown/releases/latest">v1.0.22</a> ·
    AI-generated code
  </p>
</div>

![How Spacedown renders Markdown](docs/img/preview-light.png)

> [!NOTE]
> **This project is implemented by an AI coding assistant** (code, docs, design and release
> scripts). A human owns requirements, trade-offs and on-device acceptance. See
> [AI disclosure](#ai-disclosure) for the exact split — worth reading before you trust it.

## The problem

macOS Quick Look treats `.md` as **plain text**: monospaced font, literal `#`, tables
flattened into pipes. You just want to glance at a document, and you end up opening an editor.

Spacedown does two things:

1. **Takes over Quick Look for Markdown** — select a `.md` in Finder, press space, get typeset
   content: GFM tables, task lists, strikethrough, autolinks, fenced code, `> [!NOTE]` callouts,
   and relative images inlined.
2. **Ships a read-only multi-tab viewer** — double-click to open, multiple files side by side,
   live reload on external edits, adjustable measure and zoom.

The renderer is vendored [cmark-gfm](https://github.com/github/cmark-gfm) plus a hand-written
HTML shell. **No JavaScript runs in that layer**: no front-end framework, no JS syntax
highlighting, no network access.

## Features

| | |
|---|---|
| **Space to preview** | A Quick Look extension: press space in Finder, get rendered Markdown |
| **Just enough to glance** | Quick Look renders the first 64 KB — cut at a **complete block boundary** so tables and code fences never split — with a "load more" button that hands the file to the app |
| **Tabs** | Custom tab bar, `WKWebView` LRU pool (5 + 2 spare), ~0 ms switching; hard cap of 10 tabs |
| **Fast first frame** | A web view is prewarmed at launch: ~100 ms for the first file (the 370 ms cold start is paid during app launch instead) |
| **Read-only, still copyable** | CSP `default-src 'none'`, HTML is not editable; selection, ⌘C and ⌘A work |
| **Live reload** | `DispatchSource` watch + 120 ms debounce + inode/size/mtime comparison; survives delete-and-recreate |
| **Light/dark** | Follows the system appearance, one CSS for both Quick Look and the app |
| **Adjustable measure** | Full width by default, down to 40%; ⌥⌘= / ⌥⌘− / ⌥⌘0 |
| **Zoom** | ⌘+ / ⌘− / ⌘0, 25%–500%, via `pageZoom` (reflows, so no horizontal scrollbar) |
| **Find** | ⌘F opens a find bar using WebKit's native `find`, no injected JS |
| **Links** | Click copies the URL, ⌘/⌃ + click opens it in your browser (via XPC, out of the sandbox) |
| **Self-update** | Ed25519 self-signing plus a swap script — safe upgrades without a Developer ID |

![Dark appearance](docs/img/preview-dark.png)

## Install

Requires **macOS 13 Ventura or later** on **Apple Silicon** (arm64 only).

```bash
brew tap czw96/spacedown
brew trust czw96/spacedown            # third-party taps need explicit trust once
brew install --cask spacedown

brew upgrade --cask spacedown         # upgrade
brew uninstall --cask --zap spacedown # uninstall, including preferences and caches
```

Or grab the `.dmg` from the [latest release](https://github.com/Czw96/homebrew-spacedown/releases/latest)
and drag it into Applications.

Two things to do once after installing:

1. **The first launch is blocked by Gatekeeper** (there is no Apple Developer ID here):
   use **System Settings → Privacy & Security → Open Anyway**.
2. **Launch Spacedown once, then choose "View → Take over Markdown quick look"** from the menu.
   Without this, space still shows source text.

Details (`xattr` to clear quarantine, why the claim has to be manual, how to diagnose failures)
are in [`docs/构建与发布.md`](docs/构建与发布.md) (Chinese).

## Using it

| Action | Shortcut |
|---|---|
| Open file… | <kbd>⌘</kbd><kbd>O</kbd> |
| Close tab / window | <kbd>⌘</kbd><kbd>W</kbd> |
| Reload | <kbd>⌘</kbd><kbd>R</kbd> |
| Next / previous tab | <kbd>⌃</kbd><kbd>⇥</kbd> / <kbd>⌃</kbd><kbd>⇧</kbd><kbd>⇥</kbd> |
| Jump to tab N | <kbd>⌘</kbd><kbd>1</kbd> … <kbd>⌘</kbd><kbd>9</kbd> (<kbd>⌘9</kbd> is always the last one) |
| Zoom in / out / reset | <kbd>⌘</kbd><kbd>+</kbd> / <kbd>⌘</kbd><kbd>−</kbd> / <kbd>⌘</kbd><kbd>0</kbd> |
| Measure wider / narrower / full | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>=</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>−</kbd> / <kbd>⌥</kbd><kbd>⌘</kbd><kbd>0</kbd> |
| Reveal in Finder | <kbd>⌘</kbd><kbd>⇧</kbd><kbd>R</kbd> |
| Open in default editor | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| Find / next / previous | <kbd>⌘</kbd><kbd>F</kbd> / <kbd>⌘</kbd><kbd>G</kbd> / <kbd>⇧</kbd><kbd>⌘</kbd><kbd>G</kbd> |

- Drop a `.md` anywhere in the window to open it; double-click the empty tab bar for a new tab.
- Quick Look zooms too: **⌘+ / ⌘− / ⌘0**, up to 3×, visual zoom (`magnification`); pinch is the same path.
- The measure setting is app-only: the extension cannot read app preferences, so Quick Look is always full width.

## Known limitations

- **arm64 only**: no universal2 build, Intel Macs are out.
- **No Developer ID**: first launch is blocked by Gatekeeper, and the app cannot enter the
  official `homebrew-cask`.
- **Read-only**: no editing or saving. A design choice.
- **64 KB preview cap**: larger files are truncated at a block boundary with a "load more"
  button. The app itself has no cap.
- **Remote images are never loaded**: CSP allows `img-src data:` only — offline by design.
  shields.io badges are dropped rather than rendered as broken boxes.
- **Quick Look cannot read images in subdirectories**: the system only grants access to the
  previewed file itself, so `docs/img/x.png` does not appear in Quick Look (the app is fine).
- **Release assets live in another repository**:
  [Czw96/homebrew-spacedown](https://github.com/Czw96/homebrew-spacedown), which is also where
  the Cask points — so this repository's Releases page is empty.
- **No iOS / iPadOS**: Quick Look extensions, `DispatchSource` and AppKit make this macOS-only.

## Troubleshooting

- **Space shows source / monospaced text**: the claim didn't take — run the menu item again and
  disable other Markdown preview extensions (WPS on this machine:
  `pluginkit -e ignore -i com.kingsoft.wpsoffice.mac.WPSQuickLook`).
- **Rebuilt and reinstalled, nothing changed**: the build directory is registered as a second
  extension; see `docs/构建与发布.md`.
- **Double-clicking a `.md` doesn't render**: use "Set as default .md handler" in Settings.

To see who is actually rendering, read the log:

```bash
/usr/bin/log stream --predicate 'subsystem == "cn.29dev.Spacedown"' --style compact
```

`preview file=` means we took over; no output at all means the extension was never loaded.

## Build from source

```bash
python3 scripts/gen_project.py      # the Xcode project is generated; re-run when adding files
xcodebuild -project Spacedown.xcodeproj -scheme Spacedown -configuration Release \
           -derivedDataPath ~/Library/Caches/Spacedown/DerivedData build
```

Installing, claiming Quick Look, releasing, notarizing and the self-update keys are documented
in [`docs/构建与发布.md`](docs/构建与发布.md) (Chinese) — including three "silent failure" traps
that will save you half a day.

## Project layout

```
Spacedown/            main app (AppKit)
QuickLookPreview/     Quick Look extension (.appex)
LinkOpener/           XPC service: opens links on behalf of the sandboxed extension
Packages/Core/        cmark-gfm + MarkdownKit (render/truncate) + SharedTheme (shell/theme) + DevTools (benchmarks)
scripts/              gen_project.py / release.sh / sign_update.swift
docs/                 design doc / performance analysis / code review / build & release
```

| Document | Contents |
|---|---|
| [`docs/技术方案.md`](docs/技术方案.md) | Architecture and the reasoning behind every decision |
| [`docs/性能分析.md`](docs/性能分析.md) | Where the time actually goes (answer: 99% in WebKit) |
| [`docs/代码审查.md`](docs/代码审查.md) | File-by-file review notes, including what was left unfixed |
| [`docs/构建与发布.md`](docs/构建与发布.md) | Build, install, claim, release, self-update keys |

## Contributing

Single-maintainer project, and an AI-generated codebase — reviewing outside PRs costs more than
writing the code:

- **Issues are welcome**: bugs, odd typography, Quick Look behaviour differences. Include your
  macOS version and a sample file.
- **Open an issue before a PR**: unsolicited PRs may be closed.
- Docs fixes, typos, translation improvements: PR directly.

## AI disclosure

**The code in this project is generated by an AI coding assistant (WorkBuddy).** Not a
boilerplate disclaimer — here is the split:

| Stage | Who |
|---|---|
| Requirements, product judgement, on-device acceptance | Human (repository owner) |
| Architecture, technical decisions, performance measurement and trade-offs | Proposed by AI, vetoed or confirmed by human |
| Swift / C glue code, scripts, documentation | AI-generated |
| Review and sign-off before each commit | Human |
| Pitfall archives and review notes | Written by AI, with human measurements added |

What you can verify:

- Every decision in [`docs/技术方案.md`](docs/技术方案.md) carries a "why not the alternative",
  and several of them are **AI drafts the human rejected** (the clearest example: a render cache
  was planned, measured at ~0 benefit, and dropped).
- Every "measured" number in the docs comes from the benchmark tools under
  `Packages/Core/Sources/DevTools/` — AI-written, but you can rerun them yourself.
- Comments explain *why*, never restate *what* — the easiest way for generated code to become
  noise, so this repo pushes the other way on purpose.

**Limitations, stated plainly**: AI-generated code leans on measurement rather than reasoning at
edge cases, which is why the repo keeps a pile of one-off diagnostics and pitfall write-ups
(`docs/修复记录-*.md`). If something behaves oddly, suspect that first.

## License

[MIT](LICENSE). The renderer [cmark-gfm](https://github.com/github/cmark-gfm) is BSD-2-Clause;
icon and visuals are drawn by this project ([`design/logo/build_logo.py`](design/logo/build_logo.py)).
