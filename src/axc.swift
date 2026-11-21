// axc — AX-first Mac computer-use engine (single-file Swift CLI, stateless).
//
// Subcommands:
//   winlist                          — on-screen windows: pid<TAB>windowId<TAB>app<TAB>title<TAB>x,y w×h
//   axtree --pid N [--win I] [--depth D] [--max N] [--clickable] [--text S]
//                                    — compact ref tree; refs are "idx.chain:Role" from the window root
//   axread --pid N --path REF        — attributes of one element (role/title/desc/value/focused/enabled/actions)
//   axact  --pid N --json ACTIONS    — batched verified actions; prints per-action status + summary
//   shot   --pid N [--out F] [--max-edge N] — window screenshot via screencapture(1); prints rect line
//   ocr    --pid N [--text S]        — Vision OCR of the window: HIT «text» center=(x,y) lines
//   relaunch --app NAME [--args "…"] — SIGTERM quit + `open -a` with args; prints new pid
//
// Refs stay valid across processes: path is a child-index chain from the dumped root,
// and the ":Role" suffix is identity-checked at resolution time (±3 sibling probe on shift).

import ApplicationServices
import AppKit
import Foundation
import Vision

let AX_TIMEOUT: CFTimeInterval = 3.0
let AXAttrActions = "AXActions"
let AXAttrMenu = "AXMenu"
let CLICKABLE_ROLES: Set<String> = [
    "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
    "AXLink", "AXSlider", "AXTextField", "AXTextArea", "AXComboBox", "AXMenuItem",
    "AXMenuBarItem", "AXTabGroup", "AXRow", "AXCell", "AXStaticText", "AXImage",
]
let VALUE_ROLES: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXStaticText", "AXValueIndicator", "AXSlider"]

// ── AX helpers ────────────────────────────────────────────────────────────────

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    let r = AXUIElementCopyAttributeValue(el, name as CFString, &v)
    return r == .success ? v : nil
}
func strAttr(_ el: AXUIElement, _ name: String) -> String? {
    guard let v = attr(el, name) else { return nil }
    return v as? String
}
func kids(_ el: AXUIElement) -> [AXUIElement] {
    guard let c = attr(el, kAXChildrenAttribute) else { return [] }
    return ((c as? [AnyObject]) ?? []).filter { CFGetTypeID($0) == AXUIElementGetTypeID() }.map { $0 as! AXUIElement }
}
func setAppTimeout(_ app: AXUIElement) { AXUIElementSetMessagingTimeout(app, Float(AX_TIMEOUT)) }
func appElement(_ pid: pid_t) -> AXUIElement {
    let a = AXUIElementCreateApplication(pid)
    setAppTimeout(a)
    return a
}
func isFocused(_ el: AXUIElement) -> Bool {
    guard let f = attr(el, kAXFocusedAttribute), CFGetTypeID(f) == CFBooleanGetTypeID() else { return false }
    return CFBooleanGetValue(unsafeBitCast(f, to: CFBoolean.self))
}
func roleOf(_ el: AXUIElement) -> String { strAttr(el, kAXRoleAttribute) ?? "?" }

/// Identity string for a node: role + best label (title ?? description).
func underWebArea(_ el: AXUIElement) -> Bool {
    var cur = el
    for _ in 0..<50 {
        if roleOf(cur) == "AXWebArea" { return true }
        guard let p = attr(cur, kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else { return false }
        cur = p as! AXUIElement
    }
    return false
}

func ident(_ el: AXUIElement) -> (role: String, label: String) {
    let role = roleOf(el)
    let label = strAttr(el, kAXTitleAttribute) ?? strAttr(el, kAXDescriptionAttribute) ?? ""
    return (role, label)
}

/// Resolve "12.3.0:AXButton" from root. Verify role at the LAST level; on mismatch probe
/// siblings within ±3 sharing the same role (UI shifted by an insert).
func resolve(_ root: AXUIElement, _ ref: String) -> AXUIElement? {
    let parts = ref.split(separator: ":")
    let chain = parts[0].split(separator: ".").compactMap { Int($0) }
    let wantRole = parts.count > 1 ? String(parts[1]) : nil
    var cur = root
    for (i, idx) in chain.enumerated() {
        let ks = kids(cur)
        let last = i == chain.count - 1
        if idx >= 0 && idx < ks.count {
            if last, let want = wantRole, roleOf(ks[idx]) != want {
                if let hit = ks.enumerated().first(where: { abs($0.offset - idx) <= 3 && $0.offset != idx && roleOf($0.element) == want }) {
                    cur = hit.element
                    continue
                }
                return nil
            }
            cur = ks[idx]
        } else { return nil }
    }
    if let want = wantRole, roleOf(cur) != want { return nil }
    return cur
}


/// Find element by visible text (title/value/description contains), optional role filter; nth = 0-based match index.
func findInTree(_ root: AXUIElement, _ text: String, _ role: String?, _ nth: Int) -> AXUIElement? {
    var found: AXUIElement? = nil
    var hits = 0
    var visited = 0
    func label(_ el: AXUIElement) -> String {
        return (strAttr(el, kAXTitleAttribute) ?? "") + " \u{1}" + (strAttr(el, kAXValueAttribute) ?? "") + " \u{1}" + (strAttr(el, kAXDescriptionAttribute) ?? "")
    }
    func walk(_ el: AXUIElement, _ depth: Int) -> Bool {
        if visited > 4000 || depth > 30 { return false }
        visited += 1
        let r = roleOf(el)
        if role == nil || r == role {
            let lab = label(el)
            if text.isEmpty || lab.localizedCaseInsensitiveContains(text) {
                if hits == nth { found = el; return true }
                hits += 1
            }
        }
        for k in kids(el) { if walk(k, depth + 1) { return true } }
        return false
    }
    _ = walk(root, 0)
    return found
}

/// Resolve target from action args: "path" ref or "text"(+"role","nth") query. Searches hinted window first, then all windows.
func resolveTarget(_ a: [String: Any], _ app: AXUIElement) throws -> AXUIElement {
    if let ref = a["path"] as? String {
        let root = axRoot(app, (a["win"] as? Int) ?? 0)
        guard let el = resolve(root, ref) else { throw ActError(msg: "STALE \(ref) — retry with {text:…} locator") }
        return el
    }
    let text = (a["text"] as? String) ?? ""
    let role = a["role"] as? String
    let nth = (a["nth"] as? Int) ?? 0
    if text.isEmpty && (role ?? "").isEmpty {
        throw ActError(msg: "need path, or text, or role to locate the element")
    }
    let wins = axWindows(app)
    let hint = (a["win"] as? Int) ?? -1
    var order: [AXUIElement] = []
    if hint >= 0 && hint < wins.count { order.append(wins[hint]) }
    for (i, w) in wins.enumerated() where i != hint { order.append(w) }
    for w in order {
        if let el = findInTree(w, text, role, nth) { return el }
    }
    throw ActError(msg: "NOT_FOUND text=«\(text)»\(role != nil ? " role=\(role!)" : "") searched \(wins.count) window(s)")
}

/// Build ref for a node during dump: chain of child indices from root + role.
func refOf(_ chain: [Int], _ role: String) -> String {
    (chain.map { String($0) }.joined(separator: ".")) + ":" + role
}

// ── window enumeration ────────────────────────────────────────────────────────

func winlist(_ pidFilter: Int32? = nil) {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
    for w in list {
        let layer = w[kCGWindowLayer as String] as? Int ?? 99
        guard layer == 0 else { continue }
        let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
        if let f = pidFilter, pid != Int(f) { continue }
        let wid = w[kCGWindowNumber as String] as? Int ?? 0
        let app = w[kCGWindowOwnerName as String] as? String ?? "?"
        let title = w[kCGWindowName as String] as? String ?? ""
        guard let b = w[kCGWindowBounds as String] as? [String: Any],
              let x = b["X"] as? Double, let y = b["Y"] as? Double,
              let wd = b["Width"] as? Double, let ht = b["Height"] as? Double else { continue }
        if wd < 2 || ht < 2 { continue }
        print("\(pid)\t\(wid)\t\(app)\t\(title)\t\(Int(x)),\(Int(y)) \(Int(wd))×\(Int(ht))")
    }
}

// ── axtree dump ───────────────────────────────────────────────────────────────

func esc(_ s: String, _ n: Int) -> String {
    let t = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
    return String(t.prefix(n))
}

func axtree(args: [String: String]) {
    guard let pid = Int32(args["pid"] ?? "") else { print("ERR bad pid"); exit(2) }
    let depthMax = Int(args["depth"] ?? "9") ?? 9
    let nodeCap = Int(args["max"] ?? "900") ?? 900
    let clickableOnly = args["clickable"] == "1"
    let textFilter = args["text"]
    let expandMenus = args["menu"] == "1"

    let app = appElement(pid)
    var roots: [AXUIElement] = []
    var rootTitle = ""
    let els = appWindows(app)
    if let wi = Int(args["win"] ?? ""), wi < els.count { roots = [els[wi]]; rootTitle = strAttr(els[wi], kAXTitleAttribute) ?? "" }
    else if !els.isEmpty { roots = [els[0]]; rootTitle = strAttr(els[0], kAXTitleAttribute) ?? "" }
    let dumpRoot = roots.first ?? app
    let rootLabel = rootTitle.isEmpty ? "(app)" : "win «\(esc(rootTitle, 48))»"

    // Cross-window text search: with a text filter and no explicit win, scan every window
    // and report the first one that yields hits (Chrome's AX window 0 is often an empty helper window).
    let explicitWin = Int(args["win"] ?? "")
    var candidates: [(AXUIElement, String)] = [(dumpRoot, rootTitle)]
    if let t = textFilter, !t.isEmpty, explicitWin == nil, els.count > 1 {
        candidates = els.map { ($0, strAttr($0, kAXTitleAttribute) ?? "") }
    }

    var out: [String] = []
    var count = 0
    var truncated = false
    let focusRef = attr(app, kAXFocusedUIElementAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    var focusChain: [Int] = []

    func dump(_ el: AXUIElement, chain: [Int], depth: Int) {
        guard !truncated else { return }
        count += 1
        if count > nodeCap { out.append("!TRUNCATED (raise --max or narrow --depth)"); truncated = true; return }
        let (role, label) = ident(el)
        if !expandMenus && (role == "AXMenuBar" || role == "AXMenu") {
            out.append("\(String(repeating: " ", count: depth * 2))[\(refOf(chain, role))] \(role) …menus pruned (pass menu=1 to expand)")
            return
        }
        let value = strAttr(el, kAXValueAttribute) ?? ""
        let clickable = CLICKABLE_ROLES.contains(role)
        let interactive = clickable || (attr(el, AXAttrActions) != nil && depth > 0 && (label.isEmpty == false))
        let focused = focusRef.map { $0 == el } ?? false
        if focused { focusChain = chain }
        let keep = !clickableOnly || interactive
        if keep {
            var parts = [role]
            if !label.isEmpty { parts.append("t=\(esc(label, 44))") }
            if !value.isEmpty, VALUE_ROLES.contains(role) || clickable { parts.append("v=\(esc(value, 56))") }
            if focused { parts.append("FOCUS") }
            if let acts = attr(el, AXAttrActions) as? [String], acts.contains("AXPress") { parts.append("press") }
            out.append("\(String(repeating: " ", count: depth * 2))[\(refOf(chain, role))] \(parts.joined(separator: " "))")
        }
        guard depth < depthMax else { return }
        var i = 0
        for k in kids(el) {
            var c = chain; c.append(i); i += 1
            dump(k, chain: c, depth: depth + 1)
            if truncated { return }
        }
    }
    dump(dumpRoot, chain: [], depth: 0)
    if let t = textFilter, !t.isEmpty {
        // scan further windows until hits (candidates computed above)
        var hits = out.filter { $0.contains(t) }
        if hits.isEmpty && candidates.count > 1 && explicitWin == nil {
            for (rootEl, _) in candidates.dropFirst() {
                out = []
                count = 0
                truncated = false
                focusChain = []
                dump(rootEl, chain: [], depth: 0)
                hits = out.filter { $0.contains(t) }
                if !hits.isEmpty { break }
            }
        }
        print("FILTER «\(t)» hits=\(hits.count)\(candidates.count > 1 && explicitWin == nil ? " (searched \(candidates.count) windows)" : "")")
        print(hits.prefix(60).joined(separator: "\n"))
    } else {
        print(out.joined(separator: "\n"))
    }
    print("NODES \(count)\(focusChain.isEmpty ? "" : " FOCUSPATH \(focusChain.map(String.init).joined(separator: "."))")")
}

// ── axread ────────────────────────────────────────────────────────────────────

func axread(args: [String: String]) {
    guard let pid = Int32(args["pid"] ?? ""), let ref = args["path"] else { print("ERR need pid+path"); exit(2) }
    let app = appElement(pid)
    let root = axRoot(app, winIdx: Int(args["win"] ?? "0") ?? 0)
    guard let el = resolve(root, ref) else { print("STALE ref \(ref) — re-run axtree"); exit(3) }
    print("ROLE \(roleOf(el))")
    print("TITLE \(strAttr(el, kAXTitleAttribute) ?? "")")
    print("DESC \(strAttr(el, kAXDescriptionAttribute) ?? "")")
    print("VALUE \(esc(strAttr(el, kAXValueAttribute) ?? "", 300))")
    print("FOCUSED \(isFocused(el) ? "1" : "0")")
    var settable = DarwinBoolean(false)
    AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
    print("SETTABLE \(settable.boolValue ? "1" : "0")")
    if let acts = attr(el, AXAttrActions) as? [String] { print("ACTIONS \(acts.joined(separator: ","))") }
}

func axRoot(_ app: AXUIElement, winIdx: Int) -> AXUIElement {
    let els = axWindows(app)
    if els.count > 1 || (els.count == 1 && roleOf(els[0]) == "AXWindow") {
        return els[min(max(winIdx, 0), els.count - 1)]
    }
    return app
}

// ── keyboard delivery (CGEvent, targeted to pid) ──────────────────────────────

let KEYCODES: [String: UInt16] = [
    "return": 36, "enter": 36, "tab": 48, "esc": 53, "escape": 53, "delete": 51, "backspace": 51,
    "space": 49, "up": 126, "down": 125, "left": 123, "right": 124, "forwarddelete": 117,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96,
]

func ksrc() -> CGEventSource { CGEventSource(stateID: .combinedSessionState)! }

func flags(_ mods: [String]) -> CGEventFlags {
    var f: CGEventFlags = []
    for m in mods {
        switch m {
        case "cmd", "command": f.insert(.maskCommand)
        case "ctrl", "control": f.insert(.maskControl)
        case "alt", "opt", "option": f.insert(.maskAlternate)
        case "shift": f.insert(.maskShift)
        case "fn": f.insert(.maskSecondaryFn)
        default: break
        }
    }
    return f
}

func frontGuard(_ pid: pid_t) {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    guard front != pid else { return }
    activateApp(pid, AXUIElementCreateApplication(pid))
    usleep(500000)
    let front2 = NSWorkspace.shared.frontmostApplication?.processIdentifier
    if front2 != pid {
        frontWarnStore = " WARN_FRONT pid=\(front2 ?? -1) '\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")' — HID input may land elsewhere!"
    }
}

func postKey(_ pid: pid_t, _ spec: String, hid: Bool = false) -> Bool {
    // spec: "return", "cmd+t", "ctrl+a", "shift+tab"
    let parts = spec.lowercased().split(separator: "+").map(String.init)
    guard let key = parts.last else { return false }
    let mods = Array(parts.dropLast())
    let code = KEYCODES[key] ?? (key.count == 1 ? key.uppercased().unicodeScalars.first.map { UInt16($0.value) } : nil)
    guard let kc = code else { return false }
    let f = flags(mods)
    let down = CGEvent(keyboardEventSource: ksrc(), virtualKey: kc, keyDown: true)
    let up = CGEvent(keyboardEventSource: ksrc(), virtualKey: kc, keyDown: false)
    down?.flags = f; up?.flags = f
    // Post each modifier as a real key press+release around the main key — some apps
    // (Chromium) ignore synthetic events that only carry flags without modifier press.
    let modCodes: [UInt16] = mods.map { m in
        switch m {
        case "cmd", "command": return UInt16(55)   // kVK_Command
        case "ctrl", "control": return UInt16(59)  // kVK_Control
        case "alt", "opt", "option": return UInt16(58) // kVK_Option
        case "shift": return UInt16(56)            // kVK_Shift
        case "fn": return UInt16(63)               // kVK_Function
        default: return 0
        }
    }.filter { $0 != 0 }
    func post(_ e: CGEvent?) {
        if hid { e?.post(tap: .cghidEventTap) } else { e?.postToPid(pid) }
    }
    if hid {
        frontWarnStore = ""
        frontGuard(pid)
    }
    var modDowns: [CGEvent] = []
    var modUps: [CGEvent] = []
    for mc in modCodes {
        let md = CGEvent(keyboardEventSource: ksrc(), virtualKey: mc, keyDown: true)
        let mu = CGEvent(keyboardEventSource: ksrc(), virtualKey: mc, keyDown: false)
        md?.flags = f; mu?.flags = f
        modDowns.append(md!); modUps.append(mu!)
    }
    for e in modDowns { post(e); usleep(20000) }
    post(down); usleep(15000); post(up); usleep(15000)
    for e in modUps.reversed() { post(e); usleep(20000) }
    _ = f
    return true
}

func postType(_ pid: pid_t, _ text: String, hid: Bool = false) -> Bool {
    if hid {
        frontWarnStore = ""
        frontGuard(pid)
    }
    let down = CGEvent(keyboardEventSource: ksrc(), virtualKey: 0, keyDown: true)
    down?.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16))
    let up = CGEvent(keyboardEventSource: ksrc(), virtualKey: 0, keyDown: false)
    up?.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16))
    if hid {
        down?.post(tap: .cghidEventTap); usleep(10000); up?.post(tap: .cghidEventTap)
    } else {
        down?.postToPid(pid); usleep(10000); up?.postToPid(pid)
    }
    return true
}

// ── focused element summary (for verification) ────────────────────────────────


func axPoint(_ el: AXUIElement) -> CGPoint? {
    var v: CFTypeRef? = nil
    AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &v)
    guard let av = v, CFGetTypeID(av) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    AXValueGetValue(av as! AXValue, .cgPoint, &p)
    return p
}
func axSize(_ el: AXUIElement) -> CGSize? {
    var v: CFTypeRef? = nil
    AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &v)
    guard let av = v, CFGetTypeID(av) == AXValueGetTypeID() else { return nil }
    var sz = CGSize.zero
    AXValueGetValue(av as! AXValue, .cgSize, &sz)
    return sz
}
func axFrame(_ el: AXUIElement) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
    guard let p = axPoint(el), let s = axSize(el) else { return nil }
    return (p.x, p.y, s.width, s.height)
}
func activateApp(_ pid: pid_t, _ app: AXUIElement) {
    if let na = NSRunningApplication(processIdentifier: pid) {
        _ = na.activate(options: [.activateIgnoringOtherApps])
    }
    var v: CFTypeRef? = nil
    AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &v)
    if let w = v, CFGetTypeID(w) == AXUIElementGetTypeID() {
        AXUIElementPerformAction(w as! AXUIElement, kAXRaiseAction as CFString)
    }
    usleep(180000)
}
func postClick(_ pid: pid_t, _ x: CGFloat, _ y: CGFloat, hid: Bool = false) {
    let src = CGEventSource(stateID: .hidSystemState)
    let tap: CGEventTapLocation = hid ? .cghidEventTap : .cghidEventTap
    // HID-level events go to whatever window is frontmost — verify we're about to hit the right app
    var frontWarn = ""
    if hid {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if front != pid {
            activateApp(pid, AXUIElementCreateApplication(pid))
            usleep(500000)
            let front2 = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if front2 != pid {
                frontWarn = " WARN_FRONT pid=\(front2 ?? -1) '\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")' — click may land elsewhere!"
            }
        }
    }
    frontWarnStore = frontWarn
    func fire(_ type: CGEventType, _ delay: useconds_t) {
        let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
        if hid { e?.post(tap: tap) } else { e?.postToPid(pid) }
        usleep(delay)
    }
    fire(.mouseMoved, 40000)
    fire(.leftMouseDown, 60000)
    fire(.leftMouseUp, 120000)
}

func postRightClick(_ pid: pid_t, _ x: CGFloat, _ y: CGFloat) {
    let src = CGEventSource(stateID: .hidSystemState)
    func fire(_ type: CGEventType, _ delay: useconds_t) {
        let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .right)
        e?.post(tap: .cghidEventTap)
        usleep(delay)
    }
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    if front != pid {
        activateApp(pid, AXUIElementCreateApplication(pid))
        usleep(500000)
    }
    fire(.mouseMoved, 40000)
    fire(.rightMouseDown, 80000)
    fire(.rightMouseUp, 150000)
}
var frontWarnStore = ""

func focusedSummary(_ app: AXUIElement) -> String {
    guard let f = attr(app, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() else { return "none" }
    let el = f as! AXUIElement
    let (role, label) = ident(el)
    let v = esc(strAttr(el, kAXValueAttribute) ?? "", 40)
    return "\(role)\(label.isEmpty ? "" : " «\(esc(label, 30))»")\(v.isEmpty ? "" : " v=\(v)")"
}

// ── menu navigation ───────────────────────────────────────────────────────────

func pressMenu(_ app: AXUIElement, _ titles: [String]) -> String {
    guard let menubar = attr(app, kAXMenuBarAttribute) else { return "ERR no menubar" }
    guard CFGetTypeID(menubar) == AXUIElementGetTypeID() else { return "ERR no menubar" }
    let mb = menubar as! AXUIElement
    var cur = mb
    for (i, want) in titles.enumerated() {
        let items = kids(cur)
        guard let hit = items.first(where: { (strAttr($0, kAXTitleAttribute) ?? "").localizedCaseInsensitiveContains(want) }) else {
            let avail = items.compactMap { strAttr($0, kAXTitleAttribute) }.prefix(12).joined(separator: " / ")
            return "ERR menu item «\(want)» not found (available: \(avail))"
        }
        if i == titles.count - 1 {
            let r = AXUIElementPerformAction(hit, kAXPressAction as CFString)
            return r == .success ? "OK" : "ERR press \(r.rawValue)"
        }
        // open submenu: press then read its menu (retry — menu tracking is async)
        AXUIElementPerformAction(hit, kAXPressAction as CFString)
        var menu: CFTypeRef? = nil
        for _ in 0..<5 {
            usleep(150000)
            menu = attr(hit, AXAttrMenu)
            if menu == nil {
                // some apps expose the open menu as a child element, not via AXMenu
                if let m = kids(hit).first(where: { roleOf($0) == "AXMenu" }) { menu = m }
            }
            if let m = menu, CFGetTypeID(m) == AXUIElementGetTypeID() { break }
            menu = nil
        }
        // Fallback: if submenu never opens via AX, use the item's own keyboard shortcut
        guard let m = menu, CFGetTypeID(m) == AXUIElementGetTypeID() else {
            if let key = strAttr(hit, "AXMenuItemCmdChar"), !key.isEmpty {
                return "SHORTCUT:\(key):\(strAttr(hit, "AXMenuItemCmdModifiers") ?? "0")"
            }
            return "ERR submenu «\(want)»"
        }
        cur = m as! AXUIElement
    }
    return "ERR empty path"
}

// ── axact ─────────────────────────────────────────────────────────────────────

struct ActError: Error { let msg: String }

func axact(args: [String: String]) {
    guard let pid = Int32(args["pid"] ?? "") else { print("ERR bad pid"); exit(2) }
    guard let json = args["json"], let data = json.data(using: .utf8) else { print("ERR need --json"); exit(2) }
    guard let actions = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
        print("ERR actions must be a JSON array of objects"); exit(2)
    }
    let app = appElement(pid)
    let winBefore = windowSnapshot()
    let focusBefore = focusedSummary(app)
    var log: [String] = []
    var confirmed = 0, unverified = 0, noop = 0, errors = 0
    let abortOnError = (args["abort_on_error"] ?? "1") == "1"   // default ON
    let abortOnUnverified = (args["abort_on_unverified"] ?? "") == "1"
    var abortedAt = -1

    for (i, a) in actions.enumerated() {
        let op = a["op"] as? String ?? ""
        do { let line = try perform(app, pid, op, a); log.append(line)
            if line.hasPrefix("OK confirmed") { confirmed += 1 }
            else if line.hasPrefix("OK unverified") || line.hasPrefix("OK delivered") || line.hasPrefix("OK unverifiable") { unverified += 1 }
            else if line.hasPrefix("OK suspected_noop") { noop += 1 }
        } catch let e as ActError {
            errors += 1
            log.append("ERR [\(i)] \(op): \(e.msg)")
        } catch { errors += 1; log.append("ERR [\(i)] \(op): \(error)") }
        if abortOnError && (noop > 0 || errors > 0) { abortedAt = i; break }
        if abortOnUnverified && unverified > 0 { abortedAt = i; break }
    }

    let winAfter = windowSnapshot()
    let focusAfter = focusedSummary(app)
    print(log.joined(separator: "\n"))
    if abortedAt >= 0 {
        print("ABORTED at action[\(abortedAt)] op=\(actions[abortedAt]["op"] as? String ?? "?") — remaining \(actions.count - abortedAt - 1) skipped")
    }
    print("SUMMARY confirmed=\(confirmed) unverified=\(unverified) suspected_noop=\(noop) errors=\(errors)")
    if focusBefore != focusAfter { print("FOCUS \(focusBefore) → \(focusAfter)") } else { print("FOCUS \(focusAfter)") }
    print(winDiff(winBefore, winAfter))
}

func perform(_ app: AXUIElement, _ pid: pid_t, _ op: String, _ a: [String: Any]) throws -> String {
    let idx = (a["i"] as? Int).map { "[\($0)] " } ?? ""
    switch op {
    case "press":
        let el = try resolveTarget(a, app)
        let actions = (attr(el, AXAttrActions) as? [String]) ?? []
        var act: String? = nil
        if actions.contains("AXPress") { act = kAXPressAction as String }
        else if actions.contains("AXConfirm") { act = kAXConfirmAction as String? ?? "AXConfirm" }
        else if actions.contains("AXPick") { act = "AXPick" }
        let (role, label) = ident(el)
        let stateBefore = strAttr(el, kAXValueAttribute) ?? ""
        // Fallback 1: checkbox/radio toggle via value set (many expose empty AXActions but settable value)
        if act == nil && (role == "AXCheckBox" || role == "AXRadioButton") {
            let isOn: Bool = (stateBefore == "1" || stateBefore == "true" || stateBefore.lowercased() == "yes")
            let n = NSNumber(value: isOn ? 0 : 1)
            let r = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, n)
            usleep(150000)
            let after = strAttr(el, kAXValueAttribute) ?? ""
            if r == .success && after != stateBefore {
                return "OK confirmed \(idx)press \(role) «\(esc(label, 30))» via value toggle → \(after)"
            }
            // some checkboxes ignore value set; fall through to AXPress attempt
            let r2 = AXUIElementPerformAction(el, kAXPressAction as CFString)
            if r2 == .success {
                usleep(250000)
                let after2 = strAttr(el, kAXValueAttribute) ?? ""
                if after2 != stateBefore { return "OK confirmed \(idx)press \(role) «\(esc(label, 30))» via AXPress (value → \(after2))" }
            }
            // Fallback 3: synthesized mouse click at element center (postToPid, no cursor hijack)
            if let f = axFrame(el) {
                let cx = f.0 + f.2 / 2, cy = f.1 + f.3 / 2
                if (a["activate"] as? Int) != 0 { activateApp(pid, app) }
                let web = underWebArea(el)
                postClick(pid, cx, cy, hid: web)
                let after3 = strAttr(el, kAXValueAttribute) ?? ""
                if after3 != stateBefore { return "OK confirmed \(idx)press \(role) «\(esc(label, 30))» via click@(\(Int(cx)),\(Int(cy))) (value → \(after3))" }
                if web && isFocused(el) {
                    return "OK unverified \(idx)press \(role) «\(esc(label, 30))» — web: hid-click landed (focus moved) but no value change; verify via read/screenshot"
                }
                if winSnapshotChanged() { return "OK confirmed \(idx)press \(role) «\(esc(label, 30))» via click (window changed)" }
                return "OK suspected_noop \(idx)press \(role) «\(esc(label, 30))» — click@(\(Int(cx)),\(Int(cy))) done, value still «\(esc(after3, 30))»"
            }
            throw ActError(msg: "press failed: value-set code=\(r.rawValue), AXPress code=\(r2.rawValue), no frame")
        }
        // Fallback 2 / normal path: perform AXPress even if not advertised (Chromium often supports it silently)
        guard let actName = act ?? "AXPress" as String? else { throw ActError(msg: "unreachable") }
        let r = AXUIElementPerformAction(el, actName as CFString)
        guard r == .success else { throw ActError(msg: "AX action \(actName) failed code=\(r.rawValue) (advertised: \(actions.joined(separator: ",")))") }
        usleep(250000)
        let stateAfter = strAttr(el, kAXValueAttribute) ?? ""
        let focusNow = focusedSummary(app)
        if stateAfter != stateBefore { return "OK confirmed \(idx)press \(role) «\(esc(label, 30))» (value changed)" }
        if winSnapshotChanged() { return "OK confirmed \(idx)press \(role) «\(esc(label, 30))» (window changed)" }
        if underWebArea(el) {
            // postToPid clicks don't reach Chromium renderers — degrade to HID-level click (brief real-cursor hijack)
            if let f = axFrame(el) {
                let cx = f.0 + f.2 / 2, cy = f.1 + f.3 / 2
                if (a["activate"] as? Int) != 0 { activateApp(pid, app) }
                postClick(pid, cx, cy, hid: true)
                usleep(250000)
                let v2 = strAttr(el, kAXValueAttribute) ?? ""
                if v2 != stateBefore { return "OK confirmed \(idx)press \(role) «\(esc(label, 30))» via hid-click@(\(Int(cx)),\(Int(cy))) (value → \(esc(v2, 20)))\(frontWarnStore)" }
                let hint = isFocused(el) ? "click landed, effect unproven; verify via read/screenshot" : "no observable proof; verify via read/screenshot"
                return "OK unverified \(idx)press \(role) «\(esc(label, 30))» — web: AXPress accepted, hid-click@(\(Int(cx)),\(Int(cy))) sent; \(hint)\(frontWarnStore)"
            }
            let hint = isFocused(el) ? "only focus moved (renderer AX may be partial; verify via read/screenshot, or relaunch with --force-renderer-accessibility, or use click{x,y})" : "no observable proof"
            return "OK unverified \(idx)press \(role) «\(esc(label, 30))» — web element: \(hint)"
        }
        if isFocused(el) { return "OK confirmed \(idx)press \(role) «\(esc(label, 30))» (focused)" }
        return "OK suspected_noop \(idx)press \(role) «\(esc(label, 30))» — no observable change; focused=\(focusNow)"
    case "set":
        let value = try reqStr(a, "value")
        let el = try resolveTarget(a, app)
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
        let (role, label) = ident(el)
        if settable.boolValue {
            let r = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFTypeRef)
            guard r == .success else { throw ActError(msg: "set failed code=\(r.rawValue)") }
            let back = strAttr(el, kAXValueAttribute) ?? ""
            usleep(120000)
            let back2 = strAttr(el, kAXValueAttribute) ?? ""
            if back2 == value || back == value { return "OK confirmed \(idx)set \(role) «\(esc(label, 30))» = \(esc(value, 40))" }
            return "OK suspected_noop \(idx)set \(role) — readback «\(esc(back2, 40))» ≠ input"
        } else {
            // fallback: focus + synthesized typing
            AXUIElementPerformAction(el, kAXRaiseAction as CFString)
            usleep(100000)
            AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue as CFTypeRef)
            usleep(100000)
            _ = postType(pid, value)
            usleep(150000)
            let back = strAttr(el, kAXValueAttribute) ?? ""
            if back.contains(value) { return "OK confirmed \(idx)set \(role) via typing = \(esc(value, 40))" }
            return "OK suspected_noop \(idx)set via typing — readback «\(esc(back, 40))»"
        }
    case "focus":
        let el = try resolveTarget(a, app)
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        let r = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue as CFTypeRef)
        usleep(100000)
        return isFocused(el) ? "OK confirmed \(idx)focus \(roleOf(el))" : (r == .success ? "OK suspected_noop \(idx)focus \(roleOf(el))" : "ERR focus code=\(r.rawValue)")
    case "key":
        let spec = try reqStr(a, "key")
        let hid = (a["hid"] as? Int) == 1
        guard postKey(pid, spec, hid: hid) else { throw ActError(msg: "unknown key «\(spec)»") }
        usleep(200000)
        return "OK delivered \(idx)key\(hid ? "-hid" : "") \(spec) focused=\(focusedSummary(app))\(frontWarnStore)"
    case "type":
        let text = try reqStr(a, "text")
        let hid = (a["hid"] as? Int) == 1
        if hid {
            frontWarnStore = ""
            frontGuard(pid)
        }
        // Prefer the focused editable element's AXValue set (verifiable, instant, unicode-safe).
        if let f = attr(app, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() {
            let el = f as! AXUIElement
            var settable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
            if settable.boolValue {
                let cur = strAttr(el, kAXValueAttribute) ?? ""
                let merged = hid ? text : cur + text   // hid implies fresh focus (e.g. cmd+a / cmd+l): replace, don't append
                let r = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, merged as CFTypeRef)
                if r == .success {
                    usleep(120000)
                    let back = strAttr(el, kAXValueAttribute) ?? ""
                    if back.contains(text) { return "OK confirmed \(idx)type (\(text.count) chars, via AXValue \(hid ? "replace" : "append"))" }
                }
            }
        }
        guard postType(pid, text, hid: (a["hid"] as? Int) == 1) else { throw ActError(msg: "typing failed") }
        usleep(150000)
        return "OK delivered \(idx)type (\(text.count) chars, via CGEvent)\(frontWarnStore)"
    case "menu":
        let path: [String]
        if let p = a["path"] as? [String] { path = p }
        else { path = try reqStr(a, "path").split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) } }
        let r = pressMenu(app, path)
        usleep(250000)
        return r == "OK" ? "OK confirmed \(idx)menu \(path.joined(separator: ">"))" : "\(r) [\(idx)menu \(path.joined(separator: ">"))]"
    case "select":
        let el = try resolveTarget(a, app)
        let r = AXUIElementSetAttributeValue(el, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        usleep(100000)
        let sel = attr(el, kAXSelectedAttribute)
        let selStr = sel.map { "\($0)" } ?? "?"
        return r == .success ? "OK \(selStr == "1" || selStr == "kCFBooleanTrue" ? "confirmed" : "suspected_noop") \(idx)select \(roleOf(el))" : "ERR select code=\(r.rawValue)"
    case "frame":
        let el = try resolveTarget(a, app)
        let (role, label) = ident(el)
        guard let f = axFrame(el) else { throw ActError(msg: "no frame for \(role) «\(esc(label, 30))»") }
        return "OK frame \(idx)\(role) «\(esc(label, 30))» x=\(Int(f.0)) y=\(Int(f.1)) w=\(Int(f.2)) h=\(Int(f.3))"
    case "click":
        var cx: CGFloat = 0, cy: CGFloat = 0
        var what: String
        if let kw = a["ocr"] as? String {
            // OCR-targeted click: engine finds the text and clicks its center — no vision loop needed
            let hits = ocrMatches(pid: pid, winIdx: a["win"] as? Int, filter: kw)
            guard let h = hits.min(by: { $0.text.count < $1.text.count }) else {
                throw ActError(msg: "OCR MISS «\(kw)»: no text match in window (try op ocr to list hits)")
            }
            cx = h.cx; cy = h.cy
            what = "ocr «\(kw)»→«\(esc(h.text, 24))»@(\(Int(cx)),\(Int(cy)))"
        } else if let x = a["x"] as? Int, let y = a["y"] as? Int {
            cx = CGFloat(x); cy = CGFloat(y)
            what = "@(\(x),\(y))"
        } else {
            let el = try resolveTarget(a, app)
            guard let f = axFrame(el) else { throw ActError(msg: "no frame for target") }
            cx = f.0 + f.2 / 2; cy = f.1 + f.3 / 2
            let (r2, l2) = ident(el)
            what = "\(r2) «\(esc(l2, 20))»@(\(Int(cx)),\(Int(cy)))"
        }
        if (a["activate"] as? Int) != 0 { activateApp(pid, app) }
        let hid = (a["hid"] as? Int) == 1
        postClick(pid, cx, cy, hid: hid)
        // optional inline verification: {"verify":{"path":"…:AXTextField","contains":"实施"}}
        // or {"verify":{"text":"实施项目"}} — element value must contain `contains` (or be non-empty without it)
        if let vf = a["verify"] as? [String: Any] {
            var target: [String: Any] = [:]
            for (k, v) in vf where k != "contains" { target[k] = v }
            usleep(useconds_t(((vf["wait"] as? Int) ?? 800) * 1000))
            let vel = try resolveTarget(target, app)
            let v = strAttr(vel, kAXValueAttribute) ?? ""
            let want = vf["contains"] as? String
            if let w = want {
                guard v.localizedCaseInsensitiveContains(w) else {
                    throw ActError(msg: "VERIFY FAIL click\(hid ? "-hid" : "") \(what): got v=«\(esc(v, 60))» expected contains «\(w)» — abort to prevent chained wrong clicks")
                }
                return "OK confirmed \(idx)click\(hid ? "-hid" : "") \(what) verified v contains «\(w)»"
            } else {
                guard !v.isEmpty else {
                    throw ActError(msg: "VERIFY FAIL click\(hid ? "-hid" : "") \(what): field still empty — abort")
                }
                return "OK confirmed \(idx)click\(hid ? "-hid" : "") \(what) verified v=«\(esc(v, 60))»"
            }
        }
        let focusNow = focusedSummary(app)
        return "OK unverified \(idx)click\(hid ? "-hid" : "") \(what) focused=\(focusNow)\(frontWarnStore)"
    case "rightclick":
        var rx: CGFloat = 0, ry: CGFloat = 0
        if let x = a["x"] as? Int, let y = a["y"] as? Int {
            rx = CGFloat(x); ry = CGFloat(y)
        } else {
            let el = try resolveTarget(a, app)
            guard let f = axFrame(el) else { throw ActError(msg: "no frame for target") }
            rx = f.0 + f.2 / 2; ry = f.1 + f.3 / 2
        }
        if (a["activate"] as? Int) != 0 { activateApp(pid, app) }
        postRightClick(pid, rx, ry)
        usleep(600000)
        return "OK rightclick @(\(Int(rx)),\(Int(ry))) — context menu should be open"
    case "read":
        let el = try resolveTarget(a, app)
        let (role, label) = ident(el)
        let v = strAttr(el, kAXValueAttribute) ?? ""
        return "OK read \(idx)\(role) «\(esc(label, 30))» v=\(esc(v, 120)) focused=\(isFocused(el) ? "1" : "0")"
    case "wait":
        let ms = (a["ms"] as? Int) ?? 500
        usleep(useconds_t(ms * 1000))
        return "OK waited \(idx)\(ms)ms"
    case "ocr":
        let hits = ocrMatches(pid: pid, winIdx: a["win"] as? Int, filter: a["text"] as? String)
        if (a["assert_absent"] as? Int ?? 0) == 1 {
            // verifier polarity for "did the dialog close": absence is SUCCESS here — but only if the window is visible
            guard pickWindow(Int(pid)) != nil else { throw ActError(msg: "window not on screen — cannot assert absence") }
            guard hits.isEmpty else { throw ActError(msg: "ASSERT ABSENT FAIL «\(a["text"] ?? "")» still on screen (\(hits.count) hit(s))") }
            return "OK \(idx)absent «\(a["text"] ?? "")» — confirmed not on screen"
        }
        guard !hits.isEmpty else { throw ActError(msg: "no OCR text found (window hidden/minimized?)") }
        var lines: [String] = []
        for h in hits.prefix(25) { lines.append("«\(esc(h.text, 40))»@(\(Int(h.cx)),\(Int(h.cy)))") }
        return "OK \(idx)ocr hits=\(min(hits.count, 25)) — " + lines.joined(separator: " ")
    case "scroll":
        guard let dy = a["dy"] as? Int else { throw ActError(msg: "need dy") }
        let dx = (a["dx"] as? Int) ?? 0
        let ev = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(-dy), wheel2: 0, wheel3: 0)
        ev?.postToPid(pid)
        usleep(200000)
        return "OK delivered \(idx)scroll dy=\(dy) dx=\(dx)"
    default:
        throw ActError(msg: "unknown op «\(op)» (press/set/focus/key/type/menu/select/read/wait/scroll/ocr/click-with-ocr)")
    }
}

func reqStr(_ a: [String: Any], _ k: String) throws -> String {
    guard let v = a[k] as? String, !v.isEmpty else { throw ActError(msg: "missing «\(k)»") }
    return v
}

func axRoot(_ app: AXUIElement, _ winIdx: Int) -> AXUIElement { axRoot(app, winIdx: winIdx) }

/// App windows with a nudge: some apps (e.g. TextEdit living on a background Space) report an
/// EMPTY AXWindows list until activate() has been attempted once. Retry after a light touch.
func appWindows(_ app: AXUIElement) -> [AXUIElement] {
    func read() -> [AXUIElement]? {
        guard let wins = attr(app, kAXWindowsAttribute) as? [AnyObject] else { return nil }
        let els = wins.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }.map { $0 as! AXUIElement }
        return els.isEmpty ? nil : els
    }
    if let els = read() { return els }
    var pid: pid_t = 0
    AXUIElementGetPid(app, &pid)
    if let na = NSRunningApplication(processIdentifier: pid) { _ = na.activate(options: []) }
    usleep(300000)
    return read() ?? []
}

func axWindows(_ app: AXUIElement) -> [AXUIElement] {
    let els = appWindows(app)
    return els.isEmpty ? [app] : els
}

// ── window snapshot + diff ────────────────────────────────────────────────────

func windowSnapshot() -> [Int: String] {
    var m: [Int: String] = [:]
    if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
        for w in list {
            let layer = w[kCGWindowLayer as String] as? Int ?? 99
            guard layer == 0 else { continue }
            let wid = w[kCGWindowNumber as String] as? Int ?? 0
            let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
            let app = w[kCGWindowOwnerName as String] as? String ?? "?"
            let title = w[kCGWindowName as String] as? String ?? ""
            m[wid] = "pid\(pid) \(app) «\(esc(title, 36))»"
        }
    }
    return m.mapValues { $0 }
}

func winSnapshotChanged() -> Bool { false } // placeholder: per-action window check disabled; batch-level diff covers it

func winDiff(_ before: [Int: String], _ after: [Int: String]) -> String {
    var msgs: [String] = []
    for (id, s) in after where before[id] == nil { msgs.append("+ \(s)") }
    for (id, s) in before where after[id] == nil { msgs.append("- \(s) (was \(s))") }
    for (id, s) in after where before[id] != nil && before[id] != s { msgs.append("~ \(before[id]!) → \(s)") }
    return msgs.isEmpty ? "WINDOWS unchanged (\(after.count))" : "WINDOWS \(msgs.joined(separator: "; "))"
}

// ── shot ──────────────────────────────────────────────────────────────────────

func pickWindow(_ pid: Int) -> (Int, CGRect)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
    var best: (Int, CGRect) = (0, .zero)
    for w in list {
        let layer = w[kCGWindowLayer as String] as? Int ?? 99
        guard layer == 0, w[kCGWindowOwnerPID as String] as? Int == pid else { continue }
        guard let b = w[kCGWindowBounds as String] as? [String: Any],
              let wd = b["Width"] as? Double, let ht = b["Height"] as? Double else { continue }
        if wd * ht > best.1.width * best.1.height {
            let x = b["X"] as? Double ?? 0, y = b["Y"] as? Double ?? 0
            best = (w[kCGWindowNumber as String] as? Int ?? 0, CGRect(x: x, y: y, width: wd, height: ht))
        }
    }
    return best.0 != 0 ? best : nil
}

func captureWindowPng(_ winId: Int, to path: String) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-o", "-x", "-l", String(winId), path]
    try? task.run()
    task.waitUntilExit()
    return task.terminationStatus == 0
}

// One OCR text hit in global screen coordinates (points).
struct OcrHit {
    let text: String
    let cx: CGFloat, cy: CGFloat   // global center (points)
    let w: CGFloat, h: CGFloat     // size (points)
    let conf: Float
}

/// OCR a pid's window via Vision; returns hits sorted top-left → bottom-right.
/// boundingBox is normalized with origin at bottom-left; window bounds are global points.
func ocrMatches(pid: Int32, winIdx: Int?, filter: String?) -> [OcrHit] {
    guard let picked = pickWindow(Int(pid)) else { return [] }
    let (winId, bounds) = picked
    let tmp = "/tmp/axc-ocr-\(pid)-\(Int(ProcessInfo.processInfo.systemUptime)).png"
    guard captureWindowPng(winId, to: tmp), let img = NSImage(contentsOfFile: tmp), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        try? FileManager.default.removeItem(atPath: tmp)
        return []
    }
    try? FileManager.default.removeItem(atPath: tmp)
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false
    req.recognitionLanguages = ["zh-Hans", "en-US"]
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    guard (try? handler.perform([req])) != nil else { return [] }
    var hits: [OcrHit] = []
    for obs in req.results ?? [] {
        guard let cand = obs.topCandidates(1).first else { continue }
        let box = obs.boundingBox // normalized, origin bottom-left
        let topFrac = 1.0 - box.origin.y - box.height
        let cx = bounds.origin.x + (box.origin.x + box.width / 2) * bounds.width
        let cy = bounds.origin.y + (topFrac + box.height / 2) * bounds.height
        let text = cand.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        if let f = filter, !text.localizedCaseInsensitiveContains(f) { continue }
        hits.append(OcrHit(text: text,
                           cx: cx, cy: cy,
                           w: box.width * bounds.width, h: box.height * bounds.height,
                           conf: cand.confidence))
    }
    hits.sort { $0.cy != $1.cy ? $0.cy < $1.cy : $0.cx < $1.cx }
    return hits
}

func ocrCmd(args: [String: String]) {
    guard let pid = Int32(args["pid"] ?? "") else { print("ERR bad pid"); exit(2) }
    let hits = ocrMatches(pid: pid, winIdx: nil, filter: args["text"])
    if (args["assert-absent"] ?? "0") == "1" {
        // absence only means "gone" if the window is actually visible — else it's just blindness
        guard pickWindow(Int(pid)) != nil else { print("ERR window not on screen — cannot assert absence"); exit(1) }
        guard hits.isEmpty else { print("ERR «\(args["text"] ?? "")» still on screen (\(hits.count) hit(s))"); exit(1) }
        print("OK absent «\(args["text"] ?? "")»")
        return
    }
    if hits.isEmpty { print("ERR no OCR text found (window hidden/minimized?)"); exit(1) }
    for h in hits.prefix(60) {
        print("HIT «\(h.text)» center=(\(Int(h.cx)),\(Int(h.cy))) size=(\(Int(h.w))×\(Int(h.h))) conf=\(String(format: "%.2f", h.conf))")
    }
    print("SUMMARY hits=\(min(hits.count, 60)) win=\(pickWindow(Int(pid))?.0 ?? 0)")
}

func shot(args: [String: String]) {
    guard let pid = Int(args["pid"] ?? "") else { print("ERR bad pid"); exit(2) }
    guard let (winId, bounds) = pickWindow(pid) else { print("ERR no visible window for pid \(pid)"); exit(1) }
    let maxEdge = Int(args["max"] ?? "1280") ?? 1280
    let tmpPng = "/tmp/axc-shot-\(pid)-\(Int(ProcessInfo.processInfo.systemUptime)).png"
    guard captureWindowPng(winId, to: tmpPng) else { print("ERR screencapture failed"); exit(1) }
    let out = args["out"] ?? tmpPng.replacingOccurrences(of: ".png", with: ".jpg")
    let conv = Process()
    conv.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    conv.arguments = ["-s", "format", "jpeg", "-s", "formatOptions", "80", "--resampleHeightWidthMax", String(maxEdge), tmpPng, "--out", out]
    try? conv.run()
    conv.waitUntilExit()
    try? FileManager.default.removeItem(atPath: tmpPng)
    guard conv.terminationStatus == 0 else { print("ERR sips exit \(conv.terminationStatus)"); exit(1) }
    let attrs = try? FileManager.default.attributesOfItem(atPath: out)
    let size = (attrs?[.size] as? Int) ?? 0
    print("OK \(out) \(size / 1024)KB win=\(winId) area=\(Int(bounds.width * bounds.height)) jpeg q80 max=\(maxEdge)")
}

// ── relaunch ──────────────────────────────────────────────────────────────────

func relaunch(args: [String: String]) {
    guard let name = args["app"] else { print("ERR need --app"); exit(2) }
    let extraArgs = (args["args"] ?? "").split(separator: " ").map(String.init)
    // find existing pid via NSWorkspace
    let ws = NSWorkspace.shared
    let running = ws.runningApplications.first { $0.localizedName == name || $0.bundleURL?.lastPathComponent == "\(name).app" }
    if let r = running {
        // zombie guard: NSWorkspace keeps stale entries for exited apps — probe the pid first
        if kill(r.processIdentifier, 0) == 0 {
            r.terminate()
            var gone = false
            for _ in 0..<32 { if kill(r.processIdentifier, 0) != 0 { gone = true; break }; usleep(250000) }
            if !gone {
                // SIGTERM ignored — force kill; stale entries never flip isTerminated, so probe the pid
                kill(r.processIdentifier, SIGKILL)
                for _ in 0..<12 { if kill(r.processIdentifier, 0) != 0 { gone = true; break }; usleep(250000) }
                guard gone else { print("ERR \(name) pid=\(r.processIdentifier) refuses to die (SIGTERM+SIGKILL both failed) — not relaunching"); exit(1) }
            }
        } // else: stale entry for an exited app — nothing to kill, just launch
    }
    usleep(500000)
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.arguments = extraArgs
    cfg.activates = false
    let url = running?.bundleURL ?? (urlForApp(name) ?? URL(fileURLWithPath: "/Applications/\(name).app"))
    ws.openApplication(at: url, configuration: cfg) { _, err in
        if let err = err { print("ERR open: \(err.localizedDescription)") }
    }
    // wait for pid — first launch after a kill can register slowly with NSWorkspace
    for _ in 0..<60 {
        usleep(250000)
        if let r = ws.runningApplications.first(where: { ($0.bundleURL?.path == url.path || $0.localizedName == name) && $0.processIdentifier > 0 && !$0.isTerminated }) {
            print("OK relaunched \(name) pid=\(r.processIdentifier) args=\(extraArgs.joined(separator: " "))")
            return
        }
    }
    // NSWorkspace sometimes never lists it — fall back to pgrep on the bundle executable
    let execName = (NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleExecutable"] as? String)
        ?? url.deletingPathExtension().lastPathComponent
    let pg = Process()
    pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pg.arguments = ["-x", execName]
    let pipe = Pipe()
    pg.standardOutput = pipe
    pg.standardError = FileHandle.nullDevice
    try? pg.run()
    pg.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let first = String(data: data, encoding: .utf8)?.split(separator: "\n").first
    if let pidStr = first, let newPid = Int32(pidStr.trimmingCharacters(in: .whitespaces)) {
        print("OK relaunched \(name) pid=\(newPid) (via pgrep \(execName)) args=\(extraArgs.joined(separator: " "))")
        return
    }
    print("ERR \(name) did not come up")
}

func urlForApp(_ name: String) -> URL? {
    let dirs = ["/Applications", "/System/Applications", "/Applications/Utilities"]
    for d in dirs {
        let u = URL(fileURLWithPath: "\(d)/\(name).app")
        if FileManager.default.fileExists(atPath: u.path) { return u }
    }
    return nil
}

// ── arg parse + dispatch ──────────────────────────────────────────────────────

func parseArgs(_ argv: [String]) -> (String, [String: String]) {
    guard let cmd = argv.first else { return ("", [:]) }
    var m: [String: String] = [:]
    var i = 1
    while i < argv.count {
        let t = argv[i]
        if t.hasPrefix("--") {
            let k = String(t.dropFirst(2))
            if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") { m[k] = argv[i + 1]; i += 2 }
            else { m[k] = "1"; i += 1 }
        } else { i += 1 }
    }
    return (cmd, m)
}

let (cmd, args) = parseArgs(Array(CommandLine.arguments.dropFirst()))
switch cmd {
case "winlist": winlist(args["pid"].flatMap { Int32($0) })
case "axtree": axtree(args: args)
case "axread": axread(args: args)
case "axact": axact(args: args)  // --abort_on_error 0 / --abort_on_unverified 1 pass through args
case "shot": shot(args: args)
case "ocr": ocrCmd(args: args)
case "relaunch": relaunch(args: args)
default:
    print("axc — AX-first Mac computer-use engine")
    print("usage: axc <winlist|axtree|axread|axact|shot|ocr|relaunch> [--pid N] ...")
    exit(2)
}
