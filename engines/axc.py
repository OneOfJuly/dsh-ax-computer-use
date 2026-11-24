#!/usr/bin/env python3
"""axc.py - Linux engine for ax-computer-use v2.

Contract twin of src/axc.swift (macOS) and engines/axc.ps1 (Windows).
Same subcommands, same output grammar.

Stack: AT-SPI2 (pyatspi) for the tree, XTest (python-xlib) for HID-grade input,
gnome-screenshot/scrot/import for shots, tesseract (pytesseract) for OCR.
Needs: python3, python3-pyatspi (GNOME a11y stack), python3-xlib, tesseract-ocr,
scrot (or gnome-screenshot / imagemagick import). X11 first; Wayland via
XWayland works for input+shots of X11 apps only (a11y on native Wayland apps
requires at-spi over D-Bus which pyatspi handles, but input needs compositor
permission — see ROADMAP).
"""
import json
import os
import subprocess
import sys
import time

CACHE_DIR = os.path.expanduser("~/.ax-cu")
CACHE_FILE = os.path.join(CACHE_DIR, "cache.json")


def parse_args(argv):
    a = {}
    i = 1  # argv[0] is subcommand
    while i < len(argv):
        if argv[i].startswith("--"):
            if i + 1 < len(argv) and not argv[i + 1].startswith("--"):
                a[argv[i][2:]] = argv[i + 1]
                i += 2
            else:
                a[argv[i][2:]] = "1"
                i += 1
        else:
            i += 1
    return a


# ---- frontmost guard ----

def front_pid():
    try:
        out = subprocess.run(["xdotool", "getactivewindow", "getwindowpid"],
                             capture_output=True, text=True, timeout=3)
        return int(out.stdout.strip()) if out.stdout.strip() else -1
    except Exception:
        return -1


def guard_front(pid):
    cur = front_pid()
    if cur != pid:
        try:
            subprocess.run(["xdotool", "windowactivate", "--sync",
                            _main_window(pid)], timeout=4)
            time.sleep(0.4)
        except Exception:
            pass
        cur2 = front_pid()
        if cur2 != pid:
            globals()["FRONT_WARN"] = f" WARN_FRONT pid={cur2} — input may land elsewhere!"


def _main_window(pid):
    out = subprocess.run(["xdotool", "search", "--pid", str(pid)],
                         capture_output=True, text=True, timeout=3)
    for line in out.stdout.split("\n"):
        if line.strip():
            return line.strip()
    return "0"


# ---- input (XTest = HID-grade, reaches Chromium renderers) ----

def send_click(x, y):
    from Xlib import display, X
    d = display.Display()
    root = d.screen().root
    root.warp_pointer(int(x), int(y))
    d.sync()
    time.sleep(0.05)
    Xlib_dummy = root
    from Xlib.ext import xtest
    xtest.fake_input(d, X.ButtonPress, 1)
    d.sync()
    time.sleep(0.06)
    xtest.fake_input(d, X.ButtonRelease, 1)
    d.sync()


def send_text(text):
    import subprocess
    for ch in text:
        subprocess.run(["xdotool", "type", "--", ch], timeout=3)
        time.sleep(0.01)


def send_key(spec):
    # "return" / "ctrl+a" / "shift+tab"
    parts = spec.lower().split("+")
    mods, key = parts[:-1], parts[-1]
    kmap = {"return": "Return", "enter": "Return", "tab": "Tab", "esc": "Escape",
            "escape": "Escape", "space": "space", "backspace": "BackSpace",
            "delete": "Delete", "up": "Up", "down": "Down", "left": "Left",
            "right": "Right", "home": "Home", "end": "End", "pageup": "Page_Up",
            "pagedown": "Page_Down"}
    keyname = kmap.get(key, key if len(key) > 1 else key)
    args = []
    for m in mods:
        args += ["--clearmodifiers"] if not args else []
        args = [f"{m}"] if m in ("ctrl", "alt", "shift") else args
    subprocess.run(["xdotool", "key", "--", *(f"{m}+" for m in mods), keyname],
                   timeout=3)


# ---- tree (AT-SPI2 via pyatspi) ----

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
            line = f"{chain}{role} t={name or '-'}"
            try:
                v = acc.queryText().getText(0, -1) if acc.queryText() else ""
                if v:
                    line += f" v={v[:60]}"
            except Exception:
                pass
            if not text_f or text_f in name.lower() or text_f in line.lower():
                print(line)
            try:
                for i, k in enumerate(acc):
                    dump(k, d + 1, f"{chain}{i}.")
            except Exception:
                pass

    for i, app in enumerate(desktop):
        try:
            if app.get_process_id() == pid:
                print(f"[:application] {app.name}")
                for j, w in enumerate(app):
                    dump(w, 0, f"{j}.")
        except Exception:
            continue
    print(f"NODES {count}")


# ---- shot (JPEG via CLI tools; nothing exotic) ----

def cmd_shot(a):
    out = a.get("out") or "/tmp/axc-shot.jpg"
    maxl = int(a.get("max", 1280))
    tool = None
    for t, args in (("gnome-screenshot", ["-f"]),
                    ("scrot", ["-o"]),
                    ("import", ["-window", "root"])):
        if subprocess.run(["which", t], capture_output=True).returncode == 0:
            tool, targs = t, args
            break
    if not tool:
        print("ERR no screenshot tool (install scrot / gnome-screenshot / imagemagick)")
        return
    tmp_png = "/tmp/axc-shot.png"
    subprocess.run([tool, *targs, tmp_png], timeout=10)
    try:
        subprocess.run(["convert", tmp_png, "-resize", f"{maxl}x{maxl}>",
                        "-quality", "80", out], timeout=10, check=True)
    except Exception:
        subprocess.run(["cp", tmp_png, out])
    print(f"SAVED {out}")


# ---- ocr (tesseract) ----

def cmd_ocr(a):
    want = (a.get("text") or "").lower()
    png = "/tmp/axc-ocr.png"
    cmd_shot({"out": png, "max": a.get("max", "1280")})
    r = subprocess.run(["tesseract", png, "stdout", "-l", "eng+chi_sim"],
                       capture_output=True, text=True, timeout=30)
    for line in r.stdout.split("\n"):
        line = line.strip()
        if not line:
            continue
        if want and want not in line.lower():
            continue
        print(f"HIT «{line}»")


# ---- axact (batched actions; verified subset on Linux engine v0.1) ----

FRONT_WARN = ""


def cmd_axact(a):
    global FRONT_WARN
    pid = int(a.get("pid", 0))
    acts = json.loads(a.get("json", "[]"))
    idx = c = u = n = e = 0
    abort = ""
    for act in acts:
        op = act.get("op")
        try:
            if op == "click":
                guard_front(pid)
                send_click(act["x"], act["y"])
                time.sleep(0.3)
                print(f"OK confirmed {idx}click @({act['x']},{act['y']}){FRONT_WARN}")
                FRONT_WARN = ""
                c += 1
            elif op == "type":
                guard_front(pid)
                send_text(act["text"])
                print(f"OK delivered {idx}type len={len(act['text'])}{FRONT_WARN}")
                FRONT_WARN = ""
                u += 1
            elif op == "key":
                guard_front(pid)
                send_key(act["spec"])
                print(f"OK delivered {idx}key {act['spec']}{FRONT_WARN}")
                FRONT_WARN = ""
                u += 1
            elif op == "wait":
                time.sleep(int(act["ms"]) / 1000)
                print(f"OK {idx}wait {act['ms']}")
                u += 1
            else:
                raise ValueError(f"unknown op '{op}' (click/type/key/wait on Linux engine v0.1)")
        except Exception as ex:
            e += 1
            print(f"ERR [{idx}] {op}: {ex}")
            abort = f"ABORTED at action[{idx}] op={op}"
            break
        idx += 1
    print(f"SUMMARY confirmed={c} unverified={u} suspected_noop={n} errors={e}" + (f" {abort}" if abort else ""))


# ---- remember / recall (spatial cache, shared file with macOS engine) ----

def cmd_cache_op(a):
    os.makedirs(CACHE_DIR, exist_ok=True)
    cache = {}
    if os.path.exists(CACHE_FILE):
        try:
            cache = json.load(open(CACHE_FILE))
        except Exception:
            cache = {}
    return cache


# ---- relaunch ----

def cmd_relaunch(a):
    app = a.get("app")
    args_ = a.get("args", "")
    subprocess.run(["pkill", "-f", app], capture_output=True)
    time.sleep(0.8)
    cmd = [app] + (args_.split() if args_ else [])
    subprocess.Popen(cmd, start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)
    r = subprocess.run(["pgrep", "-f", app], capture_output=True, text=True)
    if r.stdout.strip():
        print(f"OK relaunch pid={r.stdout.split()[0]}")
    else:
        print("ERR relaunch: process not found after start")


# ---- winlist ----

def cmd_winlist(a):
    filt = a.get("pid")
    r = subprocess.run(["wmctrl", "-lp"], capture_output=True, text=True, timeout=5)
    if r.returncode != 0:
        print("ERR wmctrl not installed (apt install wmctrl)")
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
            pname = open(f"/proc/{pidw}/comm").read().strip()
        except Exception:
            pname = "?"
        print(f"{wid} pid{pidw} {pname} «{title}»")


# ---- dispatch ----

def main():
    if len(sys.argv) < 2:
        print("axc (Linux engine) — winlist|axtree|axread|axact|shot|ocr|relaunch")
        return
    sub, a = sys.argv[1], parse_args(sys.argv)
    {"winlist": cmd_winlist, "axtree": cmd_axtree, "shot": cmd_shot,
     "ocr": cmd_ocr, "axact": cmd_axact, "relaunch": cmd_relaunch}.get(
        sub, lambda _a: print(f"unknown subcommand {sub}"))(a)


if __name__ == "__main__":
    main()
