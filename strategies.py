"""Technical strategies. Each takes (rows, i): rows = list of namedtuples (one per candle, indicators
included), i = index of the candle to evaluate. Only rows[:i+1] are used, so the same code serves
live scanning (i = last closed candle) and the backtester."""

def sig(side, r, why, sl_atr=1.5, rr=2.0, sl=None, tp=None, min_rr=1.0):
    c = r.close
    if sl is None:
        sl = c - side * sl_atr * r.atr
    risk = (c - sl) * side
    if not risk > 0:
        return None
    if tp is None:
        tp = c + side * risk * rr
    elif not (tp - c) * side >= min_rr * risk:
        return None
    return {"side": side, "sl": float(sl), "tp": float(tp), "why": why}

def _wick(r):
    return abs(r.close - r.open), r.high - r.low, min(r.open, r.close) - r.low, r.high - max(r.open, r.close)

def _engulf(p, r):
    bull = p.close < p.open and r.close > r.open and r.close >= p.open and r.open <= p.close
    bear = p.close > p.open and r.close < r.open and r.close <= p.open and r.open >= p.close
    return bull, bear

def scalping(R, i):                       # 5m: fast EMA cross with trend + momentum filter
    r, p = R[i], R[i - 1]
    if not r.adx > 18:
        return None
    if p.ema9 <= p.ema21 and r.ema9 > r.ema21 and r.close > r.ema50 and 45 < r.rsi < 70:
        return sig(1, r, "EMA9 crossed above EMA21, above EMA50", 1.0, 1.5)
    if p.ema9 >= p.ema21 and r.ema9 < r.ema21 and r.close < r.ema50 and 30 < r.rsi < 55:
        return sig(-1, r, "EMA9 crossed below EMA21, below EMA50", 1.0, 1.5)

def day_trading(R, i):                    # 15m: pullback to EMA21 inside the day's trend, VWAP side
    r = R[i]
    novwap = r.vwap != r.vwap
    if r.ema21 > r.ema50 and r.low <= r.ema21 < r.close and r.rsi > 45 and (novwap or r.close > r.vwap):
        return sig(1, r, "Pullback to EMA21 in uptrend, above VWAP", 1.5, 2.0)
    if r.ema21 < r.ema50 and r.high >= r.ema21 > r.close and r.rsi < 55 and (novwap or r.close < r.vwap):
        return sig(-1, r, "Pullback to EMA21 in downtrend, below VWAP", 1.5, 2.0)

def intraday(R, i):                       # 15m: opening-range breakout, same-day exit
    r, p = R[i], R[i - 1]
    day, j = r.Index.date(), i
    while j > 0 and R[j - 1].Index.date() == day:
        j -= 1
    if i < j + 4:
        return None
    hi, lo = max(x.high for x in R[j:j + 4]), min(x.low for x in R[j:j + 4])
    if not hi - lo > 0.5 * r.atr:
        return None
    if r.close > hi and p.close <= hi:
        return sig(1, r, "Opening-range breakout up", sl=max(lo, r.close - 3 * r.atr), rr=2.0)
    if r.close < lo and p.close >= lo:
        return sig(-1, r, "Opening-range breakout down", sl=min(hi, r.close + 3 * r.atr), rr=2.0)

def swing(R, i):                          # 1h entry confirmed by 4H trend, scored
    r = R[i]
    if r.signal == 0:
        return None
    side = int(r.signal)
    return sig(side, r, f"4H trend + RSI/MACD/EMA50/flow score {int(r.long if side == 1 else r.short)}/7", 1.5, 2.0)

def position(R, i):                       # 1d: golden / death cross, wide stop, multi-week hold
    r, p = R[i], R[i - 1]
    if p.ema50 <= p.ema200 and r.ema50 > r.ema200:
        return sig(1, r, "Golden cross EMA50/200 (daily)", 2.5, 3.0)
    if p.ema50 >= p.ema200 and r.ema50 < r.ema200:
        return sig(-1, r, "Death cross EMA50/200 (daily)", 2.5, 3.0)

def trend(R, i):                          # 1h: aligned EMAs, strong ADX, buy the dip to EMA21
    r = R[i]
    if r.ema21 > r.ema50 > r.ema200 and r.adx > 25 and r.pdi > r.ndi and r.low <= r.ema21 < r.close:
        return sig(1, r, f"Strong uptrend (ADX {r.adx:.0f}), dip to EMA21", 1.5, 2.5)
    if r.ema21 < r.ema50 < r.ema200 and r.adx > 25 and r.ndi > r.pdi and r.high >= r.ema21 > r.close:
        return sig(-1, r, f"Strong downtrend (ADX {r.adx:.0f}), rally to EMA21", 1.5, 2.5)

def breakout(R, i):                       # 1h: 20-bar Donchian break with range expansion and volume
    r, p = R[i], R[i - 1]
    vol_ok = (not r.vol_ma > 0) or r.volume > 1.3 * r.vol_ma
    big = r.high - r.low > r.atr and r.adx > 15 and vol_ok
    if big and r.close > r.don_hi and p.close <= p.don_hi:
        return sig(1, r, "Broke 20-bar high with expansion", 1.5, 2.5)
    if big and r.close < r.don_lo and p.close >= p.don_lo:
        return sig(-1, r, "Broke 20-bar low with expansion", 1.5, 2.5)

def reversal(R, i):                       # 1h: exhaustion at Bollinger band + reversal candle
    r, p = R[i], R[i - 1]
    body, rng, lw, uw = _wick(r)
    bull, bear = _engulf(p, r)
    last = R[i - 2:i + 1]
    if min(x.low - x.bb_lo for x in last) <= 0 and min(x.rsi for x in R[i - 3:i + 1]) < 32 and r.close > r.open \
            and (bull or (lw > 2 * body and lw > 0.6 * rng)):
        return sig(1, r, "Oversold at lower band + bullish reversal candle", sl=min(x.low for x in last) - 0.5 * r.atr, tp=r.bb_mid)
    if max(x.high - x.bb_up for x in last) >= 0 and max(x.rsi for x in R[i - 3:i + 1]) > 68 and r.close < r.open \
            and (bear or (uw > 2 * body and uw > 0.6 * rng)):
        return sig(-1, r, "Overbought at upper band + bearish reversal candle", sl=max(x.high for x in last) + 0.5 * r.atr, tp=r.bb_mid)

def range_trade(R, i):                    # 1h: low ADX, fade the edges of a contained range
    r = R[i]
    h = r.rng_hi - r.rng_lo
    if not (r.adx < 20 and 2 * r.atr < h < 10 * r.atr):
        return None
    if r.close <= r.rng_lo + 0.15 * h and r.rsi < 40 and r.close > r.open:
        return sig(1, r, "Bounce from range low", sl=r.rng_lo - 0.5 * r.atr, tp=r.rng_lo + 0.5 * h)
    if r.close >= r.rng_hi - 0.15 * h and r.rsi > 60 and r.close < r.open:
        return sig(-1, r, "Rejection at range high", sl=r.rng_hi + 0.5 * r.atr, tp=r.rng_hi - 0.5 * h)

def mean_reversion(R, i):                 # 1h: stretched from the mean while not trending
    r = R[i]
    if r.adx < 25 and r.z20 < -2 and r.rsi < 35 and r.close > r.open:
        return sig(1, r, f"Z-score {r.z20:.1f}, target mean", 1.5, tp=r.bb_mid)
    if r.adx < 25 and r.z20 > 2 and r.rsi > 65 and r.close < r.open:
        return sig(-1, r, f"Z-score {r.z20:.1f}, target mean", 1.5, tp=r.bb_mid)

def price_action(R, i):                   # 1h: pin bar / engulfing candle at a confirmed swing level
    r, p = R[i], R[i - 1]
    body, rng, lw, uw = _wick(r)
    if not rng > 0:
        return None
    bull, bear = _engulf(p, r)
    if abs(r.low - r.sup) <= 0.5 * r.atr and r.close > r.open and (bull or (lw > 2 * body and lw > 0.55 * rng)):
        return sig(1, r, "Bullish pin bar/engulfing at support", sl=r.low - 0.3 * r.atr, rr=2.0)
    if abs(r.high - r.res) <= 0.5 * r.atr and r.close < r.open and (bear or (uw > 2 * body and uw > 0.55 * rng)):
        return sig(-1, r, "Bearish pin bar/engulfing at resistance", sl=r.high + 0.3 * r.atr, rr=2.0)

def quant(R, i):                          # 1h: multi-factor z-score model (momentum, flow, trend)
    r, p = R[i], R[i - 1]
    if p.q <= 1.0 < r.q and r.adx > 15:
        return sig(1, r, f"Factor score {r.q:.2f} crossed +1", 1.5, 2.0)
    if p.q >= -1.0 > r.q and r.adx > 15:
        return sig(-1, r, f"Factor score {r.q:.2f} crossed -1", 1.5, 2.0)

# name, timeframe, function, max signal age (minutes after candle close), max hold (hours), style
REGISTRY = [
    ("Scalping", "5m", scalping, 15, 3, "minutes to hours"),
    ("Day trading", "15m", day_trading, 45, 24, "same day"),
    ("Intraday ORB", "15m", intraday, 45, 12, "close before day end"),
    ("Swing", "1h", swing, 180, 168, "days"),
    ("Trend", "1h", trend, 120, 120, "days"),
    ("Breakout", "1h", breakout, 120, 96, "hours to days"),
    ("Reversal", "1h", reversal, 120, 72, "hours to days"),
    ("Range", "1h", range_trade, 120, 72, "hours to days"),
    ("Mean reversion", "1h", mean_reversion, 120, 48, "hours to days"),
    ("Price action", "1h", price_action, 120, 72, "hours to days"),
    ("Quant factor", "1h", quant, 120, 96, "hours to days"),
    ("Position", "1d", position, 3000, 1440, "weeks to months"),
    ("Day trading 30m", "30m", day_trading, 90, 36, "hours"),
    ("Trend 30m", "30m", trend, 90, 48, "hours to days"),
    ("Breakout 30m", "30m", breakout, 90, 48, "hours to days"),
    ("Trend 4H", "4h", trend, 480, 240, "days"),
    ("Breakout 4H", "4h", breakout, 480, 240, "days"),
    ("Reversal 4H", "4h", reversal, 480, 240, "days"),
    ("Mean reversion 4H", "4h", mean_reversion, 480, 240, "days"),
]
