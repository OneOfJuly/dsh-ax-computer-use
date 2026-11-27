# ax-computer-use v2 Architecture

> One engine contract, three platform implementations. The model learns ONE interface;
> the plugin routes to the right native engine for the OS.

## Design principles (learned from v1 + agent-desktop comparison)

1. **AX/UIA/AT-SPI first, pixels last.** Reading the accessibility tree is 10-50x cheaper
   than vision loops. Screenshot+OCR is the fallback, not the default.
2. **Every action returns evidence.** `confirmed / unverified / suspected_noop / errors`
   per step. The agent must always know what it did (this was the #1 failure of
   screenshot-loop plugins: blind clicking with no feedback).
3. **Batched actions with abort-on-first-failure.** One round-trip executes a whole
   form fill; `abort_on_error` stops at the first failed step instead of poisoning
   downstream fields.
4. **HID-grade input is the floor.** Synthetic/postToPid events do not reach Chromium
   renderers reliably. All engines must support OS-level input injection
   (CGEvent / SendInput / XTest) with an optional `hid: 1` flag.
5. **Activate the renderer, don't wait for it.** Chromium/Electron apps expose no web
   content until their renderer accessibility is activated. Engines must actively
   poke it (AXManualAccessibility / --force-renderer-accessibility awareness) and
   poll-with-readback instead of returning an empty tree.
6. **OCR targeting built-in.** Self-drawn UIs (WeChat) and CEF dropdown overlays never
   enter the a11y tree. `ocr` + `click ocr:` closes that gap without external scripts.
7. **One tool face for the model.** Six tools (ax_windows/ax_tree/ax_act/ax_read/
   ax_shot/ax_relaunch) unchanged across platforms. Platform differences live below
   the engine contract.

## Engine contract (stable CLI)

All engines implement the same subcommands and print the same line protocol:

```
axc <subcommand> [flags]
  winlist [--pid N]                 -> window list: id, pid, app, title, bounds
  axtree --pid N [--win I] [--depth D] [--max N] [--clickable] [--text S] [--menu] [--root REF]
                                    -> [ref] role t=title v=value [ph=placeholder] [FOCUS] [press] [@cx,cy]
                                    depth default 18 (Electron content sits at 10-14); --text searches the full
                                    depth and prints hits (>>) + ancestors; --root dumps one subtree with refs
                                    still numbered from the window root. Chromium trees are warmed (children-only
                                    passes) before dumping, so lazily serialised subtrees don't go missing.
  axread --pid N --path REF         -> role/title/value/focused/actions/frame
  axact --pid N --json '[actions]'  -> per-action status lines + SUMMARY
  shot --pid N [--out P] [--max L]  -> JPEG (long edge <= L, default 1280); OK line carries
                                       img=W×H scale=S origin=X,Y for mapping pixels -> screen
  ocr --pid N --text S [--assert-absent 1]  -> hit coordinates or ABSENT
  relaunch --app NAME [--args "…"]  -> kill (probe liveness first) + relaunch with args

axact action ops (all engines):
  press / click {x,y | "shot":[px,py] | target} / set {value} / type {text[,hid]} / key {spec[,hid]}
  focus / menu {path} / select / read / frame / wait {ms} / scroll {dy}
  every op accepts verify: {path|text, contains?, wait?}  -> VERIFY FAIL aborts batch
  clicks on web content fall back to HID automatically (click-autohid) and self-verify against
  window / focus / screen-region change, so a click reports confirmed or unverified with a reason.
  every op accepts locate by {"path": ref} OR {"text": S, "role": R?, "nth": N}
```

Action result lines (identical grammar on every platform):

```
act[i] OK confirmed <op> …          -> performed + observed state change
act[i] OK unverified <op> …         -> performed, no observable proof (web elements)
act[i] SUSPECTED_NOOP <op> …        -> performed, nothing changed
act[i] VERIFY FAIL <op> …           -> post-condition not met (abort trigger)
SUMMARY confirmed=A unverified=B suspected_noop=C errors=D [ABORTED at action[N]]
FOCUS before -> after / WINDOWS +/- diffs
```

## Platform matrix

| Capability | macOS engine (Swift) | Windows engine (PowerShell 5.1+ / C# opt) | Linux engine (Python 3.8+) |
|---|---|---|---|
| A11y tree | AX API (AXUIElement) | UIA via .NET System.Windows.Automation | AT-SPI2 via pyatspi (D-Bus) |
| Input injection | CGEvent (.cghidEventTap) | SendInput (P/Invoke) | XTest (X11) / uinput (Wayland) |
| Screenshot | screencapture + sips JPEG | System.Drawing CopyFromScreen | gnome-screenshot / import / Pillow ImageGrab |
| OCR | Vision.framework | Windows.Media.Ocr (WinRT) | tesseract (pytesseract) |
| Renderer activation | AXManualAccessibility + poll | UIA is default-on for Chromium; still poll+readback | AT-SPI usually auto; poll+readback |
| App lifecycle | NSWorkspace + kill(pid,0) probe | Get-Process + Start-Process | psutil / subprocess |
| Ship as | prebuilt static binary (~240KB) | .ps1 script (zero deps) + opt .exe | .py script (needs python3-xlib/pyatspi/tesseract) |

## v2 feature upgrades (this release)

1. **Renderer activation with readback** (macOS first, contract for all): when a tree
   read returns no AXWebArea/content, engine sets AXManualAccessibility=true,
   polls up to ~6s (10 x 600ms), re-reads; reports `AX_ACTIVATED pid=N` when it
   worked, so the model knows why the tree grew.
2. **Frontmost guard on every coordinate action**: activate target app (probe with
   kill/Get-Process/frontmost API), sleep, re-check; emit `WARN_FRONT` when unable.
3. **`click_ocr` composite op**: shot -> OCR -> coordinate transform -> HID click ->
   optional ocr re-read verify. One action, five steps, the workhorse for CEF
   overlays and self-drawn UIs.
4. **Spatial layout cache** (`--remember key`, `--recall key`): store verified screen
   coordinates per app+key in ~/.ax-cu/cache.json; `click --key 类别` hits the cache,
   falls back to OCR re-target on miss.
5. **Form error capture**: after submit-type actions, scan the fresh tree for
   role=alert / AXStaticText matching common error class names; report
   `FORM_ERROR: <text>` in SUMMARY.
6. **select_option composite op**: open dropdown -> (search-type if query given) ->
   OCR/AX locate option -> click -> read back field value -> verify.

## What we keep that agent-desktop lacks

- Chromium/Electron CEF playbook: frame-vs-visual coordinate divergence handling,
  HID-typing into comboboxes, AXPress no-op detection (AD explicitly refuses web UIs).
- OCR + visual fallback (AD has zero vision).
- Batched actions with per-step verification and abort semantics.
- Task recipes (skills/) encoding hard-won platform knowledge.

## What we adopt from agent-desktop

- Renderer AX activation with debounce+readback (their Sept fix; Apache-2.0, noted).
- Strict STALE_REF-style semantics: resolve target fresh per action, fail loudly
  instead of clicking the wrong thing.
- disposition-style delivery reporting (delivered_verified / delivered_unverified).

## Non-goals (v2)

- Remote/headless operation, multi-agent cursor choreography (AD's niche).
- Vision-model click prediction (pure OCR + tree only; keeps deps light).
