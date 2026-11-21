# Recipe: Self-Drawn Apps (Empty AX Tree)

**App category:** Fully custom-drawn UIs where the accessibility tree is
nearly empty — native IM clients (WeChat, QQ), game launchers, menu-bar
utilities, kiosk-style apps. Signature: `ax_tree` returns a handful of
AXWindow/AXGroup nodes with no useful leaves.

## The channel stack

When AX has nothing to offer, fall through in this order:

1. **OCR targeting (v0.2.0, preferred)** — `{"op":"click","ocr":"搜索","hid":1}`
   runs Vision OCR inside the engine, finds the text, and clicks its center.
   One round-trip replaces the whole measure-and-click loop; Chinese and
   English both work (`recognitionLanguages: zh-Hans, en-US`). List hits
   first with `{"op":"ocr","text":"关键词"}` or standalone
   `axc ocr --pid N [--text S]` (prints `HIT «text» center=(x,y)` lines).
   The engine picks the **shortest matching text** as the click target —
   prefer distinctive keywords over single common characters.
2. **ax_shot** — see the screen (JPEG ~100KB, one round-trip). Only needed
   to eyeball layout or verify a state OCR cannot express (colors, images).
3. **Visual coordinates** — measure targets on the screenshot, convert:
   `global = windowOrigin + shotOffset × (windowSize / shotSize)`.
4. **HID click** (`{"op":"click","x":…,"y":…,"hid":1}`) — synthetic
   postToPid events do not reach self-drawn UIs; HID-level events do.
5. **CGEvent typing** — `{"op":"type","text":"…"}` falls back to
   `CGEventKeyboardSetUnicodeString`, which delivers Unicode (CJK included)
   into apps with no focusable AX text element.
6. **Screenshot verification** — with no AX values to read back, confirm
   state changes by screenshot. OCR itself is also a verifier: re-running
   `{"op":"ocr","text":"新状态文本"}` after an action proves the UI changed
   without spending a screenshot round.

## Worked example: sending an IM message (4 rounds, ~1 minute)

```json
[{"op":"click","x":237,"y":57,"hid":1}]        // search box
// type contact name → CGEvent delivers CJK
[{"op":"key","key":"return"}]                  // first search hit auto-selected
[{"op":"click","x":780,"y":735,"hid":1}]       // message input
// type message → return sends
```

Each round = one screenshot read to locate the next target. Total: 4
round-trips for a task that vision-only agents burn 20+ on.

## When the tree is *partially* populated

Some self-drawn apps expose a few actionable AX elements (toolbar buttons,
tab bars). Always run `ax_tree --clickable` first — a single usable AX handle
beats three screenshot rounds. Mix freely: AX for what it can see, visual+HID
for what it can't.

## Guard rails

- HID events go to the **frontmost app**. The engine's front-guard activates
  the target pid first and warns (`WARN_FRONT`) if it could not — on macOS 14+
  programmatic activation is unreliable; if you see the warning, click the
  target's Dock icon first (a HID click on a Dock icon activates that app).
- Nothing is verifiable via AX here, so the engine honestly reports
  `unverified` — budget one screenshot per state milestone and no more.
