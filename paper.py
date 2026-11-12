"""Paper-trading ledger.

The JSON file is the source of truth.  The CSV is a reproducible export of every
open and closed paper position.  Writes are atomic so an interrupted GitHub
Actions run cannot leave a truncated log behind.
"""
import csv
import json
import math
import os
import tempfile
import pandas as pd
import config as _cfg

PAPER_START = _cfg.PAPER_START
PAPER_RISK = _cfg.PAPER_RISK
# optional settings: an older config.py without them still works (no fixed amount, no trade limits)
PAPER_AMOUNT = getattr(_cfg, "PAPER_AMOUNT", None)
PAPER_MAX_OPEN = getattr(_cfg, "PAPER_MAX_OPEN", None)
PAPER_MAX_PER_SIDE = getattr(_cfg, "PAPER_MAX_PER_SIDE", None)

FILE, OLD_FILE, CSV_FILE = "docs/paper.json", "paper.json", "docs/paper_log.csv"
COST_R = 0.05
COLUMNS = ["id", "status", "opened_utc", "closed_utc", "hours_held", "symbol", "asset", "strategy", "grade", "tf", "side",
           "entry", "sl", "tp", "risk_pct", "planned_rr", "exit_price", "exit_reason", "same_candle_sl_tp", "r_multiple",
           "pnl_usd", "mfe_r", "mae_r", "agree", "news_mood", "htf_trend", "adx", "rsi", "atr_pct", "hour_utc", "weekday",
           "style", "why"]


def _utc(ts):
    ts = pd.Timestamp(ts)
    return ts.tz_localize("UTC") if ts.tzinfo is None else ts.tz_convert("UTC")


def _empty():
    return {"equity": float(PAPER_START), "open": [], "closed": [], "next_id": 0}


def load():
    for path in (FILE, OLD_FILE):
        try:
            with open(path, encoding="utf-8") as f:
                p = json.load(f)
            if not isinstance(p, dict):
                continue
            p.setdefault("equity", float(PAPER_START))
            p.setdefault("open", [])
            p.setdefault("closed", [])
            p.setdefault("next_id", max([int(x.get("id", 0) or 0) for x in p["open"] + p["closed"]] or [0]))
            if not isinstance(p["open"], list) or not isinstance(p["closed"], list):
                continue
            return p
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            continue
    return _empty()


def _atomic_write(path, writer, binary=False):
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".paper-", suffix=".tmp", dir=directory)
    try:
        mode = "wb" if binary else "w"
        with os.fdopen(fd, mode, newline=None if binary else "", encoding=None if binary else "utf-8") as f:
            writer(f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def save(p):
    """Persist JSON state and regenerate the complete CSV ledger."""
    p["closed"] = p.get("closed", [])[-20000:]
    p["open"] = p.get("open", [])
    p["next_id"] = max(int(p.get("next_id", 0) or 0),
                       max([int(x.get("id", 0) or 0) for x in p["open"] + p["closed"]] or [0]))
    write_csv(p)
    payload = json.dumps(p, ensure_ascii=False, separators=(",", ":"))
    _atomic_write(FILE, lambda f: f.write(payload))


def _row(t, status):
    c = t.get("ctx") or {}
    entry, sl, tp = t.get("entry"), t.get("sl"), t.get("tp")
    try:
        risk_pct = abs(float(entry) - float(sl)) / abs(float(entry)) * 100 if entry is not None and sl is not None and float(entry) else None
    except (TypeError, ValueError, ZeroDivisionError):
        risk_pct = None
    try:
        rr = abs(float(tp) - float(entry)) / abs(float(entry) - float(sl)) if entry is not None and sl is not None and tp is not None and float(entry) != float(sl) else None
    except (TypeError, ValueError, ZeroDivisionError):
        rr = None
    r = lambda v, n=4: None if v is None else round(float(v), n)
    return {"id": t.get("id"), "status": status, "opened_utc": t.get("opened"), "closed_utc": t.get("closed"),
            "hours_held": r(t.get("hours"), 2), "symbol": t.get("symbol"), "asset": c.get("asset"),
            "strategy": t.get("strategy"), "grade": t.get("grade"), "tf": t.get("tf"),
            "side": "BUY" if t.get("side") == 1 else "SELL", "entry": entry, "sl": sl, "tp": tp,
            "risk_pct": r(risk_pct, 3), "planned_rr": r(rr, 2), "exit_price": t.get("exit"),
            "exit_reason": t.get("reason"), "same_candle_sl_tp": t.get("ambiguous"), "r_multiple": r(t.get("r"), 3),
            "pnl_usd": r(t.get("pnl"), 2), "mfe_r": r(t.get("mfe_r"), 2), "mae_r": r(t.get("mae_r"), 2),
            "agree": c.get("agree"), "news_mood": c.get("mood"), "htf_trend": c.get("htf"), "adx": c.get("adx"),
            "rsi": c.get("rsi"), "atr_pct": c.get("atr_pct"), "hour_utc": c.get("hour"), "weekday": c.get("weekday"),
            "style": t.get("style"), "why": t.get("why")}


def write_csv(p):
    """Write a header even with zero trades; include OPEN positions as well as closed."""
    def write(f):
        w = csv.DictWriter(f, fieldnames=COLUMNS, extrasaction="ignore")
        w.writeheader()
        # Stable ordering makes diffs and downstream analysis reproducible.
        records = [(int(t.get("id", 0) or 0), "closed", t) for t in p.get("closed", [])]
        records += [(int(t.get("id", 0) or 0), "open", t) for t in p.get("open", [])]
        for _, status, trade in sorted(records, key=lambda x: x[0]):
            try:
                w.writerow(_row(trade, status))
            except Exception as e:        # one damaged record must never stop the ledger from saving
                print(f"paper_log: skipped trade id={trade.get('id') if isinstance(trade, dict) else '?'}: {e}")
    _atomic_write(CSV_FILE, write)


def open_pos(p, symbol, s):
    """Open one valid paper position. Returns True only when it was recorded."""
    try:
        side, entry, sl, tp = int(s["side"]), float(s["entry"]), float(s["sl"]), float(s["tp"])
    except (KeyError, TypeError, ValueError):
        return False
    if side not in (-1, 1) or not all(math.isfinite(v) for v in (entry, sl, tp)) or entry <= 0:
        return False
    # Reject inverted or non-positive plans rather than recording impossible trades.
    if side == 1 and not (sl < entry < tp):
        return False
    if side == -1 and not (tp < entry < sl):
        return False
    # Broken plans (seen Nov 10: AKE 4h SELL with the stop 79% away and the target below zero) are not traded.
    if tp <= 0 or sl <= 0 or abs(entry - sl) / entry > 0.20:
        return False
    if any(o.get("symbol") == symbol and o.get("strategy") == s.get("strategy") for o in p["open"]):
        return False
    if PAPER_MAX_OPEN is not None and len(p["open"]) >= PAPER_MAX_OPEN:
        return False
    if PAPER_MAX_PER_SIDE is not None and sum(o.get("side") == side for o in p["open"]) >= PAPER_MAX_PER_SIDE:
        return False
    risk = abs(entry - sl)
    if risk <= 0:
        return False
    if PAPER_AMOUNT:                                   # fixed USD position size: a stop-out loses amount x stop distance %
        risk_cash = float(PAPER_AMOUNT) * risk / entry
    else:
        risk_cash = float(p["equity"]) * float(PAPER_RISK)
    if not math.isfinite(risk_cash) or risk_cash <= 0:
        return False
    p["next_id"] = max(int(p.get("next_id", 0) or 0),
                       max([int(x.get("id", 0) or 0) for x in p["open"] + p["closed"]] or [0])) + 1
    p["open"].append({"id": p["next_id"], "symbol": symbol, "strategy": s.get("strategy", "Unknown"), "tf": s.get("tf"), "grade": s.get("grade"),
                      "side": side, "entry": entry, "sl": sl, "tp": tp, "units": risk_cash / risk,
                      "risk": risk_cash, "opened": pd.Timestamp.now(tz="UTC").isoformat(), "hold_h": s.get("hold_h", 72),
                      "style": s.get("style"), "why": s.get("why"), "ctx": s.get("ctx") or {}, "mfe_r": 0.0, "mae_r": 0.0})
    return True


def update(p, rows_by_symbol):
    """Update positions using completed candles for each position's timeframe.

    If one candle touches both SL and TP, conservatively records SL first.
    The currently forming candle is excluded to avoid look-ahead/false fills.
    """
    still, now = [], pd.Timestamp.now(tz="UTC")
    for o in p.get("open", []):
        symbol_rows = rows_by_symbol.get(o.get("symbol")) or []
        if isinstance(symbol_rows, dict):
            R = symbol_rows.get(o.get("tf") or "15m") or []
        else:
            R = symbol_rows
        t0 = _utc(o["opened"])
        closed_rows = R[:-1] if len(R) > 1 else []
        exit_px, reason, t_exit, ambiguous, mfe, mae = None, "", None, False, float(o.get("mfe_r", 0) or 0), float(o.get("mae_r", 0) or 0)
        risk_px = abs(float(o["entry"]) - float(o["sl"])) or 1e-12
        for x in closed_rows:
            candle_time = _utc(x.Index)
            if candle_time <= t0:
                continue
            high, low = float(x.high), float(x.low)
            fav = (high - float(o["entry"])) if o["side"] == 1 else (float(o["entry"]) - low)
            adv = (float(o["entry"]) - low) if o["side"] == 1 else (high - float(o["entry"]))
            mfe, mae = max(mfe, fav / risk_px), max(mae, adv / risk_px)
            hit_sl = low <= o["sl"] if o["side"] == 1 else high >= o["sl"]
            hit_tp = high >= o["tp"] if o["side"] == 1 else low <= o["tp"]
            if hit_sl:
                exit_px, reason, t_exit, ambiguous = float(o["sl"]), "SL", candle_time, bool(hit_tp)
                break
            if hit_tp:
                exit_px, reason, t_exit = float(o["tp"]), "TP", candle_time
                break
        o["mfe_r"], o["mae_r"] = round(mfe, 4), round(mae, 4)
        if exit_px is None and now - t0 > pd.Timedelta(hours=o.get("hold_h", 72)) and closed_rows:
            exit_px, reason, t_exit = float(closed_rows[-1].close), "TIMEOUT", _utc(closed_rows[-1].Index)
        if exit_px is None:
            still.append(o)
            continue
        pnl = (exit_px - float(o["entry"])) * o["side"] * float(o["units"]) - COST_R * float(o["risk"])
        p["equity"] += pnl
        done = {k: o.get(k) for k in ("id", "strategy", "symbol", "tf", "grade", "side", "entry", "sl", "tp", "opened", "style", "why", "ctx", "mfe_r", "mae_r")}
        done.update({"pnl": pnl, "r": pnl / float(o["risk"]), "exit": exit_px, "reason": reason, "ambiguous": ambiguous,
                     "closed": t_exit.isoformat(), "hours": (t_exit - t0).total_seconds() / 3600})
        p.setdefault("closed", []).append(done)
    p["open"] = still


def report(p):
    c = p.get("closed", [])
    lines = [f"💼 <b>Paper account</b>: ${p['equity']:,.0f} ({(p['equity'] / PAPER_START - 1) * 100:+.1f}%), "
             f"{len(p.get('open', []))} open, {len(c)} closed"]
    by = {}
    for t in c:
        if t.get("r") is None:          # skip damaged records instead of crashing the run
            continue
        by.setdefault(t.get("strategy") or "unknown", []).append(t["r"])
    for k, v in sorted(by.items(), key=lambda kv: -sum(kv[1])):
        lines.append(f"• {k}: {len(v)} trades, {100 * sum(r > 0 for r in v) / len(v):.0f}% wins, {sum(v):+.1f}R")
    return "\n".join(lines)


def summary(p):
    by = {}
    for t in p.get("closed", []):
        if t.get("r") is None:          # skip damaged records instead of crashing the run
            continue
        by.setdefault(t.get("strategy") or "unknown", []).append(t["r"])
    return {"equity": round(p["equity"], 2), "start": PAPER_START, "open": len(p.get("open", [])), "closed": len(p.get("closed", [])),
            "strategies": [{"name": k, "trades": len(v), "win": round(100 * sum(r > 0 for r in v) / len(v)), "r": round(sum(v), 1)}
                           for k, v in sorted(by.items(), key=lambda kv: -sum(kv[1]))]}
