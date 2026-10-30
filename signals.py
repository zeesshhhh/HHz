import numpy as np
import pandas as pd
from config import MIN_SCORE
from data import resample
from indicators import add_indicators, ema

def trend_4h(df1h):
    h4 = resample(df1h, "4h")
    e50, e200 = ema(h4.close, 50), ema(h4.close, 200)
    t = np.where((e50 > e200) & (h4.close > e50), 1, np.where((e50 < e200) & (h4.close < e50), -1, 0))
    return pd.Series(t, index=h4.index).shift(1)   # known only after the 4H bar closes

def build(df1h):
    """1H frame with all indicators plus the swing-trading score and signal."""
    d = add_indicators(df1h)
    d["trend"] = trend_4h(df1h).reindex(d.index, method="ffill").fillna(0)
    hv = d.vol_ma > 0
    fl = (((d.cmf > 0) & (d.flow20 > d.flow20.shift(3))).astype(int) + ((d.obv > d.obv_ema) & (d.close > d.vwap)).astype(int)) * hv
    fs = (((d.cmf < 0) & (d.flow20 < d.flow20.shift(3))).astype(int) + ((d.obv < d.obv_ema) & (d.close < d.vwap)).astype(int)) * hv
    veto_l, veto_s = hv & (d.cmf < -0.1), hv & (d.cmf > 0.1)
    rr, rh = d.rsi > d.rsi.shift(), d.mhist > d.mhist.shift()
    d["long"] = ((d.trend == 1) * 2 + (d.rsi.between(35, 60) & rr).astype(int) + ((d.mhist > 0) & rh).astype(int)
                 + (d.close > d.ema50).astype(int) + fl)
    d["short"] = ((d.trend == -1) * 2 + (d.rsi.between(40, 65) & ~rr).astype(int) + ((d.mhist < 0) & ~rh).astype(int)
                  + (d.close < d.ema50).astype(int) + fs)
    sl = (d.long >= MIN_SCORE) & (d.long.shift() < MIN_SCORE) & (d.trend == 1) & ~veto_l
    ss = (d.short >= MIN_SCORE) & (d.short.shift() < MIN_SCORE) & (d.trend == -1) & ~veto_s
    d["signal"] = sl.astype(int) - ss.astype(int)
    return d
