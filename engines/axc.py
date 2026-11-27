#!/usr/bin/env python3
# axc.py - Linux engine for ax-computer-use v2 (P1+P2)
# Contract twin of src/axc.swift (macOS) / axc.ps1 (Windows): same subcommands,
# same output grammar (OK confirmed/unverified/suspected_noop, SUMMARY, FOCUS,
# MAP for shots, HIT «...» @x,y for OCR, VERIFY FAIL / FORM_ERROR / OCR MISS).
# Stack: pyatspi (AT-SPI2) tree, XTest/xdotool HID input, scrot+convert JPEG,
# tesseract TSV OCR with coordinates. Supported subset documented in README.
import sys, os, json, time, subprocess, shutil

CACHE_FILE = os.path.expanduser("~/.ax-cu/cache.json")
FRONT_WARN = ""
ERR_PATS = ["不能", "必须", "请输入", "请选择", "错误", "超出", "失败",
            "invalid", "required", "error", "exceed", "must be"]


def parse_args(argv):
    # supports both "--key value" (how index.js invokes) and "--key=value"
    a = {}
    toks = argv[2:]
    i = 0
    while i < len(toks):
        tok = toks[i]
        if not tok.startswith("--"):
            i += 1
            continue
        if "=" in tok:
            k, v = tok[2:].split("=", 1)
            a[k] = v
        elif i + 1 < len(toks) and not toks[i + 1].startswith("--"):
            a[tok[2:]] = toks[i + 1]
            i += 1
        else:
            a[tok[2:]] = "1"
        i += 1
    return a


def front_pid():
    try:
        out = subprocess.run(["xdotool", "getactivewindow", "getwindowpid"],
                             capture_output=True, text=True, timeout=5)
        return int(out.stdout.strip() or 0)
    except Exception:
        return 0


def guard_front(pid):
    global FRONT_WARN
    if pid <= 0:
        return
    fp = front_pid()
    if fp == pid:
        return
    subprocess.run(["xdotool", "search", "--onlyvisible", "--pid", str(pid),
                    "windowactivate", "--sync"], capture_output=True, timeout=5)
    time.sleep(0.5)
    if front_pid() != pid:
        FRONT_WARN = " WARN_FRONT pid=%d (wanted %d)" % (front_pid(), pid)


def send_click(x, y):
    subprocess.run(["xdotool", "mousemove", str(x), str(y)], timeout=5)
    time.sleep(0.06)
    subprocess.run(["xdotool", "click", "1"], timeout=5)


def send_text(text):
    subprocess.run(["xdotool", "type", "--delay", "12", "--", text],
                   timeout=30)


def send_key(spec):
    parts = spec.lower().split("+")
    key = parts[-1]
    if len(parts) > 1:
        for m in parts[:-1]:
            subprocess.run(["xdotool", "keydown", m], timeout=5)
    subprocess.run(["xdotool", "key", key], timeout=5)
    for m in reversed(parts[:-1]):
        subprocess.run(["xdotool", "keyup", m], timeout=5)


# ---- AT-SPI2 tree access ----

def spi_desktop():
    import pyatspi
    return pyatspi.Registry.getDesktop(0)


def spi_walk(match, cap=4000):
    """Yield (acc, chain) for every accessible under the pid's app (or all)."""
    pid = match.get("pid")
    want = (match.get("text") or "").lower()
    role_f = (match.get("role") or "").lower()
    nth = int(match.get("nth", 0))
    hits = []
    visited = 0

    def value_of(acc):
        try:
            t = acc.queryText()
            return t.getText(0, -1) or ""
        except Exception:
            pass
        try:
            return acc.queryValue().currentValue or ""
        except Exception:
            pass
        return ""

    def rec(acc, chain, depth):
        nonlocal visited
        if visited >= cap or depth > 26 or len(hits) > nth:
            return
        try:
            name = acc.name or ""
            role = acc.getRoleName() or ""
            app_pid = acc.get_process_id() if hasattr(acc, "get_process_id") else None
        except Exception:
            return
        visited += 1
        if (pid in (None, 0) or app_pid in (None, 0) or app_pid == pid):
            ok_role = (not role_f) or (role_f in role.lower())
            ok_text = (not want) or (want in name.lower()) or (want in (value_of(acc) or "").lower())
            if ok_role and ok_text:
                hits.append((acc, chain, name, role, value_of(acc)))
                if len(hits) > nth:
                    return
        try:
            for i, k in enumerate(acc):
                rec(k, "%s%d." % (chain, i), depth + 1)
        except Exception:
            pass

    try:
        for app in spi_desktop():
            try:
                if pid and app.get_process_id() == pid:
                    for j, w in enumerate(app):
                        rec(w, "%d." % j, 0)
                elif not pid:
                    for j, w in enumerate(app):
                        rec(w, "%d." % j, 0)
            except Exception:
                continue
    except Exception as ex:
        print("ERR pyatspi walk: %s" % ex)
    return hits[nth] if len(hits) > nth else None


def center_of(acc):
    try:
        c = acc.queryComponent()
        ext = c.getExtents(0)
        return int(ext.x + ext.width / 2), int(ext.y + ext.height / 2)
    except Exception:
        return None


def spi_press(acc):
    """DoDefaultAction via AT-SPI Action interface; returns action name or None."""
    try:
        act = acc.queryAction()
        for i in range(act.nActions):
            nm = (act.getName(i) or "").lower()
            if nm in ("press", "click", "activate", "open"):
                act.doAction(i)
                return nm or "action"
        if act.nActions > 0:
            act.doAction(0)
            return act.getName(0) or "action0"
    except Exception:
        pass
    return None


def read_value(target):
    """Read a control's value for verify: {text|pid|nth|role} or {chain}."""
    if target.get("chain"):
        return None  # chain walk handled in axread only
    hit = spi_walk(target)
    if not hit:
        raise ValueError("verify target not found «%s»" % (target.get("text") or "?"))
    return hit[4] or hit[2] or ""


# ---- shot (JPEG + MAP line so click{"shot":[px,py]} maps on every desktop) ----

def cmd_shot(a):
    out = a.get("out") or "/tmp/axc-shot.jpg"
    maxl = int(a.get("max", 1280))
    tool = None
    for t, targs in (("gnome-screenshot", ["-f"]), ("scrot", ["-o"]),
                     ("import", ["-window", "root"])):
        if shutil.which(t):
            tool, args_ = t, targs
            break
    if not tool:
        print("ERR no screenshot tool (install scrot / gnome-screenshot / imagemagick)")
        return
    png = "/tmp/axc-shot.png"
    subprocess.run([tool] + args_ + [png], timeout=10)
    geom = subprocess.run(["identify", "-format", "%w %h", png],
                          capture_output=True, text=True, timeout=10)
    try:
        w, h = (int(v) for v in geom.stdout.split())
    except Exception:
        w = h = 0
    ox, oy = 0, 0
    if a.get("pid"):  # window crop for pid-scoped shots
        gr = subprocess.run(["xdotool", "search", "--onlyvisible", "--pid",
                             a["pid"], "getwindowgeometry", "--shell"],
                            capture_output=True, text=True, timeout=5)
        g = {}
        for ln in gr.stdout.split("\n"):
            if "=" in ln:
                k, v = ln.split("=", 1)
                g[k.strip()] = int(v.strip() or 0)
        if g.get("WIDTH") and g.get("HEIGHT"):
            ox, oy = g.get("X", 0), g.get("Y", 0)
            subprocess.run(["convert", png, "-crop",
                            "%dx%d+%d+%d" % (g["WIDTH"], g["HEIGHT"], ox, oy),
                            png], timeout=10)
            w, h = g["WIDTH"], g["HEIGHT"]
    scale = min(maxl / max(w, h), 1.0) if max(w, h) > maxl else 1.0
    try:
        subprocess.run(["convert", png, "-resize", "%dx%d>" % (maxl, maxl),
                        "-quality", "80", out], timeout=10, check=True)
        scale = maxl / max(w, h) if max(w, h) > maxl else 1.0
    except Exception:
        subprocess.run(["cp", png, out])
        scale = 1.0
    print("SAVED %s" % out)
    print("MAP w=%d h=%d max=%d scale=%.4f origin=%d,%d" % (w, h, maxl, scale, ox, oy))
    try:  # persist for click {"shot":[px,py]} in a later engine run
        meta = {"pid": int(a.get("pid", 0) or 0), "w": w, "h": h,
                "scale": scale, "ox": ox, "oy": oy, "out": out}
        json.dump(meta, open("/tmp/axc-lastshot-%d.json" % os.getuid(), "w"))
    except Exception:
        pass


def shot_to_screen(pid, px, py):
    """Convert shot pixel coords to screen coords via the last shot's MAP."""
    try:
        m = json.load(open("/tmp/axc-lastshot-%d.json" % os.getuid()))
    except Exception:
        raise ValueError("no recent shot (MAP) to map shot:[%s,%s] — run ax_shot first" % (px, py))
    if pid and m.get("pid") and int(m["pid"]) != pid:
        raise ValueError("last shot was pid %s, not %s" % (m.get("pid"), pid))
    return int(m["ox"] + px / m["scale"]), int(m["oy"] + py / m["scale"])


# ---- ocr (tesseract TSV with screen coordinates) ----

def ocr_hits(png):
    """Return [(text, cx, cy)] word-grouped line hits at screen resolution."""
    r = subprocess.run(["tesseract", png, "stdout", "-l", "eng+chi_sim", "tsv"],
                       capture_output=True, text=True, timeout=60)
    lines = {}
    for row in r.stdout.split("\n")[1:]:
        cols = row.split("\t")
        if len(cols) < 12 or cols[11].strip() == "":
            continue
        key = (cols[1], cols[2], cols[3], cols[4])
        l, t, w, h = (int(cols[i]) for i in (6, 7, 8, 9))
        e = lines.setdefault(key, {"txt": [], "x0": l, "y0": t, "x1": l + w, "y1": t + h})
        e["txt"].append(cols[11])
        e["x0"], e["y0"] = min(e["x0"], l), min(e["y0"], t)
        e["x1"], e["y1"] = max(e["x1"], l + w), max(e["y1"], t + h)
    return [(((" ".join(v["txt"])) if all(ord(ch) < 0x2E80 for ch in v["txt"][0]) else "".join(v["txt"])),
             (v["x0"] + v["x1"]) // 2, (v["y0"] + v["y1"]) // 2)
            for v in lines.values()]


def ocr_matches(pid, filt):
    png = "/tmp/axc-ocr.png"
    cmd_shot({"out": png, "max": "99999", "pid": pid})
    return [(t, x, y) for (t, x, y) in ocr_hits(png)
            if not filt or filt.lower() in t.lower()]


def cmd_ocr(a):
    want = (a.get("text") or "").lower()
    hits = ocr_matches(a.get("pid"), want)
    if a.get("assert_absent"):
        if not a.get("pid"):
            print("ERR cannot assert absence without --pid (window may be hidden)")
            return
        if hits:
            print("ASSERT ABSENT FAIL: found %d hits for «%s»" % (len(hits), want))
            for t, x, y in hits[:3]:
                print("  HIT «%s» @(%d,%d)" % (t[:50], x, y))
            return
        print("OK absent «%s»" % want)
        return
    if not hits:
        print("NO MATCH" if want else "EMPTY")
    for t, x, y in hits[:40]:
        print("HIT «%s» @(%d,%d)" % (t[:80], x, y))


# ---- axtree (AT-SPI2, text filter, menu pruning) ----

def cmd_axtree(a):
    try:
        import pyatspi
    except ImportError:
        print("ERR pyatspi not installed (apt install python3-pyatspi gir1.2-atspi-2.0)")
        return
    pid = int(a.get("pid", 0))
    depth_max = int(a.get("depth", 9))
    node_cap = int(a.get("max", 900))
    text_f = (a.get("text") or "").lower()
    desktop = pyatspi.Registry.getDesktop(0)
    count = 0
    searched = 0

    def dump(acc, d, chain):
        nonlocal count
        if count >= node_cap or d > depth_max:
            return
        try:
            name = acc.name or ""
            role = acc.getRoleName()
            app_pid = acc.get_process_id() if hasattr(acc, "get_process_id") else None
        except Exception:
            return
        if app_pid in (None, 0) or app_pid == pid:
            count += 1
            line = "%s%s t=%s" % (chain, role, name or "-")
            try:
                v = acc.queryText().getText(0, -1) if acc.queryText() else ""
                if v:
                    line += " v=%s" % v[:60]
            except Exception:
                pass
            if not text_f or text_f in name.lower() or text_f in line.lower():
                print(line)
            try:
                for i, k in enumerate(acc):
                    dump(k, d + 1, "%s%d." % (chain, i))
            except Exception:
                pass

    for i, app in enumerate(desktop):
        try:
            if app.get_process_id() == pid:
                searched += 1
                print("[:application] %s" % app.name)
                for j, w in enumerate(app):
                    dump(w, 0, "%d." % j)
        except Exception:
            continue
    print("NODES %d" % count)
    if text_f and count == 0:
        print("FILTER «%s» no hits (searched %d app(s) of pid %s)" % (text_f, searched, pid))


# ---- axread (chain walk: "1.0.2" = window1 -> child0 -> child2) ----

def cmd_axread(a):
    chain = a.get("path") or a.get("chain")
    if not chain:
        print("ERR axread needs --path 1.0.2")
        return
    try:
        import pyatspi
    except ImportError:
        print("ERR pyatspi not installed (apt install python3-pyatspi gir1.2-atspi-2.0)")
        return
    idx = [int(v) for v in chain.split(".")]
    wi, rest = idx[0], idx[1:]
    try:
        apps = [ap for ap in spi_desktop()
                if not a.get("pid") or ap.get_process_id() == int(a["pid"])]
        win = [w for ap in apps for w in ap][wi]
        acc = win
        for i in rest:
            acc = acc[i]
        name = acc.name or ""
        role = acc.getRoleName()
        val = ""
        try:
            val = acc.queryText().getText(0, -1) or ""
        except Exception:
            pass
        ext = acc.queryComponent().getExtents(0)
        print("role=%s t=%s v=%s frame=(%d,%d,%d,%d)" %
              (role, name or "-", val[:80], ext.x, ext.y, ext.width, ext.height))
    except Exception as ex:
        print("ERR axread: %s" % ex)


# ---- axact (batched verified actions; v2 op set) ----

def cmd_axact(a):
    global FRONT_WARN
    pid = int(a.get("pid", 0))
    acts = json.loads(a.get("json", "[]"))
    idx = c = u = n = e = 0
    abort = ""
    focus_before = front_pid()
    for act in acts:
        op = act.get("op")
        try:
            if op == "click":
                guard_front(pid)
                if act.get("shot"):
                    x, y = shot_to_screen(pid, act["shot"][0], act["shot"][1])
                    v0 = None
                elif act.get("text"):
                    hit = spi_walk({"pid": pid, "text": act["text"],
                                    "role": act.get("role"), "nth": act.get("nth", 0)})
                    if not hit:
                        raise ValueError("click: no element «%s»" % act["text"])
                    xy = center_of(hit[0])
                    if not xy:
                        raise ValueError("click: element has no position «%s»" % act["text"])
                    x, y = xy
                    v0 = hit[4]
                elif act.get("key"):
                    cc = load_cache().get(cache_key(act, pid))
                    if not cc:
                        raise ValueError("RECALL MISS key=%s" % act["key"])
                    x, y = int(cc["x"]), int(cc["y"])
                    v0 = None
                else:
                    x, y = int(act["x"]), int(act["y"])
                    v0 = None
                send_click(x, y)
                time.sleep(0.3)
                msg = "OK confirmed %dclick @(%d,%d)%s" % (idx, x, y, FRONT_WARN)
                FRONT_WARN = ""
                vf = act.get("verify")
                if vf:
                    time.sleep(int(vf.get("wait", 800)) / 1000)
                    tgt = {k: v for k, v in vf.items() if k not in ("contains", "wait")}
                    tgt.setdefault("pid", pid)
                    v = read_value(tgt)
                    want = vf.get("contains")
                    if want and want.lower() not in (v or "").lower():
                        raise ValueError("VERIFY FAIL click: got v=«%s» expected contains «%s»" % ((v or "")[:60], want))
                    if not want and not (v or "").strip():
                        raise ValueError("VERIFY FAIL click: value still empty after click")
                    msg += " verified v=«%s»" % (v or "")[:40]
                elif act.get("text"):
                    time.sleep(0.2)
                    h2 = spi_walk({"pid": pid, "text": act["text"],
                                   "role": act.get("role"), "nth": 0})
                    v1 = h2[4] if h2 else None
                    if v1 is not None and v1 == v0 and v0:
                        msg = "OK unverified %dclick @(%d,%d) value unchanged" % (idx, x, y)
                        n += 1
                        c -= 1
                        u += 1
                print(msg)
                c += 1
            elif op == "press":
                guard_front(pid)
                hit = spi_walk({"pid": pid, "text": act.get("text"),
                                "role": act.get("role"), "nth": act.get("nth", 0)})
                if not hit:
                    raise ValueError("press: no element «%s»" % (act.get("text") or "?"))
                acc, chain, name, role, v0 = hit
                acted = spi_press(acc)
                if not acted:
                    xy = center_of(acc)
                    if not xy:
                        raise ValueError("press: no action interface and no position")
                    send_click(*xy)
                    acted = "hid-click"
                time.sleep(0.4)
                v1 = ""
                try:
                    v1 = acc.queryText().getText(0, -1) or ""
                except Exception:
                    pass
                print("OK confirmed %dpress «%s» (%s) v=%s→%s%s" %
                      (idx, (name or "?")[:30], acted, (v0 or "")[:20], v1[:20], FRONT_WARN))
                FRONT_WARN = ""
                c += 1
            elif op == "set":
                hit = spi_walk({"pid": pid, "text": act.get("text"),
                                "role": act.get("role"), "nth": act.get("nth", 0)})
                val = act.get("value", "")
                if hit:
                    acc = hit[0]
                    try:
                        acc.queryText().setTextContents(val)
                    except Exception:
                        xy = center_of(acc)
                        if not xy:
                            raise ValueError("set: not editable and no position")
                        guard_front(pid)
                        send_click(*xy)
                        time.sleep(0.2)
                        subprocess.run(["xdotool", "key", "ctrl+a"], timeout=5)
                        send_text(val)
                else:
                    raise ValueError("set: no element «%s»" % (act.get("text") or "?"))
                time.sleep(0.2)
                v = ""
                try:
                    v = hit[0].queryText().getText(0, -1) or ""
                except Exception:
                    pass
                if val and val not in v:
                    raise ValueError("VERIFY FAIL set: wrote «%s» read back «%s»" % (val[:40], v[:40]))
                print("OK confirmed %dset v=«%s»" % (idx, val[:40]))
                c += 1
            elif op == "focus":
                hit = spi_walk({"pid": pid, "text": act.get("text"),
                                "role": act.get("role"), "nth": act.get("nth", 0)})
                if not hit:
                    raise ValueError("focus: no element «%s»" % (act.get("text") or "?"))
                try:
                    hit[0].queryComponent().grabFocus()
                except Exception:
                    xy = center_of(hit[0])
                    if xy:
                        send_click(*xy)
                print("OK confirmed %dfocus «%s»" % (idx, (hit[2] or "?")[:30]))
                c += 1
            elif op == "type":
                guard_front(pid)
                send_text(act["text"])
                print("OK delivered %dtype len=%d%s" % (idx, len(act["text"]), FRONT_WARN))
                FRONT_WARN = ""
                u += 1
            elif op == "key":
                guard_front(pid)
                send_key(act["spec"])
                print("OK delivered %dkey %s%s" % (idx, act["spec"], FRONT_WARN))
                FRONT_WARN = ""
                u += 1
            elif op == "wait":
                time.sleep(int(act["ms"]) / 1000)
                print("OK %dwait %s" % (idx, act["ms"]))
                u += 1
            elif op == "remember":
                if "x" not in act or "y" not in act:
                    raise ValueError("remember need x,y")
                cache_put(cache_key(act, pid), act["x"], act["y"])
                print("OK confirmed %dremember key=%s -> (%s,%s) saved" %
                      (idx, act.get("key", "?"), act["x"], act["y"]))
                c += 1
            elif op == "recall":
                cc = load_cache().get(cache_key(act, pid))
                if not cc:
                    raise ValueError("RECALL MISS key=%s — remember it first" % cache_key(act, pid))
                print("OK confirmed %drecall %s -> (%s,%s)" %
                      (idx, cache_key(act, pid), cc["x"], cc["y"]))
                c += 1
            elif op == "dropdown":
                # open -> HID-type search -> OCR locate option -> click -> verify
                if act.get("ocr"):
                    hits = ocr_matches(pid, act["ocr"])
                    if not hits:
                        raise ValueError("OCR MISS «%s»" % act["ocr"])
                    fx, fy = min(hits, key=lambda h: len(h[0]))[1:]
                elif act.get("key"):
                    cc = load_cache().get(cache_key(act, pid))
                    if not cc:
                        raise ValueError("RECALL MISS key=%s" % act["key"])
                    fx, fy = int(cc["x"]), int(cc["y"])
                else:
                    fx, fy = int(act["x"]), int(act["y"])
                guard_front(pid)
                send_click(fx, fy)
                time.sleep(int(act.get("settle", 700)) / 1000)
                search = act.get("search")
                if search:
                    send_text(search)
                    time.sleep(int(act.get("settle", 900)) / 1000)
                pick = act.get("pick")
                if not pick:
                    raise ValueError("dropdown needs pick=")
                hits = ocr_matches(pid, pick)
                if not hits:
                    raise ValueError("OCR MISS option «%s» — list may not contain it" % pick)
                t, px, py = min(hits, key=lambda h: len(h[0]))
                send_click(px, py)
                msg = "OK confirmed %ddropdown pick «%s»@(%d,%d)" % (idx, t[:30], px, py)
                vf = act.get("verify")
                if vf:
                    time.sleep(int(vf.get("wait", 800)) / 1000)
                    tgt = {k: v for k, v in vf.items() if k not in ("contains", "wait")}
                    tgt.setdefault("pid", pid)
                    v = read_value(tgt)
                    want = vf.get("contains")
                    if want and want.lower() not in (v or "").lower():
                        raise ValueError("VERIFY FAIL dropdown: got v=«%s» expected contains «%s»" % ((v or "")[:60], want))
                    msg += " verified v=«%s»" % (v or "")[:40]
                print(msg)
                c += 1
            elif op == "read_errors":
                errs = []
                for acc, chain, name, role, v in spi_walk({"pid": pid}, cap=2500):
                    if len(errs) >= 5:
                        break
                    txt = (v or name or "").strip()
                    if not txt:
                        continue
                    rl = role.lower()
                    if ("text" in rl or "alert" in rl or "label" in rl) and \
                       any(p.lower() in txt.lower() for p in ERR_PATS):
                        errs.append(txt[:60])
                if not errs:
                    print("OK %dread_errors none" % idx)
                else:
                    raise ValueError("FORM_ERROR detected: %s — fix fields before re-submitting" % " | ".join(errs))
                u += 1
            else:
                raise ValueError("unknown op '%s' (click/press/set/focus/type/key/wait/remember/recall/dropdown/read_errors)" % op)
        except Exception as ex:
            e += 1
            print("ERR [%d] %s: %s%s" % (idx, op, ex, FRONT_WARN))
            FRONT_WARN = ""
            abort = "ABORTED at action[%d] op=%s" % (idx, op)
            break
        idx += 1
    focus_after = front_pid()
    print("SUMMARY confirmed=%d unverified=%d suspected_noop=%d errors=%d%s" %
          (c, u, n, e, (" " + abort) if abort else ""))
    if focus_before != focus_after:
        print("FOCUS pid %d -> %d" % (focus_before, focus_after))


# ---- remember / recall cache (shared file with macOS/Windows engines) ----

def load_cache():
    os.makedirs(os.path.dirname(CACHE_FILE), exist_ok=True)
    try:
        return json.load(open(CACHE_FILE))
    except Exception:
        return {}


def cache_put(key, x, y):
    c = load_cache()
    c[key] = {"x": x, "y": y}
    json.dump(c, open(CACHE_FILE, "w"))


def cache_key(act, pid):
    return "%s:%s" % (act.get("app") or pid, act.get("key") or "?")


# ---- relaunch ----

def cmd_relaunch(a):
    app = a.get("app")
    args_ = a.get("args", "")
    subprocess.run(["pkill", "-f", app], capture_output=True)
    time.sleep(0.8)
    cmd = [app] + (args_.split() if args_ else [])
    subprocess.Popen(cmd, start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(24):
        time.sleep(0.25)
        r = subprocess.run(["pgrep", "-f", app], capture_output=True, text=True)
        if r.stdout.strip():
            print("OK relaunch pid=%s" % r.stdout.split()[0])
            return
    print("ERR relaunch: process not found after start")


# ---- winlist ----

def cmd_winlist(a):
    filt = a.get("pid")
    try:
        r = subprocess.run(["wmctrl", "-lp"], capture_output=True, text=True, timeout=5)
    except FileNotFoundError:
        print("ERR wmctrl not installed (apt install wmctrl)")
        return
    if r.returncode != 0:
        print("ERR wmctrl failed: %s" % r.stderr.strip()[:80])
        return
    for line in r.stdout.split("\n"):
        if not line.strip():
            continue
        parts = line.split(None, 5)
        if len(parts) < 6:
            continue
        wid, _desk, pidw, host, _geom, title = parts
        if filt and pidw != filt:
            continue
        try:
            pname = open("/proc/%s/comm" % pidw).read().strip()
        except Exception:
            pname = "?"
        print("%s pid%s %s «%s»" % (wid, pidw, pname, title))


# ---- dispatch ----

def main():
    if len(sys.argv) < 2:
        print("axc (Linux engine v2 P1+P2) — winlist|axtree|axread|axact|shot|ocr|relaunch")
        return
    sub, a = sys.argv[1], parse_args(sys.argv)
    {"winlist": cmd_winlist, "axtree": cmd_axtree, "axread": cmd_axread,
     "shot": cmd_shot, "ocr": cmd_ocr, "axact": cmd_axact,
     "relaunch": cmd_relaunch}.get(
        sub, lambda _a: print("unknown subcommand %s" % sub))(a)


if __name__ == "__main__":
    main()
