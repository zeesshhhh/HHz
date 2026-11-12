"""Experiment lab. Runs in GitHub Actions (no phone needed), see .github/workflows/experiments.yml.

Every indicator, on every coin and every timeframe, opens a virtual trade each time it gives a NEW signal
(a flip or a level cross on a closed candle). The entry is the open of the next candle, so nothing is seen in
advance. Each trade is followed to two targets at once, 1:1 and 1:2, with the stop at 1.5 ATR(14) and a 0.05R fee.
One open trade per indicator, coin and timeframe at a time. Trades that reach neither target within the hold time are
closed at the last price.

Files (in EXP_DIR, published to the exp-data branch):
  exp_state.json    open trades and the last candle processed per coin/timeframe
  exp_stats.json    closed-trade totals per UTC day (kept for KEEP_DAYS days)
  exp_summary.json  the table the app reads
Self-contained on purpose: it does not import the bot's own files, so it works whatever version they are.
"""
import json
import os
import re
import time
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

import numpy as np
import pandas as pd
import requests

OKX = "https://www.okx.com/api/v5"
BAR = {"5m": "5m", "15m": "15m", "30m": "30m", "1h": "1H", "4h": "4H", "1d": "1Dutc"}
HOLD = {"5m": 72, "15m": 48, "30m": 48, "1h": 48, "4h": 30, "1d": 10}      # bars: 6h, 12h, 24h, 48h, 5 days, 10 days
TFS = [t for t in os.getenv("EXP_TFS", "5m,15m,30m,1h,4h,1d").split(",") if t in BAR]
N_COINS = int(os.getenv("EXP_COINS", "30"))
DIR = os.getenv("EXP_DIR", "expdata")
KEEP_DAYS = 30
FEE = 0.05
SL_ATR = 1.5
MIN_N = 50                                        # trades needed before a row can be called proven or losing
EXCLUDE = {"USDC", "FDUSD", "TUSD", "DAI", "USDE", "BUSD", "USDP"}

# News headline experiment: same keyword score and coin names as the app's News tab
NEWS_NAME = "News headline"
NEWS_MAX_AGE_MIN = 60
NEWS_FEEDS = {"CoinDesk": "https://www.coindesk.com/arc/outboundfeeds/rss/", "Cointelegraph": "https://cointelegraph.com/rss",
              "Decrypt": "https://decrypt.co/feed",
              # backup: crypto news sites may block GitHub's servers (no News headline trade in the first 3 days)
              "Google News": "https://news.google.com/rss/search?q=bitcoin+OR+ethereum+OR+crypto+when:1h&hl=en-US&gl=US&ceid=US:en"}
BULL = ['surge', 'rally', 'soar', 'approve', 'inflow', 'adoption', 'rate cut', 'beats', 'record high', 'gains', 'bullish', 'jumps',
        'rebound', 'recovers', 'upgrade', 'breakout', 'etf approval']
BEAR = ['crash', 'plunge', 'hack', 'exploit', 'ban ', 'lawsuit', 'sues', 'rate hike', 'liquidat', 'fears', 'selloff', 'sell-off',
        'bearish', 'slump', 'tumbles', 'warns', 'outflow', 'downgrade', 'sanction', 'default']
NEWS_KEYS = {
    'BTC': ['bitcoin', ' btc'], 'ETH': ['ethereum', ' eth '], 'SOL': ['solana'], 'BNB': [' bnb', 'binance coin'], 'XRP': [' xrp', 'ripple'],
    'DOGE': ['dogecoin', ' doge'], 'ADA': ['cardano'], 'AVAX': ['avalanche'], 'LINK': ['chainlink'], 'DOT': ['polkadot'], 'LTC': ['litecoin'],
    'TRX': [' tron '], 'TON': ['toncoin'], 'SUI': [' sui '], 'SHIB': ['shiba inu'], 'UNI': ['uniswap'], 'AAVE': [' aave'], 'ARB': ['arbitrum'],
    'OP': ['optimism'], 'APT': ['aptos'], 'HYPE': ['hyperliquid'], 'ENA': ['ethena'], 'WLD': ['worldcoin'], 'BCH': ['bitcoin cash'],
    'PEPE': [' pepe'], 'XLM': ['stellar'], 'HBAR': ['hedera'], 'NEAR': ['near protocol'], 'ATOM': ['cosmos'], 'FIL': ['filecoin'],
}


# ---------------------------------------------------------------- data
def okx(path, params, tries=3):
    for k in range(tries):
        try:
            r = requests.get(OKX + path, params=params, timeout=15)
            if r.status_code == 200:
                return r.json().get("data") or []
        except Exception:
            pass
        time.sleep(1 + k)
    return []


def top_coins(n):
    out = []
    for t in okx("/market/tickers", {"instType": "SWAP"}):
        inst = t.get("instId", "")
        base = inst.split("-")[0]
        if not inst.endswith("-USDT-SWAP") or base in EXCLUDE:
            continue
        try:
            out.append((float(t["volCcy24h"]) * float(t["last"]), base))
        except Exception:
            pass
    out.sort(reverse=True)
    return [b for _, b in out[:n]]


def candles(coin, tf):
    """Last 600 candles (two pages), oldest first, with a 'closed' flag (OKX 'confirm')."""
    rows = okx("/market/candles", {"instId": f"{coin}-USDT-SWAP", "bar": BAR[tf], "limit": "300"})
    time.sleep(0.12)                                     # well inside OKX's 40 requests / 2 s
    if not rows:
        return None
    if len(rows) >= 300:                                 # second page (older candles), so long gaps between runs lose nothing
        more = okx("/market/candles", {"instId": f"{coin}-USDT-SWAP", "bar": BAR[tf], "limit": "300",
                                       "after": str(min(int(x[0]) for x in rows))}, tries=1)
        time.sleep(0.12)
        rows = rows + [x for x in more if int(x[0]) < min(int(y[0]) for y in rows)]
    df = pd.DataFrame([[x[0], x[1], x[2], x[3], x[4], x[5], x[8] if len(x) > 8 else "1"] for x in rows],
                      columns=["ts", "open", "high", "low", "close", "volume", "confirm"])
    df["ts"] = df["ts"].astype("int64")
    for c in ("open", "high", "low", "close", "volume"):
        df[c] = df[c].astype(float)
    df["closed"] = df.pop("confirm").astype(str) == "1"
    return df.sort_values("ts").reset_index(drop=True)


def unescape(t):
    for a, b in (('<![CDATA[', ''), (']]>', ''), ('&amp;', '&'), ('&#39;', "'"), ('&#8217;', "'"), ('&quot;', '"'), ('&lt;', '<'), ('&gt;', '>')):
        t = t.replace(a, b)
    return t.strip()


def news_head(t):
    # words after "after", "despite" or "following" are background, not the news itself
    x = f" {t.lower()} "
    for w in (" after ", " despite ", " following "):
        i = x.find(w)
        if i > 0:
            x = x[:i] + " "
    return x


def score_title(t):
    x = news_head(t)
    return sum(w in x for w in BULL) - sum(w in x for w in BEAR)


def parse_rss(body, source):
    out = []
    for m in re.finditer(r'<item[\s>](.*?)</item>', body, re.S):
        blk = m.group(1)
        t = re.search(r'<title[^>]*>(.*?)</title>', blk, re.S)
        d = re.search(r'<pubDate[^>]*>(.*?)</pubDate>', blk, re.S)
        if not t or not d:
            continue
        try:
            pub = int(parsedate_to_datetime(d.group(1).strip()).timestamp() * 1000)
        except Exception:
            continue
        title = unescape(t.group(1))
        out.append((f"{source}|{title}", title, pub, score_title(title)))
    return out


def news_coins(title, coins):
    x = f" {title.lower()} "
    return [c for c, ks in NEWS_KEYS.items() if c in coins and any(k in x for k in ks)]


def news_signals(st, coins, now_ms, fetch=None):
    # coin -> +1 / -1 from new headlines (60 minutes or newer) that name it; several headlines on one coin are added up
    seen = dict.fromkeys(st.get("news_seen", []))
    total, heads, feeds = {}, [], {}
    for src, url in NEWS_FEEDS.items():
        try:
            if fetch:
                body = fetch(url)
            else:
                r = requests.get(url, headers={"User-Agent": "Mozilla/5.0"}, timeout=15)
                if r.status_code != 200:
                    feeds[src] = f"HTTP {r.status_code}"
                    continue
                body = r.text
        except Exception as e:
            feeds[src] = f"error {type(e).__name__}"
            continue
        items = parse_rss(body, src)
        feeds[src] = f"{len(items)} items"
        for key, title, pub, sc in items:
            tkey = "T|" + title.lower()                  # the same story on several sites counts once
            if key in seen or tkey in seen or now_ms - pub > NEWS_MAX_AGE_MIN * 60000 or pub > now_ms + 300000:
                continue
            seen[key] = None
            seen[tkey] = None
            if sc == 0:
                continue
            for c in news_coins(title, coins):
                total[c] = total.get(c, 0) + sc
                heads.append(title)
    st["news_seen"] = list(seen)[-800:]
    st["news_feeds"] = feeds
    return {c: (1 if v > 0 else -1) for c, v in total.items() if v != 0}, heads


def open_news(coin, tf, df, st, side):
    # entry at the current price (after the headline); only candles that start later can hit the stop or target
    if df is None or len(df) < 30:
        return 0
    if any(t["k"] == NEWS_NAME and t["c"] == coin and t["tf"] == tf for t in st["open"]):
        return 0
    cl = df[df["closed"]].reset_index(drop=True)
    a = atr(cl["high"].values, cl["low"].values, cl["close"].values, 14)[-1] if len(cl) > 15 else np.nan
    if np.isnan(a) or a <= 0:
        return 0
    last = df.iloc[-1]
    st["open"].append({"k": NEWS_NAME, "c": coin, "tf": tf, "s": int(side), "e": float(last["close"]), "r": float(SL_ATR * a),
                       "chk": int(last["ts"]), "b": 0, "o1": None, "o2": None,
                       "d": datetime.now(timezone.utc).strftime("%Y-%m-%d")})
    return 1


# ---------------------------------------------------------------- indicator helpers
def ema(x, n):
    return pd.Series(x).ewm(span=n, adjust=False).mean().values


def sma(x, n):
    return pd.Series(x).rolling(n).mean().values


def rma(x, n):
    return pd.Series(x).ewm(alpha=1 / n, adjust=False).mean().values


def wma(x, n):
    w = np.arange(1, n + 1)
    return pd.Series(x).rolling(n).apply(lambda a: np.dot(a, w) / w.sum(), raw=True).values


def prev(a):
    return np.r_[np.nan, a[:-1]]


def flip(state):
    """+1 / -1 on the candle where the sign changes to it, else 0."""
    s = np.nan_to_num(np.sign(state))
    p = np.r_[0, s[:-1]]
    return np.where((s != p) & (s != 0) & (p != 0), s, 0)


def up(a, lvl):
    return (prev(a) <= lvl) & (a > lvl)


def down(a, lvl):
    return (prev(a) >= lvl) & (a < lvl)


def events(up_mask, down_mask):
    return np.where(up_mask, 1, np.where(down_mask, -1, 0))


def true_range(h, l, c):
    pc = prev(c)
    return np.nanmax(np.vstack([h - l, np.abs(h - pc), np.abs(l - pc)]), axis=0)


def atr(h, l, c, n=14):
    return rma(true_range(h, l, c), n)


def rsi(c, n):
    d = np.diff(c, prepend=c[0])
    g, ls = rma(np.clip(d, 0, None), n), rma(np.clip(-d, 0, None), n)
    rs = np.divide(g, ls, out=np.full_like(g, np.inf), where=ls > 0)
    return 100 - 100 / (1 + rs)


def hh(a, n):
    return pd.Series(a).rolling(n).max().values


def ll(a, n):
    return pd.Series(a).rolling(n).min().values


def supertrend(h, l, c, n=10, m=3.0):
    a = atr(h, l, c, n)
    mid = (h + l) / 2
    ub, lb = mid + m * a, mid - m * a
    d = np.zeros(len(c))
    fu, fl = ub.copy(), lb.copy()
    for i in range(1, len(c)):
        fu[i] = ub[i] if (ub[i] < fu[i - 1] or c[i - 1] > fu[i - 1]) else fu[i - 1]
        fl[i] = lb[i] if (lb[i] > fl[i - 1] or c[i - 1] < fl[i - 1]) else fl[i - 1]
        d[i] = 1 if c[i] > fu[i - 1] else -1 if c[i] < fl[i - 1] else d[i - 1]
    return d


def psar(h, l, step=0.02, mx=0.2):
    n = len(h)
    d = np.zeros(n)
    if n < 3:
        return d
    bull, af, ep, sar = True, step, h[0], l[0]
    for i in range(1, n):
        sar = sar + af * (ep - sar)
        if bull:
            sar = min(sar, l[i - 1], l[i - 2] if i > 1 else l[i - 1])
            if l[i] < sar:
                bull, sar, ep, af = False, ep, l[i], step
            elif h[i] > ep:
                ep, af = h[i], min(af + step, mx)
        else:
            sar = max(sar, h[i - 1], h[i - 2] if i > 1 else h[i - 1])
            if h[i] > sar:
                bull, sar, ep, af = True, ep, h[i], step
            elif l[i] < ep:
                ep, af = l[i], min(af + step, mx)
        d[i] = 1 if bull else -1
    return d


def chandelier(h, l, c, n=22, m=3.0):
    a = atr(h, l, c, n)
    ls, ss = hh(h, n) - m * a, ll(l, n) + m * a
    d = np.zeros(len(c))
    for i in range(1, len(c)):
        d[i] = 1 if c[i] > ss[i - 1] else -1 if c[i] < ls[i - 1] else d[i - 1]
    return d


def heikin(o, h, l, c):
    hc = (o + h + l + c) / 4
    ho = np.zeros(len(c))
    ho[0] = (o[0] + c[0]) / 2
    for i in range(1, len(c)):
        ho[i] = (ho[i - 1] + hc[i - 1]) / 2
    return hc - ho


# Mean-reversion signals that also get a "+ trend" version: BUY only while price is above EMA 200 of the same
# timeframe, SELL only while it is below (buy dips in an uptrend, sell rallies in a downtrend). Added Nov 10 after
# the first day showed these signals winning on SELL and losing on BUY in a falling market.
TREND_FILTERED = ["RSI 2 10/90 reversal", "RSI 14 30/70 reversal", "CCI 20 reversal", "Stochastic 14,3 cross in zone",
                  "Williams %R reversal", "MFI 14 reversal", "Z-score 20 reversal", "Ultimate oscillator reversal"]
TREND_SUFFIX = " + trend"


def indicators(df):
    """name -> array of +1 (new BUY signal), -1 (new SELL signal) or 0, one value per candle."""
    o, h, l, c, v = (df[k].values for k in ("open", "high", "low", "close", "volume"))
    e9, e20, e21, e50, e200 = ema(c, 9), ema(c, 20), ema(c, 21), ema(c, 50), ema(c, 200)
    macd = ema(c, 12) - ema(c, 26)
    r14, r2 = rsi(c, 14), rsi(c, 2)
    a10, a14 = atr(h, l, c, 10), atr(h, l, c, 14)
    sd20 = pd.Series(c).rolling(20).std().values
    bu, bl = sma(c, 20) + 2 * sd20, sma(c, 20) - 2 * sd20
    tp = (h + l + c) / 3
    md = pd.Series(tp).rolling(20).apply(lambda a: np.mean(np.abs(a - a.mean())), raw=True).values
    cci = (tp - sma(tp, 20)) / (0.015 * md)
    k = 100 * (c - ll(l, 14)) / (hh(h, 14) - ll(l, 14))
    k = sma(k, 3)
    dk = sma(k, 3)
    wr = -100 * (hh(h, 14) - c) / (hh(h, 14) - ll(l, 14))
    up_m, dn_m = h - prev(h), prev(l) - l
    pdm = np.where((up_m > dn_m) & (up_m > 0), up_m, 0.0)
    mdm = np.where((dn_m > up_m) & (dn_m > 0), dn_m, 0.0)
    trr = rma(true_range(h, l, c), 14)
    pdi, mdi = 100 * rma(pdm, 14) / trr, 100 * rma(mdm, 14) / trr
    with np.errstate(invalid="ignore", divide="ignore"):
        dx = 100 * np.abs(pdi - mdi) / (pdi + mdi)
    adx = rma(np.nan_to_num(dx), 14)
    au = 100 * (25 - pd.Series(h).rolling(26).apply(lambda a: 25 - np.argmax(a), raw=True).values) / 25
    ad = 100 * (25 - pd.Series(l).rolling(26).apply(lambda a: 25 - np.argmin(a), raw=True).values) / 25
    tenkan, kijun = (hh(h, 9) + ll(l, 9)) / 2, (hh(h, 26) + ll(l, 26)) / 2
    rmf = tp * v
    pos = pd.Series(np.where(tp > prev(tp), rmf, 0.0)).rolling(14).sum().values
    neg = pd.Series(np.where(tp < prev(tp), rmf, 0.0)).rolling(14).sum().values
    mfi = 100 - 100 / (1 + np.divide(pos, neg, out=np.full_like(pos, np.inf), where=neg > 0))
    obv = np.cumsum(np.sign(np.diff(c, prepend=c[0])) * v)
    mfm = np.divide((c - l) - (h - c), h - l, out=np.zeros_like(c), where=(h - l) > 0)
    cmf = pd.Series(mfm * v).rolling(20).sum().values / pd.Series(v).rolling(20).sum().values
    z = (c - sma(c, 20)) / sd20
    roc = 100 * (c / np.r_[np.full(12, np.nan), c[:-12]] - 1)
    t3 = ema(ema(ema(c, 15), 15), 15)
    trix = 100 * (t3 / prev(t3) - 1)
    vmp = pd.Series(np.abs(h - prev(l))).rolling(14).sum().values
    vmm = pd.Series(np.abs(l - prev(h))).rolling(14).sum().values
    trs = pd.Series(true_range(h, l, c)).rolling(14).sum().values
    hull = wma(2 * wma(c, 4) - wma(c, 9), 3)
    vwap = pd.Series(tp * v).rolling(50).sum().values / pd.Series(v).rolling(50).sum().values
    mid = (h + l) / 2
    ao = sma(mid, 5) - sma(mid, 34)
    body, pbody = c - o, prev(c) - prev(o)
    eng_up = (pbody < 0) & (body > 0) & (c >= prev(o)) & (o <= prev(c))
    eng_dn = (pbody > 0) & (body < 0) & (c <= prev(o)) & (o >= prev(c))
    t = np.arange(len(c), dtype=float)
    m = lambda a: pd.Series(a).rolling(50).mean().values
    slope = (m(t * c) - m(t) * m(c)) / (m(t * t) - m(t) ** 2)          # least-squares slope over 50 candles
    bp = c - np.minimum(l, prev(c))
    trn = np.maximum(h, prev(c)) - np.minimum(l, prev(c))
    s = lambda a, n: pd.Series(a).rolling(n).sum().values
    uo = 100 * (4 * s(bp, 7) / s(trn, 7) + 2 * s(bp, 14) / s(trn, 14) + s(bp, 28) / s(trn, 28)) / 7
    ku, kl = e20 + 2 * a10, e20 - 2 * a10
    squeeze = (bu < ku) & (bl > kl)
    release = np.r_[False, squeeze[:-1]] & ~squeeze
    vol_surge = (v > 2 * sma(v, 20)) & (np.abs(body) > 0.5 * (h - l))
    out = {
        "EMA 9/21 cross": flip(e9 - e21),
        "EMA 20/50 cross": flip(e20 - e50),
        "EMA 50/200 cross": flip(e50 - e200),
        "Price vs EMA 200": flip(c - e200),
        "SMA 10/30 cross": flip(sma(c, 10) - sma(c, 30)),
        "MACD signal cross": flip(macd - ema(macd, 9)),
        "MACD zero cross": flip(macd),
        "RSI 14 crosses 50": flip(r14 - 50),
        "RSI 14 30/70 reversal": events(up(r14, 30), down(r14, 70)),
        "RSI 2 10/90 reversal": events(up(r2, 10), down(r2, 90)),
        "Stochastic 14,3 cross in zone": events(up(k - dk, 0) & (dk < 20), down(k - dk, 0) & (dk > 80)),
        "CCI 20 breakout": events(up(cci, 100), down(cci, -100)),
        "CCI 20 reversal": events(up(cci, -100), down(cci, 100)),
        "Bollinger breakout": events(up(c - bu, 0), down(c - bl, 0)),
        "Bollinger reversal": events(up(c - bl, 0), down(c - bu, 0)),
        "Keltner breakout": events(up(c - ku, 0), down(c - kl, 0)),
        "Donchian 20 breakout": events(up(c - prev(hh(h, 20)), 0), down(c - prev(ll(l, 20)), 0)),
        "Supertrend 10,3": flip(supertrend(h, l, c)),
        "Parabolic SAR": flip(psar(h, l)),
        "ADX DI cross (ADX 20+)": np.where(adx > 20, flip(pdi - mdi), 0),
        "Aroon 25 cross": flip(au - ad),
        "Ichimoku TK cross": flip(tenkan - kijun),
        "Williams %R reversal": events(up(wr, -80), down(wr, -20)),
        "MFI 14 reversal": events(up(mfi, 20), down(mfi, 80)),
        "OBV vs EMA 21": flip(obv - ema(obv, 21)),
        "Chaikin Money Flow 20": flip(cmf),
        "Z-score 20 reversal": events(up(z, -2), down(z, 2)),
        "ROC 12 zero cross": flip(roc),
        "TRIX 15 signal cross": flip(trix - ema(np.nan_to_num(trix), 9)),
        "Vortex 14 cross": flip(vmp / trs - vmm / trs),
        "Heikin-Ashi color": flip(heikin(o, h, l, c)),
        "Hull MA 9 slope": flip(hull - prev(hull)),
        "VWAP 50 cross": flip(c - vwap),
        "Awesome Oscillator": flip(ao),
        "Engulfing candle": events(eng_up, eng_dn),
        "Linear regression 50 slope": flip(slope),
        "Chandelier exit 22,3": flip(chandelier(h, l, c)),
        "Ultimate oscillator reversal": events(up(uo, 30), down(uo, 70)),
        "Squeeze release": np.where(release, np.sign(c - sma(c, 20)), 0),
        "Volume surge candle": np.where(vol_surge, np.sign(body), 0),
    }
    above, below = c > e200, c < e200
    for n in TREND_FILTERED:
        a = out[n]
        out[n + TREND_SUFFIX] = np.where(((a == 1) & above) | ((a == -1) & below), a, 0)
    return out, a14


# ---------------------------------------------------------------- app Lab rules, run 24/7
# Exact copy of the phone app's Lab (main.dart: analyze + evalSnap), so its 10 indicators are tested around the clock
# instead of only while the app is open. Differences from the experiments above, on purpose:
#   * a signal counts on EVERY closed candle while the indicator is in its zone (not only when it starts)
#   * entry at the signal candle's close, target and stop 1.5 ATR(14), judged over the next 6 candles
#   * neither hit (or both in one candle): closed at the 6th candle's close, capped at +/-1R; fee 0.05R
#   * "+ trend": BUY only while the close is above EMA 200, SELL only while below
LAB_H = 6
LAB_ATR = 1.5
LAB_MIN_BARS = 200


def zone(x, lo, hi):
    return np.where(x < lo, 1, np.where(x > hi, -1, 0))


def lab_states(df):
    """App Lab indicator -> +1 / -1 / 0 for every candle, plus EMA 200 side and ATR(14)."""
    o, h, l, c, v = (df[k].values for k in ("open", "high", "low", "close", "volume"))
    n = len(c)
    r14, r2 = rsi(c, 14), rsi(c, 2)
    hh14, ll14 = hh(h, 14), ll(l, 14)
    with np.errstate(invalid="ignore", divide="ignore"):
        k = np.where(hh14 == ll14, 50.0, 100 * (c - ll14) / (hh14 - ll14))                 # raw %K, as in the app
        tp = (h + l + c) / 3
        sm = sma(tp, 20)
        md = pd.Series(tp).rolling(20).apply(lambda a: np.mean(np.abs(a - a.mean())), raw=True).values
        cci = np.where(md == 0, 0.0, (tp - sm) / (0.015 * md))
        mid = sma(c, 20)
        sd = pd.Series(c).rolling(20).std(ddof=0).values                                   # population sd, as in the app
        pb = np.where(sd == 0, 0.5, (c - (mid - 2 * sd)) / (4 * sd))
        z = np.where(sd > 0, (c - mid) / sd, 0.0)
        raw = tp * v
        pos = pd.Series(np.where(tp > prev(tp), raw, 0.0)).rolling(14).sum().values
        neg = pd.Series(np.where(tp < prev(tp), raw, 0.0)).rolling(14).sum().values
        mfi = np.where(neg == 0, 100.0, 100 - 100 / (1 + pos / neg))
        rh, rl = hh(r14, 14), ll(r14, 14)
        sraw = np.where(rh == rl, 50.0, 100 * (r14 - rl) / (rh - rl))
        srsi = sma(sraw, 3)
        pc = prev(c)
        bp = c - np.minimum(l, pc)
        tr = np.maximum(h, pc) - np.minimum(l, pc)
        rs = lambda a, m: pd.Series(a).rolling(m).sum().values
        av = lambda m: np.where(rs(tr, m) == 0, 0.5, rs(bp, m) / rs(tr, m))
        uo = 100 * (4 * av(7) + 2 * av(14) + av(28)) / 7
    a14 = atr(h, l, c, 14)
    # candle pattern, same order of checks as the app
    body, rg = np.abs(c - o), h - l
    upw, low = h - np.maximum(c, o), np.minimum(c, o) - l
    o1, c1, o2, c2 = prev(o), prev(c), prev(prev(o)), prev(prev(c))
    pbody, big = np.abs(c1 - o1), np.abs(c2 - o2)
    with np.errstate(invalid="ignore"):
        morning = (c2 < o2) & (big > a14 * 0.6) & (pbody < big * 0.4) & (c > o) & (c > (c2 + o2) / 2)
        evening = (c2 > o2) & (big > a14 * 0.6) & (pbody < big * 0.4) & (c < o) & (c < (c2 + o2) / 2)
        bull = (c1 < o1) & (c > o) & (c >= o1) & (o <= c1) & (body > pbody)
        bear = (c1 > o1) & (c < o) & (c <= o1) & (o >= c1) & (body > pbody)
        hammer = (rg > 0) & (body > 0) & (low > 2 * body) & (upw < 0.25 * rg)
        star = (rg > 0) & (body > 0) & (upw > 2 * body) & (low < 0.25 * rg)
    cp = np.select([morning, evening, bull, bear, hammer, star], [1, -1, 1, -1, 1, -1], 0)
    cp[:3] = 0
    ok = lambda x: np.nan_to_num(x, nan=0).astype(int)
    states = {
        "RSI (2)": zone(r2, 10, 90), "RSI (14)": zone(r14, 30, 70), "CCI (20)": zone(cci, -100, 100),
        "Stochastic (14,3)": ok(np.where(np.isnan(hh14), 0, zone(k, 20, 80))),
        "Stochastic RSI": ok(np.where(np.isnan(srsi), 0, zone(srsi, 20, 80))),
        "MFI (14)": ok(np.where(np.isnan(pos + neg), 0, zone(mfi, 20, 80))),
        "Bollinger %B (20,2)": ok(np.where(np.isnan(sd), 0, zone(pb, 0.05, 0.95))),
        "Z-score (20)": ok(np.where(np.isnan(sd), 0, zone(z, -2, 2))),
        "Ultimate Oscillator": ok(np.where(np.isnan(uo), 0, zone(uo, 30, 70))),
        "Candle pattern": cp.astype(int),
    }
    states["CCI (20)"] = ok(np.where(np.isnan(md), 0, states["CCI (20)"]))
    e200 = ema(c, 200)
    trend = np.where(c > e200, 1, -1)
    return states, trend, a14


def lab_r(side, race, move):
    if race == side:
        return 1 - FEE
    if race == -side:
        return -1 - FEE
    return min(max(move * side / LAB_ATR, -1.0), 1.0) - FEE


def lab_eval(i, hi, lo, c, a):
    """Race of candle i's signal over the next LAB_H candles: +1 upper level first, -1 lower first, 0 neither / both."""
    up, dn = c[i] + LAB_ATR * a, c[i] - LAB_ATR * a
    race = 0
    for j in range(i + 1, i + LAB_H + 1):
        hu, hd = hi[j] >= up, lo[j] <= dn
        if hu or hd:
            race = 0 if (hu and hd) else (1 if hu else -1)
            break
    return race, (c[i + LAB_H] - c[i]) / a


def lab_process(coin, tf, df, st, stats):
    """Score every app-Lab signal whose 6 candles have closed. First run: every candle with 200+ candles of history."""
    if df is None:
        return 0
    cl = df[df["closed"]].reset_index(drop=True)
    n = len(cl)
    if n < LAB_MIN_BARS + LAB_H + 2:
        return 0
    key = f"{coin}|{tf}"
    done = st.setdefault("lab_last", {}).get(key)
    ts = cl["ts"].values
    idx = [i for i in range(LAB_MIN_BARS, n - LAB_H) if done is None or ts[i] > done]
    if not idx:
        return 0
    states, trend, a14 = lab_states(cl)
    hi, lo, c = cl["high"].values, cl["low"].values, cl["close"].values
    count = 0
    for i in idx:
        a = a14[i]
        if np.isnan(a) or a <= 0:
            continue
        race = move = None
        for name, arr in states.items():
            side = int(arr[i])
            if side == 0:
                continue
            if race is None:
                race, move = lab_eval(i, hi, lo, c, a)
            r = round(lab_r(side, race, move), 3)
            day = datetime.fromtimestamp(int(ts[i + 1]) / 1000, timezone.utc).strftime("%Y-%m-%d")
            sd = "BUY" if side == 1 else "SELL"
            names = [name] + ([name + TREND_SUFFIX] if trend[i] == side else [])
            bucket = stats.setdefault(day, {})
            for nm in names:
                for k in (f"L|{nm}|{sd}", f"l|{nm}|{tf}|{sd}"):
                    row = bucket.setdefault(k, [0, 0, 0.0, 0.0, 0, 0.0, 0.0])
                    row[0] += 1
                    for j in (1, 4):                       # one result per signal: shown under both target columns
                        if r > 0:
                            row[j] += 1
                        else:
                            row[j + 2] = round(row[j + 2] - r, 3)
                        row[j + 1] = round(row[j + 1] + r, 3)
                count += 1
    st["lab_last"][key] = int(ts[idx[-1]])
    return count


# ---------------------------------------------------------------- trades
def step(tr, hi, lo, cl, hold):
    """Advance one open trade by one closed candle. Both targets share the stop. Stop first if both touch in one candle."""
    side, e, rk = tr["s"], tr["e"], tr["r"]
    sl = e - side * rk
    hit_sl = lo <= sl if side == 1 else hi >= sl
    for key, mult in (("o1", 1), ("o2", 2)):
        if tr[key] is not None:
            continue
        tp = e + side * mult * rk
        if hit_sl:
            tr[key] = round(-1 - FEE, 3)
        elif (hi >= tp if side == 1 else lo <= tp):
            tr[key] = round(mult - FEE, 3)
    tr["b"] += 1
    if tr["b"] >= hold:
        for key, mult in (("o1", 1), ("o2", 2)):
            if tr[key] is None:
                tr[key] = round(min(max((cl - e) * side / rk, -1.0), float(mult)) - FEE, 3)
    return tr["o1"] is not None and tr["o2"] is not None


def add_stat(stats, tr):
    day = tr["d"]
    sd = "BUY" if tr["s"] == 1 else "SELL"
    keys = ["all", f"I|{tr['k']}|{sd}", f"i|{tr['k']}|{tr['tf']}|{sd}", f"c|{tr['c']}|{sd}",
            f"t|{tr['tf']}|{sd}", f"ic|{tr['k']}|{sd}|{tr['c']}"]
    bucket = stats.setdefault(day, {})
    for k in keys:
        a = bucket.setdefault(k, [0, 0, 0.0, 0.0, 0, 0.0, 0.0])    # n, wins 1:1, R 1:1, losses 1:1, wins 1:2, R 1:2, losses 1:2
        a[0] += 1
        for j, r in ((1, tr["o1"]), (4, tr["o2"])):
            if r > 0:
                a[j] += 1
            else:
                a[j + 2] = round(a[j + 2] - r, 3)
            a[j + 1] = round(a[j + 1] + r, 3)


def process(coin, tf, df, st, stats):
    """Resolve open trades with newly closed candles, then open trades for new signals. Returns signals opened."""
    if df is None or len(df) < 230:
        return 0
    cl = df[df["closed"]].reset_index(drop=True)
    if len(cl) < 220:
        return 0
    key = f"{coin}|{tf}"
    last = st["last"].get(key)
    ts = cl["ts"].values
    # 1) open trades of this coin / timeframe
    keep, freed = [], {}                                   # freed: indicator -> time its trade closed in this run
    for tr in st["open"]:
        if tr["c"] != coin or tr["tf"] != tf:
            keep.append(tr)
            continue
        done = False
        for i in np.where(ts > tr["chk"])[0]:
            done = step(tr, cl["high"].iat[i], cl["low"].iat[i], cl["close"].iat[i], HOLD[tf])
            tr["chk"] = int(ts[i])
            if done:
                break
        if done:
            add_stat(stats, tr)
            freed[tr["k"]] = tr["chk"]
        else:
            keep.append(tr)
    st["open"] = keep
    # 2) new signals on candles closed since the last run (first run: only the newest closed candle)
    new_idx = [len(cl) - 1] if last is None else [i for i in np.where(ts > last)[0]]
    st["last"][key] = int(ts[-1])
    if not new_idx:
        return 0
    sig, a14 = indicators(cl)
    busy = dict(freed)                                      # name -> busy until (ms); still open = forever
    busy.update({tr["k"]: float("inf") for tr in st["open"] if tr["c"] == coin and tr["tf"] == tf})
    opened = 0
    for i in new_idx:
        if np.isnan(a14[i]) or a14[i] <= 0:
            continue
        if i + 1 < len(cl):
            entry, ets = cl["open"].iat[i + 1], int(ts[i + 1])
        else:
            nxt = df[~df["closed"]]
            if nxt.empty:
                continue
            entry, ets = float(nxt["open"].iat[0]), int(nxt["ts"].iat[0])
        for name, arr in sig.items():
            side = int(arr[i])
            if side == 0 or ts[i] < busy.get(name, -1):
                continue
            tr = {"k": name, "c": coin, "tf": tf, "s": side, "e": float(entry), "r": float(SL_ATR * a14[i]),
                  "chk": ets - 1, "b": 0, "o1": None, "o2": None,
                  "d": datetime.fromtimestamp(ets / 1000, timezone.utc).strftime("%Y-%m-%d")}
            # catch-up: candles after the entry that are already closed resolve the trade right away
            done = False
            for j in np.where(ts >= ets)[0]:
                done = step(tr, cl["high"].iat[j], cl["low"].iat[j], cl["close"].iat[j], HOLD[tf])
                tr["chk"] = int(ts[j])
                if done:
                    break
            if done:
                add_stat(stats, tr)
                busy[name] = tr["chk"]                       # no overlapping trade for this indicator
            else:
                st["open"].append(tr)
                busy[name] = float("inf")
            opened += 1
    return opened


# ---------------------------------------------------------------- summary
def summary(stats, st, coins, run_info):
    days = sorted(stats)
    tot = sum(stats[d].get("all", [0])[0] for d in days)
    split, acc = (days[0] if days else ""), 0
    for d in days:                                      # first day of the newer half (by trade count)
        acc += stats[d].get("all", [0])[0]
        if acc >= tot / 2:
            split = d
            break
    agg = {}
    for d in days:
        newer = d > split if len(days) > 1 else False
        for k, a in stats[d].items():
            t = agg.setdefault(k, [0, 0, 0.0, 0.0, 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
            for j in range(7):
                t[j] += a[j]
            t[8 if newer else 7] += a[2]
            t[10 if newer else 9] += a[5]
    rows = {}
    for k, t in agg.items():
        n = t[0]
        pf = lambda r, loss: round((r + loss) / loss, 2) if loss > 0 else (99.0 if r > 0 else 0.0)
        rows[k] = [n, round(100 * t[1] / n, 1), round(t[2], 2), pf(t[2], t[3]), round(t[7], 2), round(t[8], 2),
                   round(100 * t[4] / n, 1), round(t[5], 2), pf(t[5], t[6]), round(t[9], 2), round(t[10], 2)]
    return {"updated": datetime.now(timezone.utc).isoformat(timespec="seconds"), "coins": coins, "tfs": TFS,
            "open": len(st["open"]), "closed": tot, "days": [days[0], days[-1]] if days else [], "split": split,
            "min_n": MIN_N, "fee": FEE, "sl_atr": SL_ATR, "run": run_info,
            "cols": ["n", "win_1to1", "R_1to1", "pf_1to1", "R_1to1_older", "R_1to1_newer",
                     "win_1to2", "R_1to2", "pf_1to2", "R_1to2_older", "R_1to2_newer"],
            "rows": rows}


def load(name, default):
    try:
        with open(os.path.join(DIR, name)) as f:
            return json.load(f)
    except Exception:
        return default


def save(name, obj):
    os.makedirs(DIR, exist_ok=True)
    tmp = os.path.join(DIR, name + ".tmp")
    with open(tmp, "w") as f:
        json.dump(obj, f, separators=(",", ":"))
    os.replace(tmp, os.path.join(DIR, name))


def main():
    t0 = time.time()
    st = load("exp_state.json", {"open": [], "last": {}, "coins": []})
    stats = load("exp_stats.json", {})
    coins = top_coins(N_COINS) or st.get("coins") or ["BTC", "ETH", "SOL"]
    # coins that dropped out of the top list keep being followed until their open trades close
    follow = list(dict.fromkeys(coins + sorted({t["c"] for t in st["open"]})))
    opened = errors = 0
    try:
        nsig, heads = news_signals(st, set(coins), int(time.time() * 1000))
    except Exception as e:
        nsig, heads = {}, []
        print(f"news: {e}")
    news_opened = lab_scored = 0
    for coin in follow:
        for tf in TFS:
            in_top = coin in coins
            if not in_top and not any(t["c"] == coin and t["tf"] == tf for t in st["open"]):
                continue
            try:
                df = candles(coin, tf)
                if not in_top and df is not None and df["closed"].any():
                    st["last"][f"{coin}|{tf}"] = int(df.loc[df["closed"], "ts"].max())   # resolve only, no new trades
                opened += process(coin, tf, df, st, stats)
                if in_top:
                    lab_scored += lab_process(coin, tf, df, st, stats)
                if in_top and coin in nsig:
                    k = open_news(coin, tf, df, st, nsig[coin])
                    opened += k
                    news_opened += k
            except Exception as e:
                errors += 1
                print(f"{coin} {tf}: {e}")
    cutoff = (pd.Timestamp.now(tz="UTC") - pd.Timedelta(days=KEEP_DAYS)).strftime("%Y-%m-%d")
    stats = {d: v for d, v in stats.items() if d >= cutoff}
    st["coins"] = coins
    info = {"opened": opened, "errors": errors, "seconds": round(time.time() - t0, 1), "news_trades": news_opened, "lab_signals_scored": lab_scored,
            "news_coins": sorted(nsig), "news_headlines": heads[:10], "news_feeds": st.get("news_feeds", {})}
    save("exp_state.json", st)
    save("exp_stats.json", stats)
    save("exp_summary.json", summary(stats, st, coins, info))
    print(f"coins {len(coins)}, timeframes {len(TFS)}, opened {opened}, open now {len(st['open'])}, errors {errors}, {info['seconds']}s")


if __name__ == "__main__":
    main()
