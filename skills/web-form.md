# Recipe: Web Forms in Electron/CEF Apps

**App category:** Electron or CEF-embedded web UIs — enterprise tools, admin
consoles, chat apps with built-in webviews (antd/MUI select dropdowns, date
pickers, modals). Examples: Lark/Feishu internal tools, VS Code webviews,
Slack modals.

## Why this is its own recipe

CEF web elements report **unreliable AX frames** (systematically offset, no
fixed mapping). So:

- **Click by** screenshot coordinates (ax_shot → measure → convert)
- **Verify by** AX value (axtree / verify guard — the value channel is truthful)

Coordinate conversion: `global = windowOrigin + screenshotOffset × (windowSize / shotSize)`.

## The pattern

```json
[
  {"op":"click","x":876,"y":135,"hid":1},
  {"op":"wait","ms":900},
  {"op":"click","x":876,"y":168,"hid":1,
   "verify":{"path":"<field-path>:AXTextField","win":1,"contains":"<expected>","wait":900}},
  {"op":"click","x":703,"y":358,"hid":1},
  {"op":"click","path":"<duration-path>:AXTextField","win":1,
   "verify":{"path":"<duration-path>:AXTextField","win":1,"contains":"0.125","wait":600}}
]
```

Step by step:

1. **Open the dropdown** — HID click the field's screenshot position.
2. **Pick the option** — HID click the option's screenshot position, **with a
   `verify`** reading the field back. Dropdown item order changes between
   opens; the verify guard is what turns "picked wrong item" from a silent
   poisoned form into a one-line abort you can fix and rerun.
3. **Quick buttons / toggles** — same: click, verify the value changed.
4. **Free text** — click the textarea, then `type` (AXValue append, verified).

## Failure modes this recipe absorbs

| Symptom | Cause | What happens now |
|---|---|---|
| `VERIFY FAIL ... got v=«» expected contains «X»` | dropdown never opened | chain aborts at that step; retry the open-click |
| `VERIFY FAIL ... got v=«GAMMA-…» expected «HA»` | item order shifted | chain aborts; re-screenshot, click the right row |
| click lands but nothing happens | CEF frame offset | you used a path/frame click — switch to screenshot coords |
| modal drifted 30px since last session | dynamic layout | verify catches the wrong pick; coords from a fresh screenshot fix it |

## Real numbers

A full 5-field form (category → project → role(auto) → duration → content) in
a CEF app: **2 batched calls + 1 correction round** when a dropdown order
shifted, versus 15–18 rounds clicking one field at a time with screenshot
verification after every step.
