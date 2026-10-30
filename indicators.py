import numpy as np
import pandas as pd

def ema(s, n):
    return s.ewm(span=n, adjust=False).mean()

def rsi(s, n=14):
    d = s.diff()
    up, dn = d.clip(lower=0), -d.clip(upper=0)
    rs = up.ewm(alpha=1 / n, adjust=False).mean() / dn.ewm(alpha=1 / n, adjust=False).mean()
    return 100 - 100 / (1 + rs)

def atr(df, n=14):
    pc = df["close"].shift()
    tr = pd.concat([df["high"] - df["low"], (df["high"] - pc).abs(), (df["low"] - pc).abs()], axis=1).max(axis=1)
    return tr.ewm(alpha=1 / n, adjust=False).mean()

def macd_hist(s):
    m = ema(s, 12) - ema(s, 26)
    return m - ema(m, 9)

def adx(df, n=14):
    up, dn = df.high.diff(), -df.low.diff()
    pdm = pd.Series(np.where((up > dn) & (up > 0), up, 0.0), index=df.index)
    ndm = pd.Series(np.where((dn > up) & (dn > 0), dn, 0.0), index=df.index)
    a = atr(df, n)
    pdi = 100 * pdm.ewm(alpha=1 / n, adjust=False).mean() / a
    ndi = 100 * ndm.ewm(alpha=1 / n, adjust=False).mean() / a
    dx = 100 * (pdi - ndi).abs() / (pdi + ndi).replace(0, np.nan)
    return dx.ewm(alpha=1 / n, adjust=False).mean(), pdi, ndi

def add_flow(d):
    """Buy/sell flow proxies from OHLCV (needs real volume)."""
    rng = (d.high - d.low).replace(0, np.nan)
    clv = (((d.close - d.low) - (d.high - d.close)) / rng).fillna(0)
    d["delta"] = clv * d.volume
    d["flow20"] = d["delta"].rolling(20).sum()
    d["cmf"] = d["flow20"] / d.volume.rolling(20).sum().replace(0, np.nan)
    d["obv"] = (np.sign(d.close.diff()).fillna(0) * d.volume).cumsum()
    d["obv_ema"] = ema(d["obv"], 21)
    tp, day = (d.high + d.low + d.close) / 3, d.index.date
    d["vwap"] = (tp * d.volume).groupby(day).cumsum() / d.volume.groupby(day).cumsum().replace(0, np.nan)
    return d

def add_indicators(df):
    d = df.copy()
    for n in (9, 21, 50, 200):
        d[f"ema{n}"] = ema(d.close, n)
    d["rsi"], d["atr"], d["mhist"] = rsi(d.close), atr(d), macd_hist(d.close)
    d["vol_ma"] = d.volume.rolling(20).mean()
    d["adx"], d["pdi"], d["ndi"] = adx(d)
    mid, sd = d.close.rolling(20).mean(), d.close.rolling(20).std()
    d["bb_mid"], d["bb_up"], d["bb_lo"], d["z20"] = mid, mid + 2 * sd, mid - 2 * sd, (d.close - mid) / sd
    d["don_hi"], d["don_lo"] = d.high.rolling(20).max().shift(1), d.low.rolling(20).min().shift(1)
    d["rng_hi"], d["rng_lo"] = d.high.rolling(48).max().shift(1), d.low.rolling(48).min().shift(1)
    d["roc24"] = d.close.pct_change(24)
    d = add_flow(d)
    # confirmed swing pivots (known 3 bars later, so no lookahead): latest support and resistance
    pl = d.low.where(d.low == d.low.rolling(7, center=True).min())
    ph = d.high.where(d.high == d.high.rolling(7, center=True).max())
    d["sup"], d["res"] = pl.shift(3).ffill(), ph.shift(3).ffill()
    # multi-factor quant score: momentum, order flow, trend distance (all z-scored)
    z = lambda s: (s - s.rolling(200).mean()) / s.rolling(200).std()
    d["q"] = 0.4 * z(d.roc24).clip(-3, 3) + 0.3 * z(d.cmf).clip(-3, 3).fillna(0) + 0.3 * ((d.close - d.ema200) / d.atr).clip(-5, 5) / 2.5
    return d
