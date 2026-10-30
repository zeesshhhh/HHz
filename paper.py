"""Paper trading: every alert becomes a virtual trade so you can see which strategies actually pay.
Every trade is also written to docs/paper_log.csv (with context such as ADX, RSI, news mood, 4h trend and the
best/worst price move after entry) so the bot can be tuned from real results."""
import csv
import json
import os
import pandas as pd
from config import PAPER_START, PAPER_RISK

FILE, OLD_FILE, CSV_FILE = "docs/paper.json", "paper.json", "docs/paper_log.csv"
COST_R = 0.05
COLUMNS = ["id", "status", "opened_utc", "closed_utc", "hours_held", "symbol", "asset", "strategy", "grade", "tf", "side",
           "entry", "sl", "tp", "risk_pct", "planned_rr", "exit_price", "exit_reason", "same_candle_sl_tp", "r_multiple",
           "pnl_usd", "mfe_r", "mae_r", "agree", "news_mood", "htf_trend", "adx", "rsi", "atr_pct", "hour_utc", "weekday",
           "style", "why"]

def _utc(ts):
    ts = pd.Timestamp(ts)
    return ts.tz_localize("UTC") if ts.tzinfo is None else ts.tz_convert("UTC")

def load():
    for f in (FILE, OLD_FILE):
        try:
            return json.load(open(f))
        except Exception:
            pass
    return {"equity": PAPER_START, "open": [], "closed": []}

def save(p):
    p["closed"] = p["closed"][-20000:]
    os.makedirs("docs", exist_ok=True)
    json.dump(p, open(FILE, "w"))
    write_csv(p)

def _row(t, status):
    c = t.get("ctx", {})
    entry, sl = t.get("entry"), t.get("sl")
    risk_pct = abs(entry - sl) / entry * 100 if entry and sl is not None else None
    rr = abs(t["tp"] - entry) / abs(entry - sl) if entry and sl is not None and entry != sl and t.get("tp") is not None else None
    r = lambda v, n=4: None if v is None else round(v, n)
    return {"id": t.get("id"), "status": status, "opened_utc": t.get("opened"), "closed_utc": t.get("closed"),
            "hours_held": r(t.get("hours"), 2), "symbol": t.get("symbol"), "asset": c.get("asset"),
            "strategy": t.get("strategy"), "grade": t.get("grade"), "tf": t.get("tf"),
            "side": "BUY" if t.get("side") == 1 else "SELL", "entry": entry, "sl": sl, "tp": t.get("tp"),
            "risk_pct": r(risk_pct, 3), "planned_rr": r(rr, 2), "exit_price": t.get("exit"),
            "exit_reason": t.get("reason"), "same_candle_sl_tp": t.get("ambiguous"), "r_multiple": r(t.get("r"), 3),
            "pnl_usd": r(t.get("pnl"), 2), "mfe_r": r(t.get("mfe_r"), 2), "mae_r": r(t.get("mae_r"), 2),
            "agree": c.get("agree"), "news_mood": c.get("mood"), "htf_trend": c.get("htf"), "adx": c.get("adx"),
            "rsi": c.get("rsi"), "atr_pct": c.get("atr_pct"), "hour_utc": c.get("hour"), "weekday": c.get("weekday"),
            "style": t.get("style"), "why": t.get("why")}

def write_csv(p):
    os.makedirs("docs", exist_ok=True)
    with open(CSV_FILE, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS)
        w.writeheader()
        for t in p["closed"]:
            w.writerow(_row(t, "closed"))
        for t in p["open"]:
            w.writerow(_row(t, "open"))

def open_pos(p, symbol, s):
    if any(o["symbol"] == symbol and o["strategy"] == s["strategy"] for o in p["open"]):
        return
    risk = abs(s["entry"] - s["sl"])
    if not risk > 0:
        return
    risk_cash = p["equity"] * PAPER_RISK
    p["next_id"] = p.get("next_id", len(p["closed"]) + len(p["open"])) + 1
    p["open"].append({"id": p["next_id"], "symbol": symbol, "strategy": s["strategy"], "tf": s.get("tf"), "grade": s.get("grade"),
                      "side": s["side"], "entry": s["entry"], "sl": s["sl"], "tp": s["tp"], "units": risk_cash / risk,
                      "risk": risk_cash, "opened": pd.Timestamp.now(tz="UTC").isoformat(), "hold_h": s.get("hold_h", 72),
                      "style": s.get("style"), "why": s.get("why"), "ctx": s.get("ctx", {}), "mfe_r": 0.0, "mae_r": 0.0})

def update(p, rows_by_symbol):
    """Update paper positions using closed candles from each position's own timeframe.

    rows_by_symbol is {symbol: {timeframe: rows}} as produced by main.scan().
    Older callers/data remain supported by falling back to a symbol-level row list.
    If one candle touches both SL and TP, conservatively record the SL first.
    """
    still, now = [], pd.Timestamp.now(tz="UTC")
    for o in p["open"]:
        symbol_rows = rows_by_symbol.get(o["symbol"]) or []
        if isinstance(symbol_rows, dict):
            tf = o.get("tf") or "15m"
            R = symbol_rows.get(tf) or []
        else:  # backward compatibility for existing callers
            R = symbol_rows
        t0 = _utc(o["opened"])
        # The final row is generally the currently-forming candle; do not use it
        # to claim an SL/TP fill before that candle has closed.
        closed_rows = R[:-1] if len(R) > 1 else []
        exit_px, reason, t_exit, ambiguous, mfe, mae = None, "", None, False, 0.0, 0.0
        risk_px = abs(float(o["entry"]) - float(o["sl"])) or 1e-12
        for x in closed_rows:
            candle_time = _utc(x.Index)
            if candle_time <= t0:
                continue
            fav = (float(x.high) - o["entry"]) if o["side"] == 1 else (o["entry"] - float(x.low))
            adv = (o["entry"] - float(x.low)) if o["side"] == 1 else (float(x.high) - o["entry"])
            mfe, mae = max(mfe, fav / risk_px), max(mae, adv / risk_px)
            hit_sl = float(x.low) <= o["sl"] if o["side"] == 1 else float(x.high) >= o["sl"]
            hit_tp = float(x.high) >= o["tp"] if o["side"] == 1 else float(x.low) <= o["tp"]
            if hit_sl:
                exit_px, reason, t_exit, ambiguous = o["sl"], "SL", candle_time, bool(hit_tp)
                break
            if hit_tp:
                exit_px, reason, t_exit = o["tp"], "TP", candle_time
                break
        o["mfe_r"], o["mae_r"] = round(mfe, 2), round(mae, 2)
        if exit_px is None and now - t0 > pd.Timedelta(hours=o.get("hold_h", 72)) and closed_rows:
            exit_px, reason, t_exit = float(closed_rows[-1].close), "TIMEOUT", _utc(closed_rows[-1].Index)
        if exit_px is None:
            still.append(o)
            continue
        pnl = (exit_px - o["entry"]) * o["side"] * o["units"] - COST_R * o["risk"]
        p["equity"] += pnl
        done = {k: o.get(k) for k in ("id", "strategy", "symbol", "tf", "grade", "side", "entry", "sl", "tp", "opened", "style", "why", "ctx", "mfe_r", "mae_r")}
        done.update({"pnl": pnl, "r": pnl / o["risk"], "exit": exit_px, "reason": reason, "ambiguous": ambiguous,
                     "closed": t_exit.isoformat(), "hours": (t_exit - t0).total_seconds() / 3600})
        p["closed"].append(done)
    p["open"] = still

def report(p):
    c = p["closed"]
    lines = [f"💼 <b>Paper account</b>: ${p['equity']:,.0f} ({(p['equity'] / PAPER_START - 1) * 100:+.1f}%), "
             f"{len(p['open'])} open, {len(c)} closed"]
    by = {}
    for t in c:
        by.setdefault(t["strategy"], []).append(t["r"])
    for k, v in sorted(by.items(), key=lambda kv: -sum(kv[1])):
        lines.append(f"• {k}: {len(v)} trades, {100 * sum(r > 0 for r in v) / len(v):.0f}% wins, {sum(v):+.1f}R")
    return "\n".join(lines)

def summary(p):
    by = {}
    for t in p["closed"]:
        by.setdefault(t["strategy"], []).append(t["r"])
    return {"equity": round(p["equity"], 2), "start": PAPER_START, "open": len(p["open"]), "closed": len(p["closed"]),
            "strategies": [{"name": k, "trades": len(v), "win": round(100 * sum(r > 0 for r in v) / len(v)), "r": round(sum(v), 1)}
                           for k, v in sorted(by.items(), key=lambda kv: -sum(kv[1]))]}
