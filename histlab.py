#!/usr/bin/env python3
"""Historical lab: tests the app's indicators and verdict on months of OKX candles across many coins.

What it answers (results go to docs/histlab/):
  1. Which indicators are really right, after removing the market's own drift (market-adjusted), and does that hold
     in the first 60% of the history AND the last 40% (out of sample)?
  2. What does the app's overall verdict earn as a trade (SL 1.5 ATR, target 1R/1.5R/2R/3R, 0.05R costs), per
     timeframe, with and without each filter (volume, ADX, higher timeframe, Bitcoin trend)?
  3. How does it do in rising, falling and sideways Bitcoin regimes, and month by month?

Indicator logic is a Python port of the Dart app (analyze()). Support/resistance is not ported, so the overall score
can differ slightly from the app. Signals use only data up to the close of the signal candle (no look-ahead).

Usage:  python histlab.py [--coins 40] [--tfs 15m,1h,4h,1d] [--synthetic]
"""
import argparse
import os
import pickle
import sys
import time
import numpy as np
import pandas as pd

OUT = "docs/histlab"
CACHE = "histlab_cache"
OKX = "https://www.okx.com/api/v5"
BAR = {"15m": "15m", "1h": "1H", "4h": "4H", "1d": "1D"}
DAYS = {"15m": 90, "1h": 240, "4h": 540, "1d": 1000}
TF_MIN = {"15m": 15, "1h": 60, "4h": 240, "1d": 1440}
TF_NEXT = {"15m": "1h", "1h": "4h", "4h": "1d", "1d": None}
H = 6                 # judged 6 candles after the signal (same as the app's Lab)
RACE = 1.5            # +/-1.5 ATR race test
SL_ATR = 1.5          # trade stop distance
TPS = (1.0, 1.5, 2.0, 3.0)
COST_R = 0.05
MAX_HOLD = 48         # bars before a trade is closed at the market
WARM = 260            # bars skipped while the slow averages settle
STABLES = {"USDC", "FDUSD", "TUSD", "USDT", "DAI", "USDE", "USDG", "PYUSD"}


# ------------------------------------------------------------------ data
def get_json(url, params, tries=5):
    import requests
    for i in range(tries):
        try:
            r = requests.get(url, params=params, timeout=20)
            j = r.json()
            if str(j.get("code", "0")) == "0":
                return j
            if str(j.get("code")) == "50011":      # rate limited
                time.sleep(1 + i)
                continue
            return j
        except Exception:
            time.sleep(1 + i)
    return {"data": []}


def top_coins(n):
    j = get_json(f"{OKX}/market/tickers", {"instType": "SWAP"})
    rows = []
    for t in j.get("data", []):
        inst = t.get("instId", "")
        base = inst.split("-")[0]
        if inst.endswith("-USDT-SWAP") and base not in STABLES:
            try:
                rows.append((float(t["volCcy24h"]) * float(t["last"]), base))
            except Exception:
                pass
    rows.sort(reverse=True)
    coins = [b for _, b in rows[:n]]
    if "BTC" not in coins:
        coins.insert(0, "BTC")
    return coins


def history(coin, tf):
    path = os.path.join(CACHE, f"{coin}_{tf}.pkl")
    if os.path.exists(path) and time.time() - os.path.getmtime(path) < 20 * 3600:
        return pickle.load(open(path, "rb"))
    need = DAYS[tf] * 1440 // TF_MIN[tf]
    out, after = [], None
    while len(out) < need:
        p = {"instId": f"{coin}-USDT-SWAP", "bar": BAR[tf], "limit": "100"}
        if after:
            p["after"] = after
        data = get_json(f"{OKX}/market/history-candles", p).get("data") or []
        if not data:
            break
        out.extend(data)
        after = data[-1][0]
        time.sleep(0.11)
        if len(data) < 100:
            break
    if not out:
        return None
    df = pd.DataFrame([x[:9] for x in out], columns=["ts", "open", "high", "low", "close", "volume", "vc", "vq", "conf"])
    df = df[df.conf == "1"]                                   # closed candles only
    df.index = pd.to_datetime(df.ts.astype("int64"), unit="ms", utc=True)
    df = df[["open", "high", "low", "close", "volume"]].astype(float).sort_index()
    df = df[~df.index.duplicated()].dropna()
    os.makedirs(CACHE, exist_ok=True)
    pickle.dump(df, open(path, "wb"))
    return df


def synthetic(coins, tfs, seed=7):
    """Random-walk market with a shared factor. There is NO edge in it, so every result should be about zero."""
    rng = np.random.default_rng(seed)
    data = {}
    for tf in tfs:
        n = DAYS[tf] * 1440 // TF_MIN[tf]
        n = min(n, 6000)
        idx = pd.date_range("2026-01-01", periods=n, freq=f"{TF_MIN[tf]}min", tz="UTC")
        common = rng.normal(0, 0.004, n)
        for c in coins:
            r = common + rng.normal(0, 0.006, n)
            close = 100 * np.exp(np.cumsum(r))
            op = np.r_[close[0], close[:-1]]
            hi = np.maximum(op, close) * (1 + np.abs(rng.normal(0, 0.002, n)))
            lo = np.minimum(op, close) * (1 - np.abs(rng.normal(0, 0.002, n)))
            data[(c, tf)] = pd.DataFrame({"open": op, "high": hi, "low": lo, "close": close, "volume": rng.uniform(100, 1000, n)}, index=idx)
    return data


# ------------------------------------------------------------------ indicators (port of the Dart analyze())
def ema(s, n):
    return s.ewm(span=n, adjust=False).mean()


def wilder(s, n):
    return s.ewm(alpha=1.0 / n, adjust=False).mean()


def wma(s, p):
    w = np.arange(1, p + 1, dtype=float)
    return s.rolling(p).apply(lambda x: np.dot(x, w) / w.sum(), raw=True)


def sgn(cond_up, cond_dn):
    return np.where(cond_up, 1, np.where(cond_dn, -1, 0)).astype(np.int8)


MEAN_REV = {"RSI (14)", "Stochastic (14,3)", "CCI (20)", "Williams %R (14)", "Bollinger %B (20,2)", "MFI (14)",
            "Stochastic RSI", "Ultimate Oscillator"}


def features(df):
    o, h, l, c, v = df.open, df.high, df.low, df.close, df.volume
    n = len(df)
    pc = c.shift()
    tr = pd.concat([h - l, (h - pc).abs(), (l - pc).abs()], axis=1).max(axis=1)
    atr = wilder(tr, 14)
    tp = (h + l + c) / 3
    V = {}
    ma_names = []

    def add(name, arr, ma=False):
        V[name] = pd.Series(np.asarray(arr), index=df.index).fillna(0).astype(np.int8)
        if ma:
            ma_names.append(name)

    for p in (10, 20, 30, 50, 100, 200):
        add(f"EMA {p}", np.where(c > ema(c, p), 1, -1), True)
    for p in (10, 20, 30, 50, 100, 200):
        add(f"SMA {p}", np.where(c > c.rolling(p).mean(), 1, -1), True)
    vw = (tp * v).rolling(50).sum() / v.rolling(50).sum().replace(0, np.nan)
    add("VWAP (50)", np.where(c > vw, 1, -1), True)
    vwm = (c * v).rolling(20).sum() / v.rolling(20).sum().replace(0, np.nan)
    add("VWMA (20)", np.where(c > vwm, 1, -1), True)

    # supertrend (10, 3)
    a10 = wilder(tr, 10).values
    hl2 = ((h + l) / 2).values
    cv, hv, lv = c.values, h.values, l.values
    st = np.ones(n, dtype=np.int8)
    fu = fl = 0.0
    d = 1
    for i in range(n):
        ub, lb = hl2[i] + 3 * a10[i], hl2[i] - 3 * a10[i]
        if i == 0 or np.isnan(ub):
            fu, fl = ub, lb
            st[i] = d
            continue
        pfu, pfl = fu, fl
        fu = ub if (ub < pfu or cv[i - 1] > pfu or np.isnan(pfu)) else pfu
        fl = lb if (lb > pfl or cv[i - 1] < pfl or np.isnan(pfl)) else pfl
        if d == 1 and cv[i] < fl:
            d = -1
        elif d == -1 and cv[i] > fu:
            d = 1
        st[i] = d
    add("Supertrend (10,3)", st, True)

    # parabolic SAR (same simplified rules as the app)
    up, af, ep, sar = True, 0.02, hv[0], lv[0]
    ps = np.ones(n, dtype=np.int8)
    for i in range(1, n):
        sar = sar + af * (ep - sar)
        if up:
            if lv[i] < sar:
                up, sar, ep, af = False, ep, lv[i], 0.02
            elif hv[i] > ep:
                ep, af = hv[i], min(af + 0.02, 0.2)
        else:
            if hv[i] > sar:
                up, sar, ep, af = True, ep, hv[i], 0.02
            elif lv[i] < ep:
                ep, af = lv[i], min(af + 0.02, 0.2)
        ps[i] = 1 if up else -1
    add("Parabolic SAR", ps, True)

    # Ichimoku
    tenkan = (h.rolling(9).max() + l.rolling(9).min()) / 2
    kijun = (h.rolling(26).max() + l.rolling(26).min()) / 2
    sa = ((tenkan + kijun) / 2).shift(26)
    sb = ((h.rolling(52).max() + l.rolling(52).min()) / 2).shift(26)
    top, bot = np.maximum(sa, sb), np.minimum(sa, sb)
    add("Ichimoku", sgn((c > top) & (tenkan > kijun), (c < bot) & (tenkan < kijun)), True)
    hma = wma(2 * wma(c, 4) - wma(c, 9), 3)
    add("Hull MA (9)", np.where(c > hma, 1, -1), True)

    # ---- oscillators
    dlt = c.diff().fillna(0)
    rsi = 100 - 100 / (1 + wilder(dlt.clip(lower=0), 14) / wilder((-dlt).clip(lower=0), 14).replace(0, np.nan))
    rsi = rsi.fillna(100)
    add("RSI (14)", sgn(rsi < 30, rsi > 70))
    hh14, ll14 = h.rolling(14).max(), l.rolling(14).min()
    k = 100 * (c - ll14) / (hh14 - ll14).replace(0, np.nan)
    add("Stochastic (14,3)", sgn(k < 20, k > 80))
    sma_tp = tp.rolling(20).mean()
    md = tp.rolling(20).apply(lambda x: np.abs(x - x.mean()).mean(), raw=True)
    cci = (tp - sma_tp) / (0.015 * md.replace(0, np.nan))
    add("CCI (20)", sgn(cci < -100, cci > 100))
    wr = -100 * (hh14 - c) / (hh14 - ll14).replace(0, np.nan)
    add("Williams %R (14)", sgn(wr < -80, wr > -20))
    macd = ema(c, 12) - ema(c, 26)
    hist = macd - ema(macd, 9)
    add("MACD (12,26,9)", sgn(hist > 0, hist < 0))
    mom = c - c.shift(10)
    add("Momentum (10)", sgn(mom > 0, mom < 0))
    hl2s = (h + l) / 2
    ao = hl2s.rolling(5).mean() - hl2s.rolling(34).mean()
    add("Awesome Oscillator", np.where(ao > 0, 1, -1))

    # ADX (14)
    up_m, dn_m = h.diff(), -l.diff()
    pdm = pd.Series(np.where((up_m > dn_m) & (up_m > 0), up_m, 0.0), index=df.index)
    ndm = pd.Series(np.where((dn_m > up_m) & (dn_m > 0), dn_m, 0.0), index=df.index)
    atr_a = wilder(tr, 14).replace(0, np.nan)
    pdi, ndi = 100 * wilder(pdm, 14) / atr_a, 100 * wilder(ndm, 14) / atr_a
    dx = (100 * (pdi - ndi).abs() / (pdi + ndi).replace(0, np.nan)).fillna(0)
    adx = wilder(dx, 14)
    add("ADX (14)", np.where(adx > 20, np.where(pdi > ndi, 1, -1), 0))

    mid20 = c.rolling(20).mean()
    sd20 = c.rolling(20).std(ddof=0)
    pb = (c - (mid20 - 2 * sd20)) / (4 * sd20).replace(0, np.nan)
    add("Bollinger %B (20,2)", sgn(pb < 0.05, pb > 0.95))
    add("Donchian break (20)", sgn(c > h.shift(1).rolling(20).max(), c < l.shift(1).rolling(20).min()))

    rawf = tp * v
    posf = rawf.where(tp > tp.shift(), 0.0).rolling(14).sum()
    negf = rawf.where(tp < tp.shift(), 0.0).rolling(14).sum()
    mfi = (100 - 100 / (1 + posf / negf.replace(0, np.nan))).fillna(100)
    add("MFI (14)", sgn(mfi < 20, mfi > 80))
    obv = (np.sign(c.diff().fillna(0)) * v).cumsum()
    add("OBV vs EMA21", np.where(obv > ema(obv, 21), 1, -1))

    kmid = ema(c, 20)
    a10s = pd.Series(a10, index=df.index)
    add("Keltner channel (20,2)", sgn(c > kmid + 2 * a10s, c < kmid - 2 * a10s))
    rmin, rmax = rsi.rolling(14).min(), rsi.rolling(14).max()
    srsi = (100 * (rsi - rmin) / (rmax - rmin).replace(0, np.nan)).rolling(3).mean()
    add("Stochastic RSI", sgn(srsi < 20, srsi > 80))

    bp = c - np.minimum(l, pc)
    trr = np.maximum(h, pc) - np.minimum(l, pc)

    def avg(p):
        return bp.rolling(p).sum() / trr.rolling(p).sum().replace(0, np.nan)

    uo = 100 * (4 * avg(7) + 2 * avg(14) + avg(28)) / 7
    add("Ultimate Oscillator", sgn(uo < 30, uo > 70))

    def since_max(x):
        return np.argmax(x[::-1])

    def since_min(x):
        return np.argmin(x[::-1])

    a_up = 100 * (25 - h.rolling(26).apply(since_max, raw=True)) / 25
    a_dn = 100 * (25 - l.rolling(26).apply(since_min, raw=True)) / 25
    add("Aroon (25)", sgn(a_up - a_dn > 50, a_up - a_dn < -50))

    e13 = ema(c, 13)
    bull, bear = h - e13, l - e13
    rising = e13 > e13.shift()
    add("Elder Ray (13)", sgn(rising & (bear < 0) & (bear > bear.shift()), (~rising) & (bull > 0) & (bull < bull.shift())))
    rng_ = (h - l).replace(0, np.nan)
    clv = (((c - l) - (h - c)) / rng_).fillna(0)
    cmf = (clv * v).rolling(20).sum() / v.rolling(20).sum().replace(0, np.nan)
    add("Chaikin Money Flow (20)", sgn(cmf > 0.05, cmf < -0.05))
    t3 = ema(ema(ema(c, 15), 15), 15)
    trix = t3.pct_change()
    add("TRIX (15)", sgn(trix > 0, trix < 0))
    roc = c / c.shift(12) - 1
    add("ROC (12)", sgn(roc > 0, roc < 0))
    vmp = (h - l.shift()).abs().rolling(14).sum()
    vmm = (l - h.shift()).abs().rolling(14).sum()
    trs = tr.rolling(14).sum().replace(0, np.nan)
    vdiff = (vmp - vmm) / trs
    add("Vortex (14)", sgn(vdiff > 0.05, vdiff < -0.05))

    m_now = c - ((h.rolling(20).max() + l.rolling(20).min()) / 2 + c.rolling(20).mean()) / 2
    m_prev = m_now.shift()
    add("Squeeze Momentum", sgn((m_now > 0) & (m_now > m_prev), (m_now < 0) & (m_now < m_prev)))

    # Heikin-Ashi: three candles in a row
    hac = ((o + h + l + c) / 4).values
    hao = np.zeros(n)
    hao[0] = (o.values[0] + cv[0]) / 2
    for i in range(1, n):
        hao[i] = (hao[i - 1] + hac[i - 1]) / 2
    hb = pd.Series(hac > hao, index=df.index)
    b3 = hb & hb.shift(1, fill_value=False) & hb.shift(2, fill_value=False)
    s3 = (~hb) & (~hb.shift(1, fill_value=True)) & (~hb.shift(2, fill_value=True))
    add("Heikin-Ashi trend", sgn(b3, s3))

    # Chandelier exit (22, 3)
    a22 = wilder(tr, 22).values
    hh22, ll22 = h.rolling(22).max().values, l.rolling(22).min().values
    ch = np.ones(n, dtype=np.int8)
    d, pls, pss = 1, np.nan, np.nan
    for i in range(n):
        lsv, ssv = hh22[i] - 3 * a22[i], ll22[i] + 3 * a22[i]
        if np.isnan(lsv):
            ch[i] = d
            continue
        if not np.isnan(pss):
            if cv[i] > pss:
                d = 1
            elif cv[i] < pls:
                d = -1
        pls, pss = lsv, ssv
        ch[i] = d
    add("Chandelier Exit (22,3)", ch)

    corr = c.rolling(50).corr(pd.Series(np.arange(n, dtype=float), index=df.index))
    add("Linear regression (50)", np.where(corr ** 2 > 0.5, np.sign(corr), 0))

    # candlestick patterns (same priority order as the app)
    body, rg = (c - o).abs(), h - l
    upw, low_w = h - np.maximum(c, o), np.minimum(c, o) - l
    c1, o1, c2, o2 = c.shift(), o.shift(), c.shift(2), o.shift(2)
    pbody, big = (c1 - o1).abs(), (c2 - o2).abs()
    morning = (c2 < o2) & (big > atr * 0.6) & (pbody < big * 0.4) & (c > o) & (c > (c2 + o2) / 2)
    evening = (c2 > o2) & (big > atr * 0.6) & (pbody < big * 0.4) & (c < o) & (c < (c2 + o2) / 2)
    beng = (c1 < o1) & (c > o) & (c >= o1) & (o <= c1) & (body > pbody)
    seng = (c1 > o1) & (c < o) & (c <= o1) & (o >= c1) & (body > pbody)
    ham = (rg > 0) & (body > 0) & (low_w > 2 * body) & (upw < 0.25 * rg)
    shs = (rg > 0) & (body > 0) & (upw > 2 * body) & (low_w < 0.25 * rg)
    pat = np.select([morning, evening, beng, seng, ham, shs], [1, -1, 1, -1, 1, -1], default=0)
    add("Candle pattern", pat)

    votes = pd.DataFrame(V)
    # regime-aware weighted score, as in the app
    w = pd.DataFrame(1.0, index=df.index, columns=votes.columns)
    mr_cols = [x for x in votes.columns if x in MEAN_REV]
    tr_cols = [x for x in votes.columns if x not in MEAN_REV]
    trending, ranging = (adx > 25), (adx < 20)
    w.loc[trending, mr_cols], w.loc[trending, tr_cols] = 0.5, 1.5
    w.loc[ranging, mr_cols], w.loc[ranging, tr_cols] = 1.3, 0.6
    score = (votes * w).sum(axis=1) / w.sum(axis=1)
    rvol = v / v.shift().rolling(20).mean().replace(0, np.nan)
    aux = pd.DataFrame({"atr": atr, "adx": adx, "rvol": rvol, "score": score}, index=df.index)
    aux["side"] = np.where(aux.score >= 0.2, 1, np.where(aux.score <= -0.2, -1, 0))
    return votes, aux


# ------------------------------------------------------------------ forward evaluation
def forward(df, atr):
    """Move after H bars in ATR, and the +/-1.5 ATR race (same-candle double hit counts as neither)."""
    c, hi, lo = df.close.values, df.high.values, df.low.values
    a = atr.values
    n = len(c)
    move = np.full(n, np.nan)
    race = np.zeros(n, dtype=np.int8)
    if n <= H + 1:
        return move, race
    move[:-H] = (c[H:] - c[:-H]) / a[:-H]
    up, dn = c + RACE * a, c - RACE * a
    decided = np.zeros(n, dtype=bool)
    for k in range(1, H + 1):
        hu = np.full(n, False)
        hd = np.full(n, False)
        hu[:-k] = hi[k:] >= up[:-k]
        hd[:-k] = lo[k:] <= dn[:-k]
        new = ~decided
        race[new & hu & ~hd] = 1
        race[new & hd & ~hu] = -1
        decided |= (hu | hd)
    return move, race


def simulate(df, atr, side):
    """Outcome in R for a trade opened at each bar's close, for each target multiple.
    Returns {k: (r array, exit index array)}; NaN where there is no signal or not enough future data."""
    c, hi, lo = df.close.values, df.high.values, df.low.values
    a = atr.values
    n = len(c)
    out = {}
    idx = np.flatnonzero((side != 0) & ~np.isnan(a))
    idx = idx[idx < n - 2]
    for k in TPS:
        r = np.full(n, np.nan)
        ex = np.full(n, -1)
        if len(idx):
            s = side[idx].astype(float)
            ent = c[idx]
            risk = SL_ATR * a[idx]
            sl = ent - s * risk
            tpv = ent + s * k * risk
            res = np.full(len(idx), np.nan)
            exi = np.full(len(idx), -1)
            done = np.zeros(len(idx), dtype=bool)
            for j in range(1, MAX_HOLD + 1):
                pos = idx + j
                ok = pos < n
                p2 = np.where(ok, pos, n - 1)
                hit_sl = np.where(s > 0, lo[p2] <= sl, hi[p2] >= sl) & ok & ~done
                hit_tp = np.where(s > 0, hi[p2] >= tpv, lo[p2] <= tpv) & ok & ~done
                sl_now = hit_sl                      # a same-bar double hit counts as a loss
                tp_now = hit_tp & ~hit_sl
                res[sl_now] = -1.0 - COST_R
                res[tp_now] = k - COST_R
                exi[sl_now | tp_now] = pos[sl_now | tp_now]
                done |= sl_now | tp_now
                if j == MAX_HOLD:
                    to = ~done & ok
                    res[to] = (c[p2[to]] - ent[to]) * s[to] / risk[to] - COST_R
                    exi[to] = pos[to]
                    done |= to
            r[idx] = res
            ex[idx] = exi
        out[k] = (r, ex)
    return out


# ------------------------------------------------------------------ statistics
def to_ms(index):
    return np.asarray((index - pd.Timestamp("1970-01-01", tz="UTC")) // pd.Timedelta(milliseconds=1), dtype=np.int64)


def tstat(x, n_eff):
    x = np.asarray(x, dtype=float)
    if len(x) < 5 or n_eff < 5:
        return np.nan
    sd = x.std(ddof=1)
    return np.nan if sd == 0 else x.mean() / (sd / np.sqrt(n_eff))


def pick_non_overlapping(mask, r, ex):
    """Greedy: one trade per coin at a time (like the app), taking the first signal after the previous trade closed."""
    idx = np.flatnonzero(mask & ~np.isnan(r))
    keep, busy = [], -1
    for i in idx:
        if i >= busy:
            keep.append(i)
            busy = ex[i]
    return np.array(keep, dtype=int)


def lookup(src, ms):
    """Value of a higher-timeframe series as of each candle close (last higher candle already closed)."""
    if src is None:
        return np.zeros(len(ms), dtype=int)
    keys, vals = src
    pos = np.searchsorted(keys, ms, side="right") - 1
    return np.where(pos >= 0, vals[np.clip(pos, 0, len(vals) - 1)], 0)


FILTERS = {
    "none": lambda c: np.full(len(c["side"]), True),
    "strong only (|score|>=0.5)": lambda c: np.abs(c["score"]) >= 0.5,
    "rvol>=1": lambda c: c["rvol"] >= 1,
    "adx>=20": lambda c: c["adx"] >= 20,
    "higher tf not against": lambda c: ~(c["has_htf"] & (c["htf"] == -c["side"])),
    "higher tf agrees": lambda c: c["has_htf"] & (c["htf"] == c["side"]),
    "bitcoin 4h agrees": lambda c: c["btc"] == c["side"],
    "combo: rvol>=1 + adx>=20 + htf not against": lambda c: (c["rvol"] >= 1) & (c["adx"] >= 20) & ~(c["has_htf"] & (c["htf"] == -c["side"])),
}


def run(coins, tfs, data):
    os.makedirs(OUT, exist_ok=True)
    F = {}
    for (coin, tf), df in data.items():
        if len(df) >= WARM + 100:
            F[(coin, tf)] = (df,) + features(df)
    print("feature sets:", len(F), flush=True)

    def cms(df, tf):
        return to_ms(df.index) + TF_MIN[tf] * 60_000          # when each candle closed

    btc4, btc1 = F.get(("BTC", "4h")), F.get(("BTC", "1d"))
    btc_side_src = (cms(btc4[0], "4h"), btc4[2].side.values) if btc4 else None
    if btc1:
        ret30 = btc1[0].close.pct_change(30).values
        btc_reg_src = (cms(btc1[0], "1d"), np.where(ret30 > 0.10, 1, np.where(ret30 < -0.10, -1, 0)))
    else:
        btc_reg_src = None

    ind_rows = []
    tr_r, tr_meta = {}, {}                                      # (tf, filter, k) -> lists of arrays
    for tf in tfs:
        frames, ctxs = [], {}
        for coin in coins:
            if (coin, tf) not in F:
                continue
            df, votes, aux = F[(coin, tf)]
            ms = cms(df, tf)
            nxt = TF_NEXT[tf]
            has = bool(nxt and (coin, nxt) in F)
            htf = lookup((cms(F[(coin, nxt)][0], nxt), F[(coin, nxt)][2].side.values), ms) if has else np.zeros(len(ms), dtype=int)
            btc_side = lookup(btc_side_src, ms) if coin != "BTC" else aux.side.values
            btc_reg = lookup(btc_reg_src, ms)
            move, race = forward(df, aux.atr)
            sim = simulate(df, aux.atr, aux.side.values)
            rside = np.random.default_rng(abs(hash((coin, tf))) % (2 ** 32)).choice([-1, 1], size=len(df))
            rsim = simulate(df, aux.atr, rside)                        # random-direction trades = the "no skill" baseline
            n = len(df)
            valid = np.zeros(n, dtype=bool)
            valid[WARM:n - H] = True
            valid &= ~np.isnan(move) & (aux.atr.values > 0)
            ctxs[coin] = {
                "side": aux.side.values, "score": aux.score.values, "rvol": aux.rvol.values, "adx": aux.adx.values,
                "htf": htf, "has_htf": np.full(n, has), "btc": btc_side, "reg": btc_reg, "ms": ms, "valid": valid, "sim": sim,
                "rside": rside, "rsim": rsim,
            }
            fr = votes.copy()
            fr["coin"], fr["ms"], fr["move"], fr["race"] = coin, ms, move, race
            for col in ("atr", "adx", "rvol", "score", "side"):
                fr[col] = aux[col].values
            frames.append(fr[valid])
        if not frames:
            continue
        D = pd.concat(frames, ignore_index=True)
        D["adj"] = D.move - D.groupby("ms").move.transform("mean")      # remove the market's own drift
        cut = D.ms.quantile(0.6)
        D["oos"] = D.ms > cut
        vcols = list(F[next(iter(F))][1].columns)
        print(f"[{tf}] rows {len(D):,}; first 60% / last 40% split at {pd.to_datetime(cut, unit='ms', utc=True):%Y-%m-%d}", flush=True)

        def indicator_stats(name, vote):
            for sidename, m in (("all", vote != 0), ("buy", vote > 0), ("sell", vote < 0)):
                x = D[m]
                if len(x) < 100:
                    continue
                vv = vote[m].values.astype(float)
                sm, sa = vv * x.move.values, vv * x.adj.values
                nz = sm != 0
                rc = x.race.values
                rw, rl = int(((vv == rc) & (rc != 0)).sum()), int(((vv == -rc) & (rc != 0)).sum())
                oos = x.oos.values
                ind_rows.append({
                    "tf": tf, "indicator": name, "side": sidename, "signals": len(x),
                    "direction_acc_pct": round(100 * (sm[nz] > 0).mean(), 2) if nz.any() else np.nan,
                    "avg_move_atr": round(sm.mean(), 4), "adj_move_atr": round(sa.mean(), 4),
                    "t_adj": round(tstat(sa, len(sa) / H), 2),
                    "race_win_pct": round(100 * rw / max(1, rw + rl), 2),
                    "adj_first60": round(sa[~oos].mean(), 4) if (~oos).sum() > 30 else np.nan,
                    "adj_last40_oos": round(sa[oos].mean(), 4) if oos.sum() > 30 else np.nan,
                    "t_oos": round(tstat(sa[oos], oos.sum() / H), 2) if oos.sum() > 30 else np.nan,
                })

        for name in vcols:
            indicator_stats(name, D[name])
        indicator_stats("OVERALL verdict", D.side)
        indicator_stats("OVERALL strong verdict", pd.Series(np.where(D.score.abs() >= 0.5, D.side, 0), index=D.index))

        for coin, c in ctxs.items():
            base = (c["side"] != 0) & c["valid"]
            for fname, fn in FILTERS.items():
                mask = base & fn(c)
                if not mask.any():
                    continue
                for k, (r, ex) in c["sim"].items():
                    keep = pick_non_overlapping(mask, r, ex)
                    if not len(keep):
                        continue
                    key = (tf, fname, k)
                    tr_r.setdefault(key, []).append(r[keep])
                    tr_meta.setdefault(key, []).append((np.full(len(keep), coin), c["ms"][keep], c["side"][keep], c["reg"][keep]))
            for k, (r, ex) in c["rsim"].items():
                keep = pick_non_overlapping(c["valid"], r, ex)
                if len(keep):
                    key = (tf, "RANDOM direction (no-skill baseline)", k)
                    tr_r.setdefault(key, []).append(r[keep])
                    tr_meta.setdefault(key, []).append((np.full(len(keep), coin), c["ms"][keep], c["rside"][keep], c["reg"][keep]))
        ctxs.clear()
        globals()["_CUT_" + tf] = cut

    ind = pd.DataFrame(ind_rows)
    ind.to_csv(f"{OUT}/indicator_accuracy.csv", index=False)

    parts = []
    for (tf, fname, k), rs in tr_r.items():
        meta = tr_meta[(tf, fname, k)]
        parts.append(pd.DataFrame({
            "tf": tf, "filter": fname, "target_r": k, "r": np.concatenate(rs), "coin": np.concatenate([m[0] for m in meta]),
            "ms": np.concatenate([m[1] for m in meta]), "side": np.concatenate([m[2] for m in meta]),
            "btc_regime": np.concatenate([m[3] for m in meta]),
        }))
    T = pd.concat(parts, ignore_index=True) if parts else pd.DataFrame(columns=["tf", "filter", "target_r", "r", "coin", "ms", "side", "btc_regime"])
    T["oos"] = [ms > globals()["_CUT_" + tf] for ms, tf in zip(T.ms.values, T.tf.values)]
    T["month"] = pd.to_datetime(T.ms, unit="ms", utc=True).dt.strftime("%Y-%m")

    def agg(g):
        r = g.r.values
        gl = -r[r < 0].sum()
        return {
            "trades": len(r), "win_pct": round(100 * (r > 0).mean(), 1), "avg_r": round(r.mean(), 3), "total_r": round(r.sum(), 1),
            "profit_factor": round(r[r > 0].sum() / gl, 2) if gl > 0 else np.nan, "t_stat": round(tstat(r, len(r)), 2),
            "avg_r_first60": round(g[~g.oos].r.mean(), 3) if (~g.oos).sum() > 20 else np.nan,
            "avg_r_last40_oos": round(g[g.oos].r.mean(), 3) if g.oos.sum() > 20 else np.nan,
            "breakeven_win_pct": round(100 * (1 + COST_R) / (1 + g.target_r.iloc[0]), 1),
        }

    def table(frame, keys):
        rows = []
        for key, g in frame.groupby(keys):
            key = key if isinstance(key, tuple) else (key,)
            rows.append({**dict(zip(keys, key)), **agg(g)})
        return pd.DataFrame(rows)

    strat = table(T, ["tf", "filter", "target_r"])
    strat.to_csv(f"{OUT}/strategy_results.csv", index=False)
    table(T[T["filter"] == "none"], ["tf", "target_r", "month"]).to_csv(f"{OUT}/monthly_baseline.csv", index=False)
    rg = T[(T["filter"] == "none") & (T.target_r == 1.0)].copy()
    rg["direction"] = np.where(rg.side == 1, "BUY", "SELL")
    rg["btc_regime"] = rg.btc_regime.map({1: "BTC rising", 0: "BTC sideways", -1: "BTC falling"})
    table(rg, ["tf", "btc_regime", "direction"]).to_csv(f"{OUT}/regime_breakdown.csv", index=False)
    write_summary(ind, strat, T)
    return ind, strat


def write_summary(ind, strat, T):
    L = ["# Historical lab results", "",
         f"Coins tested: {T.coin.nunique()}. Trades simulated: {len(T):,} (stop {SL_ATR} ATR, costs {COST_R}R, one open trade per coin and timeframe).",
         "Indicator tests are market-adjusted (the average move of all coins at that moment is subtracted) so a falling or rising market does not look like skill.",
         "With about 45 indicators on several timeframes a few will look good by chance. Trust only results that are positive in the first 60% AND the last 40% (out of sample) with |t| above about 3.5.", ""]
    ok = ind[(ind.side == "all") & ~ind.indicator.str.startswith("OVERALL")]
    robust = ok[(ok.adj_first60 > 0) & (ok.adj_last40_oos > 0) & (ok.t_adj > 3.5) & (ok.t_oos > 2)]
    L.append("## Indicators with a repeatable edge (adjusted move > 0 in both halves, t > 3.5)")
    L.append(robust.sort_values("t_adj", ascending=False).head(15).to_string(index=False) if len(robust) else "None. No single indicator showed a repeatable edge after removing the market's drift.")
    L += ["", "## Worst indicators"]
    L.append(ok.sort_values("t_adj").head(8)[["tf", "indicator", "signals", "direction_acc_pct", "adj_move_atr", "t_adj"]].to_string(index=False))
    ov = ind[ind.indicator.str.startswith("OVERALL") & (ind.side == "all")]
    L += ["", "## The app's overall verdict", ov[["tf", "indicator", "signals", "direction_acc_pct", "adj_move_atr", "t_adj", "adj_first60", "adj_last40_oos"]].to_string(index=False)]
    good = strat[(strat.trades >= 300) & (strat.avg_r_first60 > 0) & (strat.avg_r_last40_oos > 0) & (strat.t_stat > 2)]
    L += ["", "## Trade rules positive in both halves (n>=300, t>2)"]
    L.append(good.sort_values("avg_r_last40_oos", ascending=False).head(15).to_string(index=False) if len(good) else "None. No tested combination of timeframe, filter and target was profitable in both halves.")
    best = strat[strat.trades >= 300].sort_values("avg_r", ascending=False).head(10)
    L += ["", "## Best 10 by average R (check the out-of-sample column before believing them)", best.to_string(index=False)]
    base = strat[strat["filter"].str.startswith("RANDOM")]
    L += ["", "## No-skill baseline: trades in a random direction with the same stops and targets",
          "Compare every rule above with the row for the same timeframe and target. A rule only matters if it beats this baseline clearly.",
          base[["tf", "target_r", "trades", "win_pct", "avg_r", "avg_r_first60", "avg_r_last40_oos"]].to_string(index=False),
          "", "Note: t-stats treat trades as independent, but trades on different coins share the market's moves, so the true significance is lower.",
          "On pure random data this lab still shows t-stats up to about 3 by chance. Prefer rules that beat the baseline in both halves and in most months (monthly_baseline.csv)."]
    open(f"{OUT}/SUMMARY.md", "w").write("\n".join(L) + "\n")
    print("\n".join(L))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--coins", type=int, default=40)
    ap.add_argument("--tfs", default="15m,1h,4h,1d")
    ap.add_argument("--synthetic", action="store_true")
    a = ap.parse_args()
    tfs = [t for t in a.tfs.split(",") if t in TF_MIN]
    need = set(tfs) | {TF_NEXT[t] for t in tfs if TF_NEXT[t]}
    if a.synthetic:
        coins = ["BTC"] + [f"C{i}" for i in range(a.coins - 1)]
        data = synthetic(coins, sorted(need | {"4h", "1d"}))
    else:
        coins = top_coins(a.coins)
        print("coins:", coins, flush=True)
        data = {}
        for i, c in enumerate(coins):
            for tf in sorted(need | ({"4h", "1d"} if c == "BTC" else set())):
                df = history(c, tf)
                if df is not None and len(df) >= WARM + 100:
                    data[(c, tf)] = df
            print(f"downloaded {i + 1}/{len(coins)} {c}", flush=True)
    run(coins, tfs, data)


if __name__ == "__main__":
    main()
