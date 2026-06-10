#!/usr/bin/env python3
# Claude Code statusLine hook for the usage widget.
# Claude Code pipes a JSON blob on stdin that (for subscribers) contains
# `rate_limits` with the SAME real numbers shown in the in-app usage popup.
# We cache it VERBATIM (all windows, including any per-model ones like
# seven_day_opus if present) to ~/.claude/usage-cache.json for the widget,
# and print a compact status line back to Claude Code.

import sys, json, os, time

CACHE = os.path.expanduser("~/.claude/usage-cache.json")
LAST_INPUT = os.path.expanduser("~/.claude/statusline-last-input.json")


def atomic_write(path, obj):
    try:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(obj, f, ensure_ascii=False)
        os.replace(tmp, path)
    except Exception:
        pass


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        print("")
        return

    # Full input snapshot (local only) — lets us discover undocumented fields.
    atomic_write(LAST_INPUT, data)

    rl = data.get("rate_limits") or {}
    model = (data.get("model") or {}).get("display_name")

    # Pass every rate-limit window through verbatim; the widget decides
    # how to label five_hour / seven_day / seven_day_opus / anything new.
    windows = {}
    for key, win in rl.items():
        if isinstance(win, dict):
            windows[key] = win

    if windows:  # never clobber good data with an empty blob
        atomic_write(CACHE, {
            "updated_at": int(time.time()),
            "model": model,
            "windows": windows,
            # Legacy top-level mirrors so old readers keep working.
            "five_hour": windows.get("five_hour"),
            "seven_day": windows.get("seven_day"),
        })

    # Compact status line for Claude Code itself.
    def pct(key):
        p = (windows.get(key) or {}).get("used_percentage")
        return f"{p:.0f}%" if isinstance(p, (int, float)) else None

    parts = []
    if pct("five_hour"):
        parts.append(f"5h {pct('five_hour')}")
    if pct("seven_day"):
        parts.append(f"周 {pct('seven_day')}")
    if pct("seven_day_opus"):
        parts.append(f"Opus周 {pct('seven_day_opus')}")
    line = "  ·  ".join(parts)
    if model:
        line = f"{model}" + ("  ·  " + line if line else "")
    print(line)


if __name__ == "__main__":
    main()
