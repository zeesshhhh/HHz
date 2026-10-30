"""Value, growth, dividend and long-term investing screens. Slow-moving ideas, not trade signals."""
import yfinance as yf
import pandas as pd
from config import STOCKS, LONGTERM

def g(info, k):
    v = info.get(k)
    return v if isinstance(v, (int, float)) else None

def metrics(info):
    price, cap = g(info, "currentPrice"), g(info, "marketCap")
    div = g(info, "dividendRate")
    fcf = g(info, "freeCashflow")
    return {"pe": g(info, "trailingPE"), "pb": g(info, "priceToBook"), "peg": g(info, "trailingPegRatio") or g(info, "pegRatio"),
            "roe": g(info, "returnOnEquity"), "de": g(info, "debtToEquity"), "rev_g": g(info, "revenueGrowth"),
            "earn_g": g(info, "earningsGrowth"), "margin": g(info, "profitMargins"), "payout": g(info, "payoutRatio"),
            "yield": div / price if div and price else None, "fcf_yield": fcf / cap if fcf and cap else None}

def _pt(cond):
    return int(bool(cond))

def value_score(m):
    return (_pt(m["pe"] and 0 < m["pe"] < 18) + _pt(m["pb"] and m["pb"] < 3) + _pt(m["peg"] and 0 < m["peg"] < 1.5)
            + _pt(m["fcf_yield"] and m["fcf_yield"] > 0.04) + _pt(m["roe"] and m["roe"] > 0.15) + _pt(m["de"] is not None and m["de"] < 100))

def growth_score(m):
    return (_pt(m["rev_g"] and m["rev_g"] > 0.15) + _pt(m["earn_g"] and m["earn_g"] > 0.15) + _pt(m["roe"] and m["roe"] > 0.15)
            + _pt(m["margin"] and m["margin"] > 0.10) + _pt((m["peg"] and 0 < m["peg"] < 2) or (m["pe"] and 0 < m["pe"] < 40)))

def dividend_score(m):
    return (_pt(m["yield"] and m["yield"] >= 0.025) + _pt(m["payout"] and 0.2 < m["payout"] < 0.7)
            + _pt(m["earn_g"] is None or m["earn_g"] > 0) + _pt(m["de"] is not None and m["de"] < 150))

def longterm_view(df):
    """Buy-and-hold / long-term: 200-day trend, 12-month return, drawdown, DCA guidance."""
    c = df.close.dropna()
    if len(c) < 210:
        return None
    ma200, dd = c.rolling(200).mean().iloc[-1], c.iloc[-1] / c.iloc[-252:].max() - 1
    yr = c.iloc[-1] / c.iloc[-252] - 1 if len(c) > 252 else float("nan")
    if c.iloc[-1] > ma200:
        plan = "uptrend: keep regular DCA / hold"
    elif dd < -0.3:
        plan = "deep drawdown below 200DMA: accumulate in thirds, not all at once"
    else:
        plan = "below 200DMA: reduce new buys until trend recovers"
    return f"{yr:+.0%} 12m, {dd:.0%} from 1y high, {'above' if c.iloc[-1] > ma200 else 'below'} 200DMA, {plan}"

def top(items, fn, n=3):
    scored = sorted(((fn(m), t, m) for t, m in items), key=lambda x: -x[0])
    return [(s, t, m) for s, t, m in scored[:n] if s >= 3]

def report():
    items = []
    for t in STOCKS:
        try:
            items.append((t, metrics(yf.Ticker(t).info)))
        except Exception:
            pass
    f = lambda x: "n/a" if x is None else f"{x:.1f}"
    lines = ["🏦 <b>Weekly investing report</b> (screens, not advice)\n"]
    for title, fn, show in [
        ("Value", value_score, lambda m: f"P/E {f(m['pe'])}, P/B {f(m['pb'])}, ROE {f(m['roe'] and m['roe'] * 100)}%"),
        ("Growth", growth_score, lambda m: f"rev growth {f(m['rev_g'] and m['rev_g'] * 100)}%, earnings growth {f(m['earn_g'] and m['earn_g'] * 100)}%"),
        ("Dividend", dividend_score, lambda m: f"yield {f(m['yield'] and m['yield'] * 100)}%, payout {f(m['payout'] and m['payout'] * 100)}%")]:
        best = top(items, fn)
        lines.append(f"<b>{title} picks</b>" if best else f"<b>{title}</b>: nothing passes the screen this week")
        lines += [f"• {t} ({s} pts): {show(m)}" for s, t, m in best]
        lines.append("")
    lines.append("<b>Long-term and buy-and-hold</b>")
    for t in LONGTERM:
        try:
            df = yf.download(t, period="2y", interval="1d", progress=False, auto_adjust=True)
            if isinstance(df.columns, pd.MultiIndex):
                df.columns = df.columns.get_level_values(0)
            v = longterm_view(df.rename(columns=str.lower))
            v and lines.append(f"• {t}: {v}")
        except Exception:
            pass
    return "\n".join(lines)
