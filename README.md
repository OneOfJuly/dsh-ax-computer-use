# dsh-ax-computer-use

[English](README.md) | [中文](README.zh.md)

**Universal computer use for macOS / Windows / Linux, AX-first** — for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness). The agent reads the platform accessibility tree (AX / UIA / AT-SPI2) instead of staring at screenshots, acts in **batched, machine-verified steps**, and only falls back to vision when pixels are genuinely needed. Works across **every category of desktop app**, not just one:

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
- `click` — HID-level global click with a **frontmost-app guard**: if the target app isn't frontmost, it activates first and appends `WARN_FRONT` when the click would have landed on the wrong window. Optional **inline verify guard** (`"verify":{"path":…,"contains":"…"}`) reads the target's value back after the click and **aborts the remaining batch** on mismatch — a wrong dropdown pick stops the chain instead of poisoning every field after it. For fully self-drawn UIs (WeChat, game launchers) that expose no AX tree at all, `"ocr"` targeting runs **Vision OCR inside the engine** (`zh-Hans` + `en-US`): `{"op":"click","ocr":"搜索","hid":1}` finds the text and clicks its center in one round-trip, and `{"op":"ocr","text":"关键词"}` lists every hit with global coordinates — the vision loop collapses to a single action. `ax_shot` reports `img=W×H scale=S origin=X,Y`; `{"op":"click","shot":[px,py]}` takes screenshot pixels and maps them to the screen for you. Clicks on web content switch to HID automatically (`click-autohid`) and then **self-verify** — window list diff, focus change, or a thumbnail diff of the screen region around the click — so the status line says `confirmed (…)` or `unverified (no observable change — …)` instead of always `unverified`.
- `menu` — walks native menu hierarchies (including the AXMenu-as-children quirk), falls back to reporting the item's keyboard shortcut.
- Every batch reports `FOCUS before→after`, `FOCUSPATH`, and a **window-list diff** (`WINDOWS` — new/closed/retitled windows), so side effects surface immediately.

`ax_tree` outputs a compact, interactive-elements-first tree with stable `path:Role` refs, Chinese/English labels, focus markers, and optional text filtering that searches across all windows. `ax_shot` captures a single window (multi-display safe) and returns it through DSH's attachment pipeline. `ax_relaunch` restarts an app **with arguments** without losing login state.

## Native, web, and Electron — one toolset

- **Native apps** (all 3 OS): full a11y-tree read/write — AX on macOS, UI Automation on Windows, AT-SPI2 on Linux. `AXSetValue`-style writes land in ~8 ms with read-back confirmation. Menus, toolbar checkboxes, text insertion all verified.
- **Chrome / Chromium browsers**: the renderer AX tree is exposed, so web content is readable as text. Clicks that AX cannot dispatch fall through to **HID-grade hardware events** — verified opening bilibili's episode panel on a multi-window, multi-display setup.
- **Electron / CEF apps that hide their AX tree** (Lark, and many other Electron-based apps): `ax_relaunch --app Lark --args "--force-renderer-accessibility"` relaunches with the renderer accessibility flag — **login preserved** — and the whole web UI becomes readable and scriptable. This is the case vision-only tools simply cannot do at all.

## Install

```sh
dsh plugin add github:OneOfJuly/dsh-ax-computer-use
```

or from the plugin market (after the catalog entry lands): search **dsh-ax-computer-use** under Plugins → Discover.

Requirements:

- macOS (Apple Silicon prebuilt `bin/axc`, arm64; Intel: build from `src/axc.swift` with `swiftc -O`)
- Windows (PowerShell 5.1+ built-in; no install needed — `engines/axc.ps1`, UIA + SendInput + WinRT OCR)
- Linux (X11; needs `python3-pyatspi`, `python3-xlib`, `xdotool`, `wmctrl`, `tesseract-ocr tesseract-ocr-chi-sim`, `scrot` — `engines/axc.py`, AT-SPI2 + XTest)
- DSH ≥ 0.2.1 (tested on 0.2.2-rc.5).
- macOS: grant **Accessibility** + **Screen Recording** to the DSH host app (System Settings → Privacy & Security); the engine runs as a child process and inherits them.
- Windows: no special setup (UIA is unrestricted; OCR needs a Windows language pack).
- Linux: enable accessibility (GNOME: Settings → Accessibility, or `gsettings set org.gnome.desktop.interface toolkit-accessibility true`).

> **Platform maturity**: macOS = fully validated in production use. Windows/Linux engines implement the full contract (see [ARCHITECTURE.md](ARCHITECTURE.md)) but are awaiting first on-device validation — bug reports welcome.

## Architecture

One stateless engine per OS (`bin/axc` Swift binary on macOS, `engines/axc.ps1` PowerShell on Windows, `engines/axc.py` Python on Linux — all behind the same CLI contract, see [ARCHITECTURE.md](ARCHITECTURE.md)); `index.js` is a thin mapping to six DSH tools. Each tool call spawns one short-lived process: list windows, dump a tree, run an action batch, take a shot, or relaunch an app. No persistent state, nothing to crash, nothing to clean up.

Safety posture: HID clicks move the real cursor and are guarded by the frontmost-app check; keyboard events are posted per-process (no global focus stealing); the binary makes **no network calls** and keeps **no logs**; screenshots live only in DSH's own attachment pipeline.

## Building from source

```sh
swiftc -O -module-cache-path /tmp/axc-cache src/axc.swift -o bin/axc
```

Xcode toolchain required (`swiftc`). The module cache path must be writable; the default location is often not.

## Related

- [dsh-mac-computer-use](https://github.com/OrderG-X/dsh-mac-computer-use) — the official vision-first plugin; this project started as its faster alternative for web-heavy workflows.
- [dsh-operator](https://github.com/yffo/dsh-operator) — another community computer-use suite with browser automation via CDP.

## Credits

- [agent-desktop](https://github.com/vercel-labs/agent-desktop) (Apache-2.0) — the renderer-accessibility activation technique (set `AXManualAccessibility`, then poll with readback) and the STALE-REF / disposition reporting semantics were adopted from its design and are annotated in source ([ARCHITECTURE.md](ARCHITECTURE.md)). No code was copied; this project is an independent implementation.

## License

MIT
