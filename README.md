# dsh-ax-computer-use

[English](README.md) | [中文](README.zh.md)

**Universal computer use for macOS, AX-first** — for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness). The agent reads the macOS Accessibility tree instead of staring at screenshots, acts in **batched, machine-verified steps**, and only falls back to vision when pixels are genuinely needed. Works across **every category of Mac app**, not just one:

| App category | Example | Channel that works | Verified in the wild |
|---|---|---|---|
| Native AppKit | TextEdit, Finder, most system apps | full AX: read tree, `AXSetValue` write-back, menu traversal | end-to-end |
| Chromium browsers | Chrome, Edge, multi-window multi-display | renderer AX tree + HID-grade clicks | bilibili episode panel on a 2-display setup |
| Electron / CEF embeds | Lark/Feishu, Slack, VS Code webviews | forced-renderer-AX relaunch + visual coords + inline verify | 5-field enterprise form with antd dropdowns |
| Self-drawn UIs (empty AX) | WeChat, game launchers, kiosk apps | screenshot → coords → HID click + CGEvent CJK typing | IM message sent in 4 rounds |

Six tools: `ax_windows` / `ax_tree` / `ax_act` / `ax_read` / `ax_shot` / `ax_relaunch`. Task recipes for each category live in [skills/](skills/).

<p align="center">
  <a href="assets/bilibili-episode-panel.jpg"><img src="assets/bilibili-episode-panel.jpg" width="560" alt="A web page read as an accessibility tree and driven by HID-grade clicks"></a>
</p>
<p align="center"><sub>Web content read as text (buttons, links, player controls) and driven by HID-grade clicks on a multi-window, multi-display Chrome — no pixel guessing anywhere in the loop.</sub></p>

## Why

Vision-only computer use is slow and blind, in exactly this loop:

> screenshot → model looks at pixels → guesses a coordinate → clicks → screenshot again to check → guess again…

Every step costs a full-resolution image and a model round-trip. Twenty-plus cycles to fill one form is normal. And when a click lands on the wrong element, nothing tells you — the model only finds out from the *next* screenshot, if it checks at all.

This plugin flips the loop:

| | Vision-only clicking | dsh-ax-computer-use |
|---|---|---|
| Read the screen | Full screenshot + vision model every step | AX tree as text (~1 KB per window, ~100 ms to read) |
| Act | One synthetic click per turn | **Batched JSON actions** — fill the form + submit + verify in one call |
| Know what happened | Hope the next screenshot shows it | Every action returns `confirmed` / `unverified` / `suspected_noop` / `errors`, plus focus before→after and a window-list diff |
| Find a control | Re-screenshot, re-locate, re-guess | Locate by **text** (`{"op":"press","text":"提交","role":"AXButton"}`) — immune to dynamic DOM re-indexing |
| Screenshots | Raw frames | `screencapture` → JPEG q80 @1280px: 2.1 MB → ~95 KB (**−95% tokens**) |

Measured on real tasks: a form-filling workflow in a CEF-based enterprise web app that takes 20–30 minutes of vision-clicking was completed end-to-end (open form → fill every field with dropdowns → verify each step → close) in **~3 minutes including screenshot verification** — roughly **10× fewer model round-trips**.

## What it actually verifies

`ax_act` takes a JSON array of actions (`press`, `set`, `type`, `key`, `click`, `menu`, `focus`, `read`, `select`, `scroll`, `wait`) and returns one status line per action plus a summary. Verification is real, not a return-code rubber stamp:

- `set` / `type` — write via `AXSetValue`, then **read the value back**; append targets the focused element's current value so partial writes are visible.
- `press` — checks the element's `AXActions` list, falls back through checkbox value-toggle, and for web elements detects the "AXPress accepted but nothing happened" trap (renderer accessibility half-active) and **reports `unverified` instead of pretending**; optional HID-grade click fallback.
- `click` — HID-level global click with a **frontmost-app guard**: if the target app isn't frontmost, it activates first and appends `WARN_FRONT` when the click would have landed on the wrong window. Optional **inline verify guard** (`"verify":{"path":…,"contains":"…"}`) reads the target's value back after the click and **aborts the remaining batch** on mismatch — a wrong dropdown pick stops the chain instead of poisoning every field after it.
- `menu` — walks native menu hierarchies (including the AXMenu-as-children quirk), falls back to reporting the item's keyboard shortcut.
- Every batch reports `FOCUS before→after`, `FOCUSPATH`, and a **window-list diff** (`WINDOWS` — new/closed/retitled windows), so side effects surface immediately.

`ax_tree` outputs a compact, interactive-elements-first tree with stable `path:Role` refs, Chinese/English labels, focus markers, and optional text filtering that searches across all windows. `ax_shot` captures a single window (multi-display safe) and returns it through DSH's attachment pipeline. `ax_relaunch` restarts an app **with arguments** without losing login state.

## Native, web, and Electron — one toolset

- **Native macOS apps**: full AX read/write; `AXSetValue` writes land in ~8 ms with read-back confirmation. Menus, toolbar checkboxes, text insertion all verified.
- **Chrome / Chromium browsers**: the renderer AX tree is exposed, so web content is readable as text. Clicks that AX cannot dispatch fall through to **HID-grade hardware events** — verified opening bilibili's episode panel on a multi-window, multi-display setup.
- **Electron / CEF apps that hide their AX tree** (Lark, and many other Electron-based apps): `ax_relaunch --app Lark --args "--force-renderer-accessibility"` relaunches with the renderer accessibility flag — **login preserved** — and the whole web UI becomes readable and scriptable. This is the case vision-only tools simply cannot do at all.

## Install

```sh
dsh plugin add github:OneOfJuly/dsh-ax-computer-use
```

or from the plugin market (after the catalog entry lands): search **dsh-ax-computer-use** under Plugins → Discover.

Requirements:

- macOS on Apple Silicon (prebuilt `bin/axc`, arm64). Intel Macs: build from `src/axc.swift` with `swiftc -O` and replace the binary.
- DSH ≥ 0.2.1 (tested on 0.2.2-rc.5).
- macOS permissions: **Accessibility** + **Screen Recording** granted to the DSH host app (System Settings → Privacy & Security). The plugin engine runs as a child process and inherits them — no per-tool prompts.

## Architecture

One stateless Swift binary (`bin/axc`, ~170 KB, no daemon, no dependencies) does all macOS work; `index.js` is a thin mapping to six DSH tools. Each tool call spawns one short-lived process: list windows, dump a tree, run an action batch, take a shot, or relaunch an app. No persistent state, nothing to crash, nothing to clean up.

Safety posture: HID clicks move the real cursor and are guarded by the frontmost-app check; keyboard events are posted per-process (no global focus stealing); the binary makes **no network calls** and keeps **no logs**; screenshots live only in DSH's own attachment pipeline.

## Building from source

```sh
swiftc -O -module-cache-path /tmp/axc-cache src/axc.swift -o bin/axc
```

Xcode toolchain required (`swiftc`). The module cache path must be writable; the default location is often not.

## Related

- [dsh-mac-computer-use](https://github.com/OrderG-X/dsh-mac-computer-use) — the official vision-first plugin; this project started as its faster alternative for web-heavy workflows.
- [dsh-operator](https://github.com/yffo/dsh-operator) — another community computer-use suite with browser automation via CDP.

## License

MIT
