"""Strategies that need more than one chart or outside data: news, event-driven, momentum ranking,
pairs, arbitrage, options sentiment, order-book microstructure, copy trading."""
import datetime as dt
import json
import numpy as np
import pandas as pd
import requests
from config import *
from strategies import sig

def utc(ts):
    ts = pd.Timestamp(ts)
    return ts.tz_localize("UTC") if ts.tzinfo is None else ts.tz_convert("UTC")

def news_trade(R, i, sentiment):
    """News trading: strong headline sentiment plus a candle that already confirms it."""
    r = R[i]
    big = r.high - r.low >= r.atr
    if sentiment >= 2 and r.close > r.open and big:
        return sig(1, r, f"Bullish headlines (score {sentiment:+.1f}) + confirming candle", 1.5, 1.5)
    if sentiment <= -2 and r.close < r.open and big:
        return sig(-1, r, f"Bearish headlines (score {sentiment:+.1f}) + confirming candle", 1.5, 1.5)

def event_driven(R, i, events, symbol):
    """Event-driven: trade the break of the pre-event range after a high-impact release."""
    r, now = R[i], pd.Timestamp.now(tz="UTC")
    for e in events:
        try:
            if e["country"] not in CURRENCIES.get(symbol, []):
                continue
            t = utc(dt.datetime.fromisoformat(e["date"]))
            if not (pd.Timedelta(minutes=20) <= now - t <= pd.Timedelta(hours=4)) or utc(r.Index) < t:
                continue
            pre = [x for x in R[max(0, i - 60):i] if t - pd.Timedelta(hours=3) <= utc(x.Index) < t]
            if len(pre) < 6:
                continue
            hi, lo = max(x.high for x in pre), min(x.low for x in pre)
            mid = (hi + lo) / 2
            if r.close > hi + 0.25 * r.atr:
                s = sig(1, r, f"Broke pre-event range after {e['country']} {e['title']}", sl=max(mid, r.close - 3 * r.atr), rr=2.0)
            elif r.close < lo - 0.25 * r.atr:
                s = sig(-1, r, f"Broke pre-event range after {e['country']} {e['title']}", sl=min(mid, r.close + 3 * r.atr), rr=2.0)
            else:
                continue
            if s:
                s["event_key"] = f"{e['title']}|{e['date']}"
                return s
        except Exception:
            continue

def momentum_rank(daily):
    """Cross-sectional momentum: long the strongest 60-day performers, short the weakest. daily = {symbol: rows}."""
    ranks = []
    for sym, R in daily.items():
        if len(R) > 70:
            r = R[-2]
            ranks.append((r.close / R[-62].close - 1, sym, r))
    ranks.sort(key=lambda x: x[0], reverse=True)
    out = []
    for roc, sym, r in ranks[:MOMENTUM_TOP_N]:
        if roc > 0 and r.close > r.ema50:
            s = sig(1, r, f"Top-{MOMENTUM_TOP_N} 60d momentum ({roc:+.0%}), above EMA50", 2.5, 3.0)
            s and out.append((sym, s, r))
    for roc, sym, r in ranks[-MOMENTUM_TOP_N:]:
        if roc < 0 and r.close < r.ema50:
            s = sig(-1, r, f"Bottom-{MOMENTUM_TOP_N} 60d momentum ({roc:+.0%}), below EMA50", 2.5, 3.0)
            s and out.append((sym, s, r))
    return out

def pair_signal(a, b, da, db, window=300):
    """Pairs trading: hedge-ratio regression on log prices, trade the spread z-score. da, db = close Series."""
    x = pd.concat([da, db], axis=1, join="inner").dropna().iloc[-window:]
    if len(x) < 150:
        return None
    la, lb = np.log(x.iloc[:, 0].values), np.log(x.iloc[:, 1].values)
    corr = np.corrcoef(np.diff(la), np.diff(lb))[0, 1]
    if corr < PAIR_MIN_CORR:
        return None
    beta, alpha = np.polyfit(lb, la, 1)
    spread = la - (alpha + beta * lb)
    z = (spread[-2] - spread.mean()) / spread.std()
    if abs(z) < PAIR_Z_ENTRY:
        return None
    long_a = z < 0
    return {"pair": f"{a}/{b}", "z": float(z), "beta": float(beta), "corr": float(corr), "time": x.index[-2],
            "text": (f"{'BUY' if long_a else 'SELL'} {a} and {'SELL' if long_a else 'BUY'} {b} (hedge ratio {beta:.2f})\n"
                     f"Spread z-score {z:+.1f}, correlation {corr:.2f}\n"
                     f"Exit when z returns to 0, cut the pair if |z| passes 3.5")}

COIN = {"BTC-USD": "BTC", "ETH-USD": "ETH", "SOL-USD": "SOL"}
KRAKEN = {"BTC": "XBTUSD", "ETH": "ETHUSD", "SOL": "SOLUSD"}

def arbitrage(symbol):
    """Cross-exchange arbitrage scan: OKX vs Coinbase vs Kraken spot. Alert only, never executes."""
    c = COIN.get(symbol)
    if not c:
        return None
    px = {}
    try:
        px["Coinbase"] = float(requests.get(f"https://api.coinbase.com/v2/prices/{c}-USD/spot", timeout=10).json()["data"]["amount"])
    except Exception:
        pass
    try:
        j = requests.get("https://api.kraken.com/0/public/Ticker", params={"pair": KRAKEN[c]}, timeout=10).json()
        px["Kraken"] = float(list(j["result"].values())[0]["c"][0])
    except Exception:
        pass
    try:
        px["OKX (USDT)"] = float(requests.get("https://www.okx.com/api/v5/market/ticker", params={"instId": f"{c}-USDT"}, timeout=10).json()["data"][0]["last"])
    except Exception:
        pass
    if len(px) < 2:
        return None
    lo, hi = min(px, key=px.get), max(px, key=px.get)
    spread = (px[hi] - px[lo]) / px[lo] * 100
    return {"symbol": symbol, "spread": spread, "buy": lo, "sell": hi, "prices": px,
            "hit": spread >= ARB_MIN_PCT}

def options_sentiment(ccy):
    """Options trading data: Deribit put/call open-interest ratio and OI-weighted implied volatility."""
    try:
        res = requests.get("https://www.deribit.com/api/v2/public/get_book_summary_by_currency",
                           params={"currency": ccy, "kind": "option"}, timeout=20).json()["result"]
        call = sum(x["open_interest"] for x in res if x["instrument_name"].endswith("-C"))
        put = sum(x["open_interest"] for x in res if x["instrument_name"].endswith("-P"))
        w = sum(x["open_interest"] for x in res)
        iv = sum(x["mark_iv"] * x["open_interest"] for x in res if x.get("mark_iv")) / w if w else None
        return options_view(ccy, put / call if call else None, iv)
    except Exception:
        return None

def options_equity(ticker):
    try:
        import yfinance as yf
        t = yf.Ticker(ticker)
        ch = t.option_chain(t.options[0])
        call, put = ch.calls.openInterest.sum(), ch.puts.openInterest.sum()
        iv = float(pd.concat([ch.calls, ch.puts]).impliedVolatility.median() * 100)
        return options_view(ticker, put / call if call else None, iv)
    except Exception:
        return None

def options_view(name, pcr, iv):
    if pcr is None:
        return None
    mood = "fearful (contrarian bullish)" if pcr > 1.2 else "complacent (contrarian caution)" if pcr < 0.6 else "balanced"
    idea = ""
    if iv:
        idea = " | high IV: favour defined-risk spreads, selling premium" if iv > 70 else " | low IV: buying calls/puts is cheaper" if iv < 40 else ""
    return {"name": name, "pcr": pcr, "iv": iv, "text": f"{name} options: put/call OI {pcr:.2f} {mood}" + (f", IV {iv:.0f}%" if iv else "") + idea}

def order_book(symbol):
    """HFT-style microstructure snapshot (depth imbalance and spread). Scan-speed, not real HFT."""
    c = COIN.get(symbol)
    if not c:
        return None
    try:
        b = requests.get("https://www.okx.com/api/v5/market/books", params={"instId": f"{c}-USDT", "sz": "20"}, timeout=10).json()["data"][0]
        bv, av = sum(float(x[1]) for x in b["bids"]), sum(float(x[1]) for x in b["asks"])
        bid, ask = float(b["bids"][0][0]), float(b["asks"][0][0])
        return {"imbalance": (bv - av) / (bv + av), "spread_bps": (ask - bid) / bid * 1e4}
    except Exception:
        return None

def copy_signals():
    """Copy trading: relay trades from a trader/source you follow. COPY_SOURCE_URL returns a JSON list of
    {"trader","symbol","side","entry","sl","tp"}."""
    if not COPY_SOURCE_URL:
        return []
    try:
        return requests.get(COPY_SOURCE_URL, timeout=15).json()
    except Exception:
        return []
