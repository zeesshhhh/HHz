"""Publishes docs/feed.json (latest signals, paper account, report) so the Android app can read it."""
import json, os
import pandas as pd

FILE = "docs/feed.json"

def load():
    try:
        return json.load(open(FILE))
    except Exception:
        return {"updated": "", "signals": [], "paper": {}, "report": ""}

def add(fd, sym, sigs):
    now = pd.Timestamp.now(tz="UTC").isoformat()
    for s in sigs:
        agree = sum(x["side"] == s["side"] for x in sigs)
        fd["signals"].insert(0, {"symbol": sym, "side": "BUY" if s["side"] == 1 else "SELL", "strategy": s["strategy"],
                                 "tf": s["tf"], "entry": s["entry"], "sl": s["sl"], "tp": s["tp"], "why": s["why"],
                                 "style": s.get("style", ""), "grade": s.get("grade", ""), "agree": agree, "time": now})
    fd["signals"] = fd["signals"][:100]

def save(fd):
    body = lambda f: json.dumps({k: v for k, v in f.items() if k != "updated"}, sort_keys=True)
    if body(fd) == body(load()):
        return
    fd["updated"] = pd.Timestamp.now(tz="UTC").isoformat()
    os.makedirs("docs", exist_ok=True)
    json.dump(fd, open(FILE, "w"))
