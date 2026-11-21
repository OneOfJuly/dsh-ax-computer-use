# Task Recipes

Reusable step-by-step playbooks for common computer-use patterns. Each recipe
encodes what *kind* of app you are driving and which axc channel works there —
not one specific app.

| Recipe | App category | Core channel |
|---|---|---|
| [web-form.md](web-form.md) | Electron/CEF apps with web forms (antd selects, date pickers) | visual coords + HID click + inline `verify` |
| [self-drawn-app.md](self-drawn-app.md) | Fully self-drawn UIs (empty AX tree): IM apps, game launchers, menu-bar tools | screenshot → coords → HID click + CGEvent typing |

## The universal pattern

Every recipe follows the same loop, which is the whole point of this plugin:

```
one batched ax_act call  →  per-step verify guards  →  abort on first mismatch
        ↓ abort?                       ↓ all confirmed?
read the error line, fix ONE step, rerun      done — zero extra screenshot rounds
```

Rules of thumb baked into every recipe:

1. **Batch everything you can.** Each `ax_act` is one LLM round-trip; a whole
   form should be 1–2 calls, not 15.
2. **Put a `verify` on every state-changing click** whose result you care about
   (dropdown picks, toggles, submits). A wrong pick aborts the chain instead of
   poisoning the steps after it.
3. **CEF frames lie.** Inside Electron/CEF web content, click by screenshot
   coordinates, not by AX frame — but *verify* by AX value (the value channel
   is truthful even when frames are not).
4. **Budget before you start.** If a channel produces no progress after 3
   attempts, switch (API/CLI → CDP → AX batch → visual coords → ask the user).
