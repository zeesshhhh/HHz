"""Backtest every technical strategy on history. Usage: python backtest.py [SYMBOL ...]"""
import sys
import numpy as np
from config import *
from data import get_ohlc
from main import load_rows
from strategies import REGISTRY
import telegram

COST_R = 0.05

def stats(rs):
    if not rs:
        return {"trades": 0}
    rs = np.array(rs)
    w, l = rs[rs > 0], rs[rs <= 0]
    eq = np.cumsum(rs)
    return {"trades": len(rs), "win%": round(100 * len(w) / len(rs), 1),
            "PF": round(float(w.sum() / abs(l.sum())), 2) if len(l) and l.sum() else None,
            "avgR": round(float(rs.mean()), 3), "totalR": round(float(eq[-1]), 1),
            "maxDD_R": round(float((np.maximum.accumulate(eq) - eq).max()), 1)}

def run_strategy(R, fn, hold_bars, warm):
    rs, i, n = [], warm, len(R)
    while i < n - 3:
        s = fn(R, i)
        if not s:
            i += 1
            continue
        side, c = s["side"], R[i].close
        entry, risk, reward = R[i + 1].open, abs(c - s["sl"]), abs(s["tp"] - c)
        sl, tp, r = entry - side * risk, entry + side * reward, None
        end = min(n, i + 2 + hold_bars)
        for j in range(i + 1, end):
            x = R[j]
            if (x.low <= sl) if side == 1 else (x.high >= sl):
                r = -1.0
                break
            if (x.high >= tp) if side == 1 else (x.low <= tp):
                r = reward / risk
                break
        if r is None:
            j = end - 1
            r = (R[j].close - entry) * side / risk
        rs.append(r - COST_R)
        i = j + 1
    return rs

def main(symbols):
    data, bh = {}, {}
    for sym in symbols:
        for tf in INTERVAL:
            try:
                data[sym, tf] = load_rows(sym, tf, BACKTEST_PERIOD[tf])
            except Exception as e:
                print(sym, tf, "error", e)
        d = data.get((sym, "1d"))
        if d:
            bh[sym] = (d[-1].close / d[0].close - 1) * 100
    agg, lines = {}, []
    for name, tf, fn, _, hold, _ in REGISTRY:
        for sym in symbols:
            R = data.get((sym, tf))
            if R:
                agg.setdefault(name, []).extend(run_strategy(R, fn, int(hold * 60 / BAR_MIN[tf]), 210 if tf == "1d" else 250))
    lines.append("Strategy backtest (cost 0.05R per trade, next-candle entry, one trade at a time)\n")
    for name, rs in sorted(agg.items(), key=lambda kv: -stats(kv[1]).get("avgR", -9)):
        lines.append(f"{name:16s} {stats(rs)}")
    lines.append("\nBuy and hold benchmark over the daily sample: " + ", ".join(f"{k} {v:+.0f}%" for k, v in bh.items()))
    out = "\n".join(lines)
    print(out)
    open("backtest_results.txt", "w").write(out)
    telegram.send("<pre>" + out[:3800] + "</pre>")

if __name__ == "__main__":
    main(sys.argv[1:] or list(WATCHLIST))
